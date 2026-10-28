import AppKit
import Combine
import SQLite3

private struct CodexReadResult {
    var working: [CodexTaskSnapshot]
    var terminalByExecutionID: [String: CodexTaskSnapshot]
}

private struct CodexLockInfo {
    let id: String
    let modifiedAt: Int64
    var title = ""
    var cwd: String?
}

final class CodexStatusMonitor: ObservableObject {
    @Published private(set) var tasks: [CodexTaskSnapshot] = []
    @Published var isExpanded = false

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var recoveryObservers: [NSObjectProtocol] = []
    private var refreshInProgress = false
    private var reconnectPending = false
    private var knownWorking: [String: CodexTaskSnapshot] = [:]
    private var lastSeenAt: [String: Date] = [:]
    private var terminalTasks: [String: (snapshot: CodexTaskSnapshot, expiresAt: Date)] = [:]
    private let unreadCompletions = UnreadCompletionStore<CodexTaskSnapshot>(provider: "codex")
    private let worker = DispatchQueue(label: "DynamicIsland.CodexStatus", qos: .utility)
    /// 只在 worker 队列上读写，用于增量解析 rollout 文件。
    private let sessionReaderCache = CodexSessionReaderCache()
    private let appStatusReader = CodexAppStatusReader()

    var task: CodexTaskSnapshot? { tasks.first }
    var activeTasks: [CodexTaskSnapshot] { tasks.filter { $0.state == .working } }
    var activeTaskCount: Int { activeTasks.count }
    var isVisible: Bool { !tasks.isEmpty }
    var isWorking: Bool { !activeTasks.isEmpty }
    var hasUnreadCompletion: Bool { isPreview ? tasks.contains { $0.state == .completed } : !unreadCompletions.tasks.isEmpty }
    var compactStatusText: String {
        activeTaskCount > 1 ? "\(activeTaskCount) 个任务正在工作" : task?.state.label ?? "Codex"
    }
    var elapsedText: String { task.map(elapsedText(for:)) ?? "" }

    private var isPreview = false

    init(previewTasks: [CodexTaskSnapshot]? = nil, previewExpanded: Bool = false) {
        if let previewTasks {
            isPreview = true
            isExpanded = previewExpanded
            tasks = previewTasks
            return
        }
        tasks = unreadCompletions.tasks
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  Self.isCodexApplication(application) else { return }
            self?.markCompletionsViewed()
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            recoveryObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh(reconnecting: true) })
        }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        for observer in recoveryObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func elapsedText(for task: CodexTaskSnapshot) -> String {
        let endpoint = task.state == .working ? Date() : task.updatedAt
        return AgentElapsedFormatter.text(from: task.startedAt, to: endpoint)
    }

    func openCodex() {
        let candidates = ["com.openai.codex", "com.openai.chatgpt"]
        if let url = candidates.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] application, _ in
                guard application != nil else { return }
                DispatchQueue.main.async { self?.markCompletionsViewed() }
            }
            markCompletionsViewed()
        }
    }

    private static func isCodexApplication(_ application: NSRunningApplication) -> Bool {
        guard let bundleID = application.bundleIdentifier else { return false }
        return ["com.openai.codex", "com.openai.chatgpt"].contains(bundleID)
    }

    private func markCompletionsViewed() {
        guard hasUnreadCompletion else { return }
        unreadCompletions.markViewed()
        terminalTasks = terminalTasks.filter { $0.value.snapshot.state != .completed }
        publishTasks()
    }

    private func refresh(reconnecting: Bool = false) {
        reconnectPending = reconnectPending || reconnecting
        // 唤醒时通知和定时器可能同时到达，不把过时的读取堆在 worker 中。
        guard !refreshInProgress else { return }
        refreshInProgress = true
        let shouldReconnect = reconnectPending
        reconnectPending = false
        let cache = sessionReaderCache
        let appReader = appStatusReader
        worker.async { [weak self] in
            if shouldReconnect { appReader.reconnect() }
            // Dot / durable 的执行记录不落在本机 sessions 中，直接订阅应用状态。
            let local = Self.readTasks(cache: cache)
            let remote = appReader.readTasks()
            var terminals = local?.terminalByExecutionID ?? [:]
            for task in remote where task.state != .working { terminals[task.id] = task }
            let result = CodexReadResult(
                working: (local?.working ?? []) + remote.filter { $0.state == .working },
                terminalByExecutionID: terminals
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshInProgress = false
                self.accept(result)
                if self.reconnectPending { self.refresh() }
            }
        }
    }

    private func accept(_ result: CodexReadResult?) {
        let now = Date()
        if let result {
            for snapshot in result.working {
                knownWorking[snapshot.id] = snapshot
                lastSeenAt[snapshot.id] = now
                terminalTasks.removeValue(forKey: snapshot.rootThreadID)
            }
            let currentIDs = Set(result.working.map(\.id))
            for (executionID, previous) in knownWorking where !currentIDs.contains(executionID) {
                if let terminal = result.terminalByExecutionID[executionID] {
                    if terminal.state == .completed {
                        unreadCompletions.record(terminal)
                    }
                    terminalTasks[previous.rootThreadID] = (
                        terminal,
                        now.addingTimeInterval(terminal.state == .failed ? 12 : 5)
                    )
                    knownWorking.removeValue(forKey: executionID)
                    lastSeenAt.removeValue(forKey: executionID)
                } else if now.timeIntervalSince(lastSeenAt[executionID] ?? .distantPast) >= 6 {
                    knownWorking.removeValue(forKey: executionID)
                    lastSeenAt.removeValue(forKey: executionID)
                }
            }
        }

        terminalTasks = terminalTasks.filter { $0.value.expiresAt > now || isExpanded }
        publishTasks()
        if hasUnreadCompletion,
           let application = NSWorkspace.shared.frontmostApplication,
           Self.isCodexApplication(application) {
            markCompletionsViewed()
        }
    }

    private func publishTasks() {
        let snapshots = Array(knownWorking.values) + terminalTasks.values.map(\.snapshot)
            + unreadCompletions.tasks
        let grouped = Dictionary(grouping: snapshots, by: \.rootThreadID)
        tasks = grouped.values.compactMap { group in
            group.min { Self.isHigherPriority($0, $1) }
        }.sorted { Self.isHigherPriority($0, $1) }
    }

    private static func isHigherPriority(_ lhs: CodexTaskSnapshot, _ rhs: CodexTaskSnapshot) -> Bool {
        lhs.state.priority != rhs.state.priority
            ? lhs.state.priority < rhs.state.priority
            : lhs.updatedAt > rhs.updatedAt
    }

    private static func readTasks(cache: CodexSessionReaderCache) -> CodexReadResult? {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let historyPath = directory.appendingPathComponent("thread_history_1.sqlite").path
        let statePath = directory.appendingPathComponent("state_5.sqlite").path
        guard FileManager.default.fileExists(atPath: historyPath), FileManager.default.fileExists(atPath: statePath) else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(historyPath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { return nil }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        let escapedPath = statePath.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(database, "ATTACH DATABASE '\(escapedPath)' AS state", nil, nil, nil) == SQLITE_OK else { return nil }

        let lockDirectory = directory.appendingPathComponent("thread-writer-locks")
        var locks = (try? FileManager.default.contentsOfDirectory(at: lockDirectory, includingPropertiesForKeys: [.contentModificationDateKey]))?.compactMap { url -> CodexLockInfo? in
            guard url.pathExtension == "lock" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard id.allSatisfy({ $0.isHexDigit || $0 == "-" }),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return CodexLockInfo(id: id, modifiedAt: Int64(date.timeIntervalSince1970))
        } ?? []

        if !locks.isEmpty {
            let ids = locks.map { "'\($0.id)'" }.joined(separator: ",")
            var metadata: OpaquePointer?
            if sqlite3_prepare_v2(database, "SELECT id,title,cwd FROM state.threads WHERE id IN (\(ids))", -1, &metadata, nil) == SQLITE_OK, let metadata {
                defer { sqlite3_finalize(metadata) }
                while sqlite3_step(metadata) == SQLITE_ROW {
                    guard let idText = sqlite3_column_text(metadata, 0),
                          let index = locks.firstIndex(where: { $0.id == String(cString: idText) }) else { continue }
                    if let text = sqlite3_column_text(metadata, 1) { locks[index].title = String(cString: text) }
                    if let text = sqlite3_column_text(metadata, 2) { locks[index].cwd = String(cString: text) }
                }
            }
        }

        let sql = """
        SELECT turns.thread_id,turns.status,turns.started_at,
               COALESCE(turns.completed_at,threads.updated_at,turns.started_at),
               COALESCE(threads.title,''),threads.cwd
        FROM thread_turns turns LEFT JOIN state.threads threads ON threads.id=turns.thread_id
        WHERE turns.started_at >= CAST(strftime('%s','now') AS INTEGER)-86400
        ORDER BY turns.started_at DESC LIMIT 200
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        var working: [CodexTaskSnapshot] = []
        var terminals: [String: CodexTaskSnapshot] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let stateText = sqlite3_column_text(statement, 1),
                  let state = CodexTaskSnapshot.State(rawValue: String(cString: stateText)) else { continue }
            let id = String(cString: idText)
            let started = sqlite3_column_int64(statement, 2)
            let updated = sqlite3_column_int64(statement, 3)
            let directTitle = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            let directCWD = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let matchedLock = locks.min { abs($0.modifiedAt - started) < abs($1.modifiedAt - started) }
                .flatMap { abs($0.modifiedAt - started) <= 180 || $0.id == id ? $0 : nil }
            if state == .working, matchedLock == nil { continue }
            let rootID = matchedLock?.id ?? id
            let cwd = matchedLock?.cwd ?? directCWD
            let lockTitle = matchedLock?.title ?? ""
            let title = !lockTitle.isEmpty ? lockTitle : (directTitle.isEmpty ? "Codex 任务" : directTitle)
            let snapshot = CodexTaskSnapshot(
                id: id, rootThreadID: rootID, title: title,
                projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
                cwd: cwd, state: state,
                startedAt: Date(timeIntervalSince1970: TimeInterval(started)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(updated))
            )
            if state == .working {
                if !working.contains(where: { $0.id == id }) { working.append(snapshot) }
            } else if terminals[id] == nil {
                terminals[id] = snapshot
            }
        }

        // thread_history 是 UI 投影，切换任务时可能保留旧的 inProgress，且其内部
        // execution id 不一定等于用户看到的任务 id。执行器直接写入的 JSONL 才是
        // 活跃任务的事实来源；存在实时会话时，用它替换投影结果，避免同一任务重复。
        let liveSessions = liveSessionTasks(in: directory, locks: locks, cache: cache)
        working = liveSessions.working
        terminals.merge(liveSessions.terminalByExecutionID) { _, live in live }
        return CodexReadResult(working: working, terminalByExecutionID: terminals)
    }

    private static func liveSessionTasks(
        in codexDirectory: URL,
        locks: [CodexLockInfo],
        cache: CodexSessionReaderCache
    ) -> CodexReadResult {
        let sessionsDirectory = codexDirectory.appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return CodexReadResult(working: [], terminalByExecutionID: [:]) }

        let now = Date()
        var snapshots: [CodexTaskSnapshot] = []
        var visitedPaths = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modifiedAt = values.contentModificationDate,
                  cache.shouldRead(url: url, modifiedAt: modifiedAt, now: now),
                  let rootID = firstUUID(in: url.lastPathComponent) else { continue }
            visitedPaths.insert(url.path)

            // rollout 文件可能远大于任意固定窗口：单轮输出超过窗口后，
            // 只读末尾固定字节会丢掉文件开头的 turn_context，把仍在工作的
            // 任务误判为不存在。改为按文件增量解析，只读取新追加的字节。
            guard let state = cache.read(url: url), !state.isInternalTask else { continue }

            let metadata = locks.first(where: { $0.id == rootID })
            let cwd = metadata?.cwd ?? state.cwd
            let title = metadata?.title.isEmpty == false ? metadata!.title : "Codex 任务"
            snapshots.append(CodexTaskSnapshot(
                id: state.turnID,
                rootThreadID: rootID,
                title: title,
                projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
                cwd: cwd,
                state: state.terminalState ?? .working,
                startedAt: state.startedAt,
                updatedAt: state.endedAt ?? modifiedAt
            ))
        }
        cache.retainOnly(visitedPaths)
        // 一个用户任务可能同时产生主执行文件和内部子执行文件。工作中的记录
        // 优先于已结束的子执行；同状态下取最近的一条。
        let canonical = Dictionary(grouping: snapshots, by: \.rootThreadID).values.compactMap { group in
            group.sorted {
                if ($0.state == .working) != ($1.state == .working) { return $0.state == .working }
                return $0.updatedAt > $1.updatedAt
            }.first
        }
        return CodexReadResult(
            working: canonical.filter { $0.state == .working },
            terminalByExecutionID: Dictionary(
                uniqueKeysWithValues: canonical.filter { $0.state != .working }.map { ($0.id, $0) }
            )
        )
    }

    private static func firstUUID(in text: String) -> String? {
        let pattern = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

}
