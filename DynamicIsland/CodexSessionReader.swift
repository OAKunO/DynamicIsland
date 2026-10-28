import Foundation

struct CodexSessionTurnState {
    let turnID: String
    let cwd: String?
    let startedAt: Date
    let endedAt: Date?
    let terminalState: CodexTaskSnapshot.State?
    let isInternalTask: Bool
}

/// rollout JSONL 的增量解析缓存。每个文件只读取新追加的字节，既不重复读取
/// 已经解析过的内容，也不会像固定尾部窗口那样漏掉文件开头的 turn_context。
final class CodexSessionReaderCache {
    private var readers: [String: CodexSessionFileReader] = [:]
    private struct Observation {
        var modifiedAt: Date
        var checkedAt: Date
        var quietSeconds: TimeInterval
    }
    private var observations: [String: Observation] = [:]

    func shouldRead(url: URL, modifiedAt: Date, now: Date) -> Bool {
        // 轮询中断不计入已知任务的静默超时。正常轮询时仍有上限，避免没有写入
        // 终态的崩溃会话永久显示为工作中；未跟踪的历史文件仍按 mtime 筛选。
        let age = max(0, now.timeIntervalSince(modifiedAt))
        var observation = observations[url.path] ?? Observation(
            modifiedAt: modifiedAt, checkedAt: now, quietSeconds: age
        )
        if modifiedAt != observation.modifiedAt {
            observation.quietSeconds = 0
        } else {
            let gap = max(0, now.timeIntervalSince(observation.checkedAt))
            if gap <= 15 { observation.quietSeconds += gap }
        }
        observation.modifiedAt = modifiedAt
        observation.checkedAt = now
        observations[url.path] = observation
        return age < 600 || (readers[url.path]?.isWorking == true && observation.quietSeconds < 600)
    }

    func read(url: URL) -> CodexSessionTurnState? {
        let key = url.path
        let reader = readers[key] ?? CodexSessionFileReader()
        let state = reader.read(url: url)
        readers[key] = reader
        return state
    }

    /// 只保留本轮回溯到的文件，避免应用长时间运行时缓存无限增长。
    func retainOnly(_ paths: Set<String>) {
        readers = readers.filter { paths.contains($0.key) }
        observations = observations.filter { paths.contains($0.key) }
    }
}

private final class CodexSessionFileReader {
    /// 单行 JSONL 超过该大小说明文件异常，丢弃残余而不是无限堆积。
    private static let maximumPendingBytes = 32 * 1024 * 1024

    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var offset: UInt64 = 0
    private var pending = Data()
    private var latestTurnID: String?
    private var latestCWD: String?
    private var latestModel: String?
    private var startedAtByTurn: [String: Date] = [:]
    private var terminalStates: [String: CodexTaskSnapshot.State] = [:]
    private var terminalDates: [String: Date] = [:]

    var isWorking: Bool {
        guard let state = currentState else { return false }
        return state.terminalState == nil && !state.isInternalTask
    }

    func read(url: URL) -> CodexSessionTurnState? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return currentState }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        // 文件被截断或轮换时从头重建，避免沿用旧内容。
        if size < offset { reset() }
        if size > offset, (try? handle.seek(toOffset: offset)) != nil,
           let data = try? handle.readToEnd() {
            offset += UInt64(data.count)
            consume(data)
        }
        return currentState
    }

    private func reset() {
        offset = 0
        pending.removeAll(keepingCapacity: false)
        latestTurnID = nil
        latestCWD = nil
        latestModel = nil
        startedAtByTurn.removeAll(keepingCapacity: false)
        terminalStates.removeAll(keepingCapacity: false)
        terminalDates.removeAll(keepingCapacity: false)
    }

    private func consume(_ data: Data) {
        let buffer = pending.isEmpty ? data : pending + data
        pending = Data()
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            parse(line: Data(buffer[lineStart..<newline]))
            lineStart = buffer.index(after: newline)
        }
        // Copy only the unfinished tail, rather than the entire remaining log
        // after every line. A large initial rollout stays linear in its size.
        if buffer.distance(from: lineStart, to: buffer.endIndex) <= Self.maximumPendingBytes {
            pending = Data(buffer[lineStart...])
        }
    }

    private func parse(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return }

        if type == "turn_context", let turnID = payload["turn_id"] as? String {
            latestTurnID = turnID
            latestCWD = payload["cwd"] as? String
            latestModel = payload["model"] as? String
            if let timestamp = object["timestamp"] as? String,
               let date = timestampFormatter.date(from: timestamp) {
                startedAtByTurn[turnID] = date
            }
        } else if type == "event_msg", let turnID = payload["turn_id"] as? String {
            let eventType = payload["type"] as? String
            if eventType == "task_started" {
                // turn_context 可能晚于 task_started 写入，先兜底记录当前 turn。
                if latestTurnID == nil {
                    latestTurnID = turnID
                    if let started = (payload["started_at"] as? NSNumber)?.doubleValue {
                        startedAtByTurn[turnID] = Date(timeIntervalSince1970: started)
                    }
                }
            } else if eventType == "task_complete" || eventType == "turn_aborted" {
                terminalStates[turnID] = eventType == "task_complete" ? .completed : .interrupted
                if let timestamp = object["timestamp"] as? String,
                   let date = timestampFormatter.date(from: timestamp) {
                    terminalDates[turnID] = date
                }
            }
        }
    }

    private var currentState: CodexSessionTurnState? {
        guard let turnID = latestTurnID else { return nil }
        return CodexSessionTurnState(
            turnID: turnID,
            cwd: latestCWD,
            startedAt: startedAtByTurn[turnID] ?? .distantPast,
            endedAt: terminalDates[turnID],
            terminalState: terminalStates[turnID],
            // 审批与自动审查也会产生 turn_context，但不应算作用户任务。
            isInternalTask: latestModel == "codex-auto-review"
        )
    }
}
