import Foundation
import Darwin

/// ChatGPT 的 durable / Dot 任务没有本地 rollout。此连接只订阅会话快照与补丁，
/// 不发送执行、输入、审批或任务控制请求。所有可变状态仅在监测器的 worker 上访问。
final class CodexAppStatusReader {
    private let socketPath: String
    private let logDirectory: URL
    private let now: () -> Date
    private var descriptor: Int32 = -1
    private var clientID: String?
    private var incoming = Data()
    private var outgoing = Data()
    private var subscriptions: [String: (host: String, thread: String)] = [:]
    private var projections: [String: CodexAppThreadProjection] = [:]
    private var owners: [String: String] = [:]
    private var recoverySubscriptions: [String: (host: String, thread: String)] = [:]
    private var lastReadAt: Date?
    private var nextConnectionAttempt = Date.distantPast
    private var nextDiscovery = Date.distantPast
    private let maximumFrameBytes = 64 * 1024 * 1024

    init(socketPath: String? = nil, logDirectory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.socketPath = socketPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/ipc/ipc.sock").path
        self.logDirectory = logDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.openai.codex")
        self.now = now
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func readTasks() -> [CodexTaskSnapshot] {
        let timestamp = now()
        // 通知可能缺失；轮询中断超过 15 秒也要重建连接并重新取快照。
        if let lastReadAt, timestamp.timeIntervalSince(lastReadAt) > 15 { reconnect() }
        lastReadAt = timestamp
        if descriptor < 0, timestamp >= nextConnectionAttempt { connect() }
        guard descriptor >= 0 else { return [] }
        flush()
        // Socket 为非阻塞，单轮限制读取量，避免连续文本输出占满 worker。
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(0.1)
        for _ in 0..<1024 {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                incoming.append(contentsOf: buffer.prefix(count))
                guard consumeFrames() else { disconnect(); break }
            } else {
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK,
                   !incoming.isEmpty, Date() < deadline {
                    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    if Darwin.poll(&event, 1, 5) > 0 { continue }
                }
                if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    disconnect()
                }
                break
            }
        }
        if clientID != nil, now() >= nextDiscovery {
            nextDiscovery = now().addingTimeInterval(10)
            discoverRemoteThreads()
        }
        flush()
        return projections.values.compactMap { $0.snapshot() }
    }

    /// 仅由监测器的串行 worker 调用；保留订阅 ID，但不沿用旧状态。
    func reconnect() {
        disconnect()
        nextConnectionAttempt = .distantPast
    }

    private func connect() {
        nextConnectionAttempt = now().addingTimeInterval(3)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path),
              FileManager.default.fileExists(atPath: socketPath) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            path.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // Darwin Unix socket 默认缓冲区很小；大快照不能每轮仅收几 KB。
        var receiveBytes: Int32 = 1_048_576
        if setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBytes, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            receiveBytes = 262_144
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBytes, socklen_t(MemoryLayout<Int32>.size))
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); return }
        descriptor = fd
        enqueue([
            "type": "request", "requestId": UUID().uuidString, "method": "initialize",
            "version": 0, "params": ["clientType": "DynamicIsland"]
        ])
    }

    private func disconnect() {
        recoverySubscriptions.merge(subscriptions) { _, current in current }
        for (key, projection) in projections {
            recoverySubscriptions[key] = (projection.host, projection.thread)
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        clientID = nil
        incoming.removeAll()
        outgoing.removeAll()
        subscriptions.removeAll()
        projections.removeAll()
        owners.removeAll()
        nextDiscovery = .distantPast
    }

    private func discoverRemoteThreads() {
        // durable 任务在主窗口中可能由 owner 持有、却没有 follower，连接时不会
        // 主动广播 ID。仅从最近的主进程日志提取 ID 作为订阅候选；日志本身不判定状态。
        guard let enumerator = FileManager.default.enumerator(at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        var logs: [(URL, Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "log", url.lastPathComponent.contains("-t0-"),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) < 172_800 else { continue }
            logs.append((url, modified))
        }
        guard let regex = try? NSRegularExpression(pattern: #"conversationId=([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})"#) else { return }
        var candidates = Set<String>()
        for (url, _) in logs.sorted(by: { $0.1 > $1.1 }).prefix(2) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 2_097_152 ? size - 2_097_152 : 0)
            guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range).reversed() {
                guard candidates.count < 48, let range = Range(match.range(at: 1), in: text) else { break }
                let thread = String(text[range])
                if candidates.insert(thread).inserted, projections["durable:\(thread)"] == nil {
                    follow(host: "durable", thread: thread)
                }
            }
        }
        // 未返回快照的候选不长期占用订阅，避免日志中的旧 ID 无限累积。
        for (key, subscription) in subscriptions where projections[key] == nil && !candidates.contains(subscription.thread) {
            if let clientID {
                enqueue(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                    "sourceClientId": clientID, "params": ["hostId": subscription.host,
                        "conversationId": subscription.thread, "following": false]])
            }
            subscriptions.removeValue(forKey: key)
        }
    }

    private func enqueue(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        var length = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &length) { outgoing.append(contentsOf: $0) }
        outgoing.append(data)
    }

    private func flush() {
        while descriptor >= 0, !outgoing.isEmpty {
            let count = outgoing.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            if count > 0 { outgoing.removeFirst(count) }
            else {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { disconnect() }
                return
            }
        }
    }

    private func consumeFrames() -> Bool {
        while incoming.count >= 4 {
            let size = incoming.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            guard size > 0, size <= maximumFrameBytes else { return false }
            guard incoming.count >= size + 4 else { return true }
            let data = Data(incoming.dropFirst(4).prefix(size))
            incoming.removeFirst(size + 4)
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            receive(message)
        }
        return true
    }

    private func follow(host: String, thread: String) {
        guard let clientID else { return }
        let key = "\(host):\(thread)"
        subscriptions[key] = (host, thread)
        enqueue([
            "type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
            "sourceClientId": clientID,
            "params": ["hostId": host, "conversationId": thread, "following": true]
        ])
    }

    private func receive(_ message: [String: Any]) {
        if message["type"] as? String == "response", message["method"] as? String == "initialize",
           let result = message["result"] as? [String: Any] {
            clientID = result["clientId"] as? String
            if clientID != nil {
                // 先让恢复的订阅有时间返回快照，再清理日志里已不存在的候选。
                if !recoverySubscriptions.isEmpty { nextDiscovery = now().addingTimeInterval(10) }
                for subscription in recoverySubscriptions.values {
                    follow(host: subscription.host, thread: subscription.thread)
                }
                recoverySubscriptions.removeAll()
            }
            return
        }
        guard message["type"] as? String == "broadcast",
              let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return }
        if method == "client-status-changed", params["status"] as? String == "disconnected",
           let client = params["clientId"] as? String {
            for key in owners.keys.filter({ owners[$0] == client }) {
                projections.removeValue(forKey: key)
                subscriptions.removeValue(forKey: key)
                owners.removeValue(forKey: key)
            }
            return
        }
        guard let host = params["hostId"] as? String, host != "local",
              let thread = params["conversationId"] as? String else { return }
        let key = "\(host):\(thread)"
        if method == "thread-stream-following-changed", params["following"] as? Bool == true {
            if subscriptions[key] == nil { follow(host: host, thread: thread) }
        } else if method == "thread-stream-state-changed",
                  message["version"] as? Int == 11,
                  let change = params["change"] as? [String: Any] {
            let projection = projections[key] ?? CodexAppThreadProjection(host: host, thread: thread)
            if projection.apply(change) {
                projections[key] = projection
                owners[key] = message["sourceClientId"] as? String
            } else {
                // 补丁丢失或格式升级时重新取快照，不沿用可能过时的“正在工作”。
                projections.removeValue(forKey: key)
                follow(host: host, thread: thread)
            }
        }
    }
}

/// 仅保留状态、时间和标题，丢弃完整对话与工具内容。
final class CodexAppThreadProjection {
    let host: String
    let thread: String
    private var revision: Int?
    private var metadata: [String: Any] = [:]
    private var turns: [String: [String: Any]] = [:]
    private var usesCanonicalHistory = false
    private static let turnFields: Set<String> = ["turnId", "status", "turnStartedAtMs", "durationMs"]
    private static let rootFields: Set<String> = ["title", "cwd", "createdAt", "updatedAt", "threadRuntimeStatus"]

    init(host: String, thread: String) { self.host = host; self.thread = thread }

    func apply(_ change: [String: Any]) -> Bool {
        guard let nextRevision = change["revision"] as? Int else { return false }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            guard state["id"] as? String == thread else { return false }
            metadata = state.filter { Self.rootFields.contains($0.key) }
            turns.removeAll()
            readHistory(state)
        } else if change["type"] as? String == "patches",
                  let revision, change["baseRevision"] as? Int == revision,
                  let patches = change["patches"] as? [[String: Any]] {
            for patch in patches { guard applyPatch(patch) else { return false } }
        } else { return false }
        revision = nextRevision
        return true
    }

    private func readHistory(_ state: [String: Any]) {
        usesCanonicalHistory = (state["turnHistory"] as? [String: Any])?["kind"] as? String == "canonical"
        if let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any],
           let entities = history["entitiesByKey"] as? [String: [String: Any]] {
            for (key, turn) in entities { turns[key] = slim(turn) }
        } else if !usesCanonicalHistory, let legacy = state["turns"] as? [[String: Any]] {
            for (index, turn) in legacy.enumerated() { turns["legacy:\(index)"] = slim(turn) }
        }
    }

    private func slim(_ turn: [String: Any]) -> [String: Any] {
        turn.filter { Self.turnFields.contains($0.key) }
    }

    private func applyPatch(_ patch: [String: Any]) -> Bool {
        guard let path = patch["path"] as? [Any], let operation = patch["op"] as? String else { return false }
        let parts = path.map { String(describing: $0) }
        guard let first = parts.first else { return false }
        let value = operation == "remove" ? nil : patch["value"]
        if first == "turns", usesCanonicalHistory { return true }
        if Self.rootFields.contains(first) {
            if parts.count == 1 { metadata[first] = value }
            else if first == "threadRuntimeStatus", parts.count == 2, parts[1] == "type" {
                var runtime = metadata[first] as? [String: Any] ?? [:]
                runtime["type"] = value
                metadata[first] = runtime
            }
            return true
        }
        let key: String
        let fieldIndex: Int
        if first == "turns", parts.count >= 2 { key = "legacy:\(parts[1])"; fieldIndex = 2 }
        else if parts.starts(with: ["turnHistory", "history", "entitiesByKey"]), parts.count >= 4 {
            key = parts[3]; fieldIndex = 4
        } else if first == "turnHistory" || first == "turns" {
            // history 整体换代时重新取快照。分页、islands 等索引不影响状态。
            return first == "turnHistory" && parts.count > 1 &&
                !(parts == ["turnHistory", "kind"] || parts == ["turnHistory", "history"] ||
                  parts == ["turnHistory", "history", "entitiesByKey"])
        } else { return true }
        if parts.count == fieldIndex {
            turns[key] = (value as? [String: Any]).map(slim)
        } else if parts.count == fieldIndex + 1, Self.turnFields.contains(parts[fieldIndex]) {
            var turn = turns[key] ?? [:]
            turn[parts[fieldIndex]] = value
            turns[key] = turn
        }
        return true
    }

    func snapshot() -> CodexTaskSnapshot? {
        guard let turn = turns.values.max(by: {
            let lhs = ($0["turnStartedAtMs"] as? NSNumber)?.doubleValue ?? 0
            let rhs = ($1["turnStartedAtMs"] as? NSNumber)?.doubleValue ?? 0
            return lhs < rhs
        }), let turnID = turn["turnId"] as? String,
           let rawState = turn["status"] as? String,
           let state = CodexTaskSnapshot.State(rawValue: rawState),
           let started = (turn["turnStartedAtMs"] as? NSNumber)?.doubleValue else { return nil }
        let cwd = metadata["cwd"] as? String
        let startDate = Date(timeIntervalSince1970: started / 1000)
        let duration = (turn["durationMs"] as? NSNumber)?.doubleValue
        let updated = state == .working ? ((metadata["updatedAt"] as? NSNumber)?.doubleValue ?? started) : started + (duration ?? 0)
        return CodexTaskSnapshot(
            id: "app:\(host):\(turnID)", rootThreadID: thread,
            title: metadata["title"] as? String ?? "Codex 任务",
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
            cwd: cwd, state: state, startedAt: startDate,
            updatedAt: Date(timeIntervalSince1970: updated / 1000)
        )
    }
}
