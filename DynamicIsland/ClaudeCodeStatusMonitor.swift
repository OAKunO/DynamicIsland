import AppKit
import Combine
import Darwin

struct ClaudeCodeTaskSnapshot: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case working, waiting, completed, interrupted

        var label: String {
            switch self {
            case .working: "正在工作"
            case .waiting: "待确认"
            case .completed: "已完成"
            case .interrupted: "已中断"
            }
        }

        var priority: Int {
            switch self {
            case .working: 0
            case .waiting: 1
            case .completed: 2
            case .interrupted: 3
            }
        }

        var symbolName: String {
            switch self {
            case .working: "sparkles"
            case .waiting: "circle.fill"
            case .completed: "checkmark.circle.fill"
            case .interrupted: "stop.circle.fill"
            }
        }
    }

    let id: String
    let title: String
    let projectName: String
    let cwd: String
    let processID: Int32
    let state: State
    let startedAt: Date
    let updatedAt: Date
}

private struct ClaudeSessionFile: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let startedAt: Double
    let updatedAt: Double?
    let statusUpdatedAt: Double?
    let status: String
    let messagingSocketPath: String?
}

final class ClaudeCodeStatusMonitor: ObservableObject {
    @Published private(set) var tasks: [ClaudeCodeTaskSnapshot] = []

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var knownWorking: [String: ClaudeCodeTaskSnapshot] = [:]
    private var lastActiveAt: [String: Date] = [:]
    private var terminalTasks: [String: (snapshot: ClaudeCodeTaskSnapshot, expiresAt: Date)] = [:]
    private let unreadCompletions = UnreadCompletionStore<ClaudeCodeTaskSnapshot>(provider: "claude")
    private let worker = DispatchQueue(label: "DynamicIsland.ClaudeCodeStatus", qos: .utility)
    /// 「打开 Claude」涉及的 lsof / AppleScript 都是同步阻塞调用，单独放一个队列，
    /// 既不会卡主线程，也不会拖慢状态轮询。
    private let openQueue = DispatchQueue(label: "DynamicIsland.ClaudeCodeOpen", qos: .userInitiated)

    var task: ClaudeCodeTaskSnapshot? { tasks.first }
    var activeTasks: [ClaudeCodeTaskSnapshot] { tasks.filter { $0.state == .working } }
    var waitingTasks: [ClaudeCodeTaskSnapshot] { tasks.filter { $0.state == .waiting } }
    var completedTasks: [ClaudeCodeTaskSnapshot] { tasks.filter { $0.state == .completed } }
    var activeTaskCount: Int { activeTasks.count }
    var ongoingTaskCount: Int { activeTasks.count + waitingTasks.count }
    var isVisible: Bool { !tasks.isEmpty }
    var isWorking: Bool { !activeTasks.isEmpty }
    var hasUnreadCompletion: Bool { isPreview ? tasks.contains { $0.state == .completed } : !unreadCompletions.tasks.isEmpty }
    var compactStatusText: String {
        activeTaskCount > 1 ? "\(activeTaskCount) 个任务" : task?.state.label ?? "Claude"
    }
    var elapsedText: String { task.map(elapsedText(for:)) ?? "" }

    private var isPreview = false

    init(previewTasks: [ClaudeCodeTaskSnapshot]? = nil) {
        if let previewTasks {
            isPreview = true
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
                    as? NSRunningApplication else { return }
            let activatedPID = application.processIdentifier
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.unreadCompletions.tasks.contains(where: {
                          Self.guiAncestor(of: $0.processID)?.processIdentifier == activatedPID
                      }) else { return }
                self.markCompletionsViewed()
            }
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
    }

    func elapsedText(for task: ClaudeCodeTaskSnapshot) -> String {
        let endDate = task.state == .working ? Date() : task.updatedAt
        return AgentElapsedFormatter.text(from: task.startedAt, to: endDate)
    }

    func openClaudeCode() {
        guard let task else { return }
        let processID = task.processID
        let cwd = task.cwd
        markCompletionsViewed()

        // lsof 与 AppleScript 都是同步阻塞调用，全部放到后台队列执行；
        // 只有最终激活 App / 打开 Terminal 回到主线程。
        openQueue.async {
            if let tty = Self.terminalTTY(for: processID), Self.activateTerminalTab(tty: tty) {
                return
            }
            DispatchQueue.main.async {
                if Self.activateGUIAncestor(of: processID) {
                    return
                }

                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open(
                    [URL(fileURLWithPath: cwd)],
                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                    configuration: configuration
                )
            }
        }
    }

    private func markCompletionsViewed() {
        guard hasUnreadCompletion else { return }
        unreadCompletions.markViewed()
        terminalTasks = terminalTasks.filter { $0.value.snapshot.state != .completed }
        publishTasks()
    }

    private func refresh() {
        worker.async { [weak self] in
            let snapshots = Self.readActiveSessions()
            DispatchQueue.main.async { self?.accept(snapshots) }
        }
    }

    private func accept(_ snapshots: [ClaudeCodeTaskSnapshot]?) {
        let now = Date()
        guard let snapshots else {
            terminalTasks = terminalTasks.filter { $0.value.expiresAt > now }
            publishTasks()
            return
        }

        let currentIDs = Set(snapshots.map(\.id))
        for snapshot in snapshots {
            var normalized = snapshot
            if let previous = knownWorking[snapshot.id] {
                let adjustedStart: Date
                if previous.state == .waiting, snapshot.state == .working {
                    // 恢复工作时扣除等待用户确认的时间，计时从冻结值继续。
                    adjustedStart = previous.startedAt.addingTimeInterval(
                        snapshot.updatedAt.timeIntervalSince(previous.updatedAt)
                    )
                } else {
                    adjustedStart = previous.startedAt
                }
                normalized = ClaudeCodeTaskSnapshot(
                    id: snapshot.id,
                    title: snapshot.title,
                    projectName: snapshot.projectName,
                    cwd: snapshot.cwd,
                    processID: snapshot.processID,
                    state: snapshot.state,
                    startedAt: adjustedStart,
                    updatedAt: snapshot.updatedAt
                )
            }
            knownWorking[normalized.id] = normalized
            lastActiveAt[normalized.id] = now
            terminalTasks.removeValue(forKey: normalized.id)
        }
        for (id, previous) in knownWorking where !currentIDs.contains(id) {
            // Claude 会先把 session 写为 idle，再把 AskUserQuestion/权限请求
            // 追加到 JSONL。给两份文件一个短暂的一致性窗口，避免中间态被
            // 闪判为“已完成”。下一轮读到待确认后会继续保留该任务。
            if now.timeIntervalSince(lastActiveAt[id] ?? now) < 3 {
                continue
            }
            let completed = ClaudeCodeTaskSnapshot(
                id: previous.id,
                title: previous.title,
                projectName: previous.projectName,
                cwd: previous.cwd,
                processID: previous.processID,
                state: .completed,
                startedAt: previous.startedAt,
                updatedAt: now
            )
            terminalTasks[id] = (completed, now.addingTimeInterval(5))
            unreadCompletions.record(completed)
            knownWorking.removeValue(forKey: id)
            lastActiveAt.removeValue(forKey: id)
        }
        terminalTasks = terminalTasks.filter { $0.value.expiresAt > now }
        publishTasks()
    }

    private func publishTasks() {
        let snapshots = Array(knownWorking.values) + terminalTasks.values.map(\.snapshot)
            + unreadCompletions.tasks
        let grouped = Dictionary(grouping: snapshots, by: \.id)
        tasks = grouped.values.compactMap { group in
            group.min { $0.state.priority < $1.state.priority }
        }.sorted {
            if $0.state.priority != $1.state.priority { return $0.state.priority < $1.state.priority }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private static func readActiveSessions() -> [ClaudeCodeTaskSnapshot]? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let decoder = JSONDecoder()
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(ClaudeSessionFile.self, from: data),
                  sessionIsAlive(session) else { return nil }

            let state: ClaudeCodeTaskSnapshot.State
            if session.status == "busy" {
                state = .working
            } else if session.status == "waiting" {
                // Claude Code 2.1.263+ 会在选择题、权限或回车确认时
                // 直接暴露 waiting，不需要通过 idle 猜测。
                state = .waiting
            } else if session.status == "idle", transcriptIsWaiting(for: session) {
                state = .waiting
            } else {
                return nil
            }

            let projectName = URL(fileURLWithPath: session.cwd).lastPathComponent
            let cleanName = session.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClaudeCodeTaskSnapshot(
                id: session.sessionId,
                title: cleanName?.isEmpty == false ? cleanName! : "Claude Code 任务",
                projectName: projectName.isEmpty ? "Claude Code" : projectName,
                cwd: session.cwd,
                processID: session.pid,
                state: state,
                startedAt: date(fromMilliseconds: session.statusUpdatedAt ?? session.startedAt),
                updatedAt: date(fromMilliseconds: session.updatedAt ?? session.statusUpdatedAt ?? session.startedAt)
            )
        }
    }

    private static func date(fromMilliseconds value: Double) -> Date {
        Date(timeIntervalSince1970: value / 1_000)
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func sessionIsAlive(_ session: ClaudeSessionFile) -> Bool {
        if processIsAlive(session.pid) { return true }
        // Claude Code 的 CLI 进程可能运行在宿主隔离域中，PID 对本应用不可见；
        // 此时会话通信 socket 才是可靠的存活标志。
        guard let socketPath = session.messagingSocketPath, !socketPath.isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: socketPath)
    }

    private static func transcriptIsWaiting(for session: ClaudeSessionFile) -> Bool {
        let projectDirectory = session.cwd.replacingOccurrences(of: "/", with: "-")
        let transcriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(projectDirectory, isDirectory: true)
            .appendingPathComponent("\(session.sessionId).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: transcriptURL) else { return false }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let maximumTailBytes: UInt64 = 128 * 1_024
        let start = end > maximumTailBytes ? end - maximumTailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else { return false }
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(...newline)
        }

        var resolvedToolIDs = Set<String>()
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }
            let content = message["content"] as? [[String: Any]] ?? []

            if role == "user" {
                for item in content where item["type"] as? String == "tool_result" {
                    if let id = item["tool_use_id"] as? String { resolvedToolIDs.insert(id) }
                }
                continue
            }
            guard role == "assistant" else { continue }
            if message["stop_reason"] as? String == "end_turn" { return false }
            for item in content where item["type"] as? String == "tool_use" {
                guard let id = item["id"] as? String else { continue }
                if !resolvedToolIDs.contains(id) { return true }
            }
        }
        return false
    }

    private static func activateGUIAncestor(of processID: Int32) -> Bool {
        guard let application = guiAncestor(of: processID) else { return false }
        return application.activate(options: [.activateAllWindows])
    }

    private static func guiAncestor(of processID: Int32) -> NSRunningApplication? {
        var pid = processID
        for _ in 0..<24 {
            if let application = NSRunningApplication(processIdentifier: pid),
               application.activationPolicy == .regular {
                return application
            }
            var info = proc_bsdinfo()
            let result = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard result > 0, info.pbi_ppid > 1, info.pbi_ppid != pid else { break }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }

    nonisolated private static func terminalTTY(for processID: Int32) -> String? {
        guard processID > 0 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(processID), "-Fn"]
        guard let data = ProcessRunner.readStandardOutput(of: process, timeout: 5,
                                                         requiresSuccessfulExit: false),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .map(String.init)
            .first { $0.hasPrefix("n/dev/ttys") }?
            .dropFirst()
            .description
    }

    nonisolated private static func activateTerminalTab(tty: String) -> Bool {
        guard tty.range(of: #"^/dev/ttys[0-9]+$"#, options: .regularExpression) != nil else {
            return false
        }

        let terminalScript = """
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is "\(tty)" then
                        set selected tab of terminalWindow to terminalTab
                        set index of terminalWindow to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        if runActivationScript(terminalScript) { return true }

        let iTermScript = """
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if tty of terminalSession is "\(tty)" then
                            select terminalSession
                            select terminalTab
                            select terminalWindow
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
        return runActivationScript(iTermScript)
    }

    nonisolated private static func runActivationScript(_ source: String) -> Bool {
        AppleScriptRunner.run(source)?.booleanValue == true
    }
}
