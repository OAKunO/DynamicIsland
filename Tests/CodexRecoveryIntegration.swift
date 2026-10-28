import Foundation
import Darwin

enum CodexRecoveryIntegration {
    static func run() throws -> Int {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout.jsonl")
        let initial = Data("""
        {"timestamp":"2026-10-26T01:00:00.000Z","type":"turn_context","payload":{"turn_id":"local-turn","cwd":"/projects/test","model":"gpt-6"}}

        """.utf8)
        try initial.write(to: url)
        let cache = CodexSessionReaderCache()
        let beforeSleep = Date()
        check(cache.shouldRead(url: url, modifiedAt: beforeSleep, now: beforeSleep), "Recent local rollout is discovered")
        check(cache.read(url: url)?.turnID == "local-turn", "Local task is cached before sleep")
        let afterSleep = beforeSleep.addingTimeInterval(36 * 3600)
        check(cache.shouldRead(url: url, modifiedAt: beforeSleep, now: afterSleep), "A known active task survives sleep longer than the discovery window")
        cache.retainOnly([url.path])
        check(cache.read(url: url)?.terminalState == nil, "A quiet active task keeps its turn after wake")
        let coldCache = CodexSessionReaderCache()
        check(!coldCache.shouldRead(url: url, modifiedAt: beforeSleep, now: afterSleep), "Old untracked rollouts do not become phantom tasks")

        // 模拟休眠期间完成，醒来时终态文件本身也早已超过 10 分钟。
        let complete = Data("""
        {"timestamp":"2026-10-26T02:00:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"local-turn"}}

        """.utf8)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: complete)
        try handle.close()
        check(cache.shouldRead(url: url, modifiedAt: beforeSleep.addingTimeInterval(3600), now: afterSleep), "A stale completion file is still read for its tracked turn")
        check(cache.read(url: url)?.terminalState == .completed, "Completion during sleep is recovered by incremental parsing")
        check(!cache.shouldRead(url: url, modifiedAt: beforeSleep, now: afterSleep), "Finished old tasks no longer bypass the discovery window")
        cache.retainOnly([])
        check(!cache.shouldRead(url: url, modifiedAt: beforeSleep, now: afterSleep), "Removed files are evicted from tracking")

        try initial.write(to: url)
        let abandoned = CodexSessionReaderCache()
        _ = abandoned.shouldRead(url: url, modifiedAt: beforeSleep, now: beforeSleep)
        _ = abandoned.read(url: url)
        check(abandoned.shouldRead(url: url, modifiedAt: beforeSleep, now: afterSleep), "Sleep is excluded from a tracked task's quiet timeout")
        for second in 1...600 {
            _ = abandoned.shouldRead(url: url, modifiedAt: beforeSleep,
                                     now: afterSleep.addingTimeInterval(Double(second)))
        }
        check(!abandoned.shouldRead(url: url, modifiedAt: beforeSleep, now: afterSleep.addingTimeInterval(601)), "An abandoned task still expires after ten awake minutes without updates")
        let partialCache = CodexSessionReaderCache()
        _ = partialCache.read(url: url)
        let partial = try FileHandle(forWritingTo: url)
        try partial.seekToEnd()
        try partial.write(contentsOf: complete.prefix(complete.count / 2))
        check(partialCache.read(url: url)?.terminalState == nil, "Partial terminal JSON does not drop an active turn")
        try partial.write(contentsOf: complete.dropFirst(complete.count / 2))
        try partial.close()
        check(partialCache.read(url: url)?.terminalState == .completed, "A terminal line split across polls is recovered")

        let batchURL = directory.appendingPathComponent("batch.jsonl")
        let ignoredLine = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"irrelevant\"}}\n"
        let prefix = Data((String(repeating: ignoredLine, count: 10_000) + "\n").utf8) + initial
        let batchCache = CodexSessionReaderCache()
        try (prefix + complete.prefix(complete.count / 2)).write(to: batchURL)
        check(batchCache.read(url: batchURL)?.turnID == "local-turn", "A large batch and empty lines retain the latest turn")
        check(batchCache.read(url: batchURL)?.terminalState == nil, "An unfinished tail in a large batch is not parsed early")
        let batchHandle = try FileHandle(forWritingTo: batchURL)
        try batchHandle.seekToEnd()
        try batchHandle.write(contentsOf: complete.dropFirst(complete.count / 2))
        try batchHandle.close()
        check(batchCache.read(url: batchURL)?.terminalState == .completed, "The unfinished tail completes on the next incremental read")
        try initial.write(to: batchURL)
        check(batchCache.read(url: batchURL)?.terminalState == nil, "Truncating a large log clears its old terminal state")

        let server = try RecoverySocketServer()
        var clock = beforeSleep
        let reader = CodexAppStatusReader(socketPath: server.path, logDirectory: directory, now: { clock })
        check(reader.readTasks().isEmpty, "Connecting does not invent remote state")
        try server.acceptClient()
        check(server.messages().contains { $0["method"] as? String == "initialize" }, "Initial socket handshake is sent")
        try server.send(["type": "response", "method": "initialize", "result": ["clientId": "test-client"]])
        try server.send(["type": "broadcast", "method": "thread-stream-following-changed", "params": [
            "hostId": "remote-host", "conversationId": "remote-thread", "following": true
        ]])
        try server.send(snapshot(status: "inProgress", revision: 4))
        check(reader.readTasks().first?.state == .working, "Remote task is observed before sleep")
        check(server.messages().contains(where: isRecoveryFollow), "Reader follows the remote owner")

        // 不发送任何系统通知，验证轮询间隔可以兜底恢复旧但仍打开的 socket。
        clock = afterSleep
        check(reader.readTasks().isEmpty, "A polling gap discards the stale remote projection")
        try server.acceptClient()
        check(server.messages().contains { $0["method"] as? String == "initialize" }, "A missed wake notification still causes a new handshake")
        try server.send(["type": "response", "method": "initialize", "result": ["clientId": "recovered-client"]])
        _ = reader.readTasks()
        let recoveryMessages = server.messages()
        check(recoveryMessages.contains(where: isRecoveryFollow), "Reconnect restores known subscriptions even without discovery logs or owner broadcasts")
        check(!recoveryMessages.contains { ($0["params"] as? [String: Any])?["following"] as? Bool == false }, "Discovery cannot immediately cancel a restoring subscription")
        try server.send(snapshot(status: "completed", revision: 9))
        check(reader.readTasks().first?.state == .completed, "A fresh snapshot recovers completion missed during sleep")

        reader.reconnect()
        check(reader.readTasks().isEmpty, "Explicit wake recovery also clears the previous projection")
        try server.acceptClient()
        _ = server.messages()
        try server.send(["type": "response", "method": "initialize", "result": ["clientId": "wake-client"]])
        _ = reader.readTasks()
        check(server.messages().contains(where: isRecoveryFollow), "Explicit wake recovery re-subscribes immediately without the reconnect backoff")
        try server.send(snapshot(status: "inProgress", revision: 1))
        check(reader.readTasks().first?.state == .working, "Reconnected subscriptions accept a fresh revision sequence")
        return assertions
    }

    private static func isRecoveryFollow(_ message: [String: Any]) -> Bool {
        let params = message["params"] as? [String: Any]
        return message["method"] as? String == "thread-stream-following-changed"
            && params?["hostId"] as? String == "remote-host"
            && params?["conversationId"] as? String == "remote-thread"
            && params?["following"] as? Bool == true
    }

    private static func snapshot(status: String, revision: Int) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
         "sourceClientId": "owner", "params": ["hostId": "remote-host", "conversationId": "remote-thread",
         "change": ["type": "snapshot", "revision": revision, "conversationState": [
            "id": "remote-thread", "title": "Recovery fixture",
            "turns": [["turnId": "remote-turn", "status": status, "turnStartedAtMs": 1_792_932_561_000.0]]
         ]]]]
    }
}

/// 使用独立的 Unix socket 模拟状态流；不连接正在运行的 Codex 或修改真实任务。
private final class RecoverySocketServer {
    let path = "/tmp/di-\(UUID().uuidString).sock"
    private let listener: Int32
    private var client: Int32 = -1
    private var incoming = Data()

    init() throws {
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(listener, 4) == 0 else { throw POSIXError(.EIO) }
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
    }

    deinit {
        if client >= 0 { Darwin.close(client) }
        Darwin.close(listener)
        unlink(path)
    }

    func acceptClient() throws {
        if client >= 0 { Darwin.close(client) }
        client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = fcntl(client, F_SETFL, O_NONBLOCK)
        incoming.removeAll()
    }

    func send(_ message: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: message)
        var count = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }
        frame.append(body)
        let sent = frame.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
        guard sent == frame.count else { throw POSIXError(.EIO) }
    }

    func messages() -> [[String: Any]] {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            incoming.append(contentsOf: buffer.prefix(count))
        }
        var result: [[String: Any]] = []
        while incoming.count >= 4 {
            let size = incoming.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            guard incoming.count >= size + 4 else { break }
            let body = Data(incoming.dropFirst(4).prefix(size))
            incoming.removeFirst(size + 4)
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { result.append(message) }
        }
        return result
    }
}
