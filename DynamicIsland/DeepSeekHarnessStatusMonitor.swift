import AppKit
import Combine

struct DeepSeekHarnessTaskSnapshot: Codable, Equatable, Identifiable {
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
            case .waiting: 0
            case .working: 1
            case .completed: 2
            case .interrupted: 3
            }
        }

        var symbolName: String {
            switch self {
            case .working: "fish.fill"
            case .waiting: "exclamationmark.circle.fill"
            case .completed: "checkmark.circle.fill"
            case .interrupted: "stop.circle.fill"
            }
        }
    }

    let id: String
    let title: String
    let projectName: String
    let cwd: String
    let state: State
    let startedAt: Date
    let updatedAt: Date
}

private struct DeepSeekProjectionMetadata {
    let id: String
    let title: String
    let cwd: String
    let cacheModifiedAt: Date
    let logModifiedAt: Date
    let mayBeActive: Bool
    let logURL: URL
}

private struct DeepSeekLogReading: Decodable {
    let id: String
    let state: String
    let cwd: String
    let startedAt: Double
    let updatedAt: Double
}

final class DeepSeekHarnessStatusMonitor: ObservableObject {
    @Published private(set) var tasks: [DeepSeekHarnessTaskSnapshot] = []

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var knownOngoing: [String: DeepSeekHarnessTaskSnapshot] = [:]
    private var terminalTasks: [String: (snapshot: DeepSeekHarnessTaskSnapshot, expiresAt: Date)] = [:]
    private let unreadCompletions = UnreadCompletionStore<DeepSeekHarnessTaskSnapshot>(provider: "deepseek")
    private let worker = DispatchQueue(label: "DynamicIsland.DeepSeekHarnessStatus", qos: .utility)

    var task: DeepSeekHarnessTaskSnapshot? { tasks.first }
    var workingTasks: [DeepSeekHarnessTaskSnapshot] { tasks.filter { $0.state == .working } }
    var waitingTasks: [DeepSeekHarnessTaskSnapshot] { tasks.filter { $0.state == .waiting } }
    var ongoingTasks: [DeepSeekHarnessTaskSnapshot] {
        tasks.filter { $0.state == .working || $0.state == .waiting }
    }
    var ongoingTaskCount: Int { ongoingTasks.count }
    var isVisible: Bool { !tasks.isEmpty }
    var isWorking: Bool { !workingTasks.isEmpty }
    var isWaiting: Bool { !waitingTasks.isEmpty }
    var hasUnreadCompletion: Bool { isPreview ? tasks.contains { $0.state == .completed } : !unreadCompletions.tasks.isEmpty }

    private var isPreview = false

    init(previewTasks: [DeepSeekHarnessTaskSnapshot]? = nil) {
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
                    as? NSRunningApplication,
                  Self.isDeepSeekHarnessApplication(application) else { return }
            self?.markCompletionsViewed()
        }
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func elapsedText(for task: DeepSeekHarnessTaskSnapshot) -> String {
        let endpoint = task.state == .working ? Date() : task.updatedAt
        return AgentElapsedFormatter.text(from: task.startedAt, to: endpoint)
    }

    func openDeepSeekHarness() {
        if let runningApplication = Self.runningDeepSeekHarnessApplication() {
            runningApplication.unhide()
            if runningApplication.activate(options: [.activateAllWindows]) {
                markCompletionsViewed()
                return
            }
        }

        if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "local.deepseek-harness.launcher"
        ) {
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init()) { [weak self] application, _ in
                guard application != nil else { return }
                DispatchQueue.main.async { self?.markCompletionsViewed() }
            }
            markCompletionsViewed()
            return
        }

        // 应用未注册到 Launch Services 时，至少打开当前任务目录作为后备入口。
        if let task {
            NSWorkspace.shared.open(URL(fileURLWithPath: task.cwd))
        }
    }

    private func markCompletionsViewed() {
        guard hasUnreadCompletion else { return }
        unreadCompletions.markViewed()
        terminalTasks = terminalTasks.filter { $0.value.snapshot.state != .completed }
        publishTasks()
    }

    private static func runningDeepSeekHarnessApplication() -> NSRunningApplication? {
        for application in NSWorkspace.shared.runningApplications {
            if isDeepSeekHarnessApplication(application) { return application }
        }
        return nil
    }

    private static func isDeepSeekHarnessApplication(_ application: NSRunningApplication) -> Bool {
        guard application.activationPolicy != .prohibited else { return false }
        if application.bundleIdentifier == "local.deepseek-harness.launcher" {
            return true
        }

        // 本地开发版以通用 com.github.Electron 身份运行，只能结合其
        // 实际 bundle/executable 路径识别，避免激活其他 Electron 应用。
        let applicationPath = (
            application.bundleURL?.path ?? application.executableURL?.path ?? ""
        ).lowercased()
        let applicationName = (application.localizedName ?? "").lowercased()
        return applicationPath.contains("/deepseek-harness/") ||
            applicationName.contains("deepseek harness")
    }

    private func refresh() {
        let knownIDs = Set(knownOngoing.keys)
        worker.async { [weak self] in
            let snapshots = Self.readSessions(knownIDs: knownIDs)
            DispatchQueue.main.async { self?.accept(snapshots) }
        }
    }

    private func accept(_ snapshots: [DeepSeekHarnessTaskSnapshot]?) {
        let now = Date()
        guard let snapshots else {
            terminalTasks = terminalTasks.filter { $0.value.expiresAt > now }
            publishTasks()
            if hasUnreadCompletion,
               let application = NSWorkspace.shared.frontmostApplication,
               Self.isDeepSeekHarnessApplication(application) {
                markCompletionsViewed()
            }
            return
        }

        let ongoing = snapshots.filter { $0.state == .working || $0.state == .waiting }
        let terminalByID = Dictionary(uniqueKeysWithValues: snapshots
            .filter { $0.state == .completed || $0.state == .interrupted }
            .map { ($0.id, $0) })
        let currentIDs = Set(ongoing.map(\.id))

        for snapshot in ongoing {
            knownOngoing[snapshot.id] = snapshot
            terminalTasks.removeValue(forKey: snapshot.id)
        }
        for (id, previous) in knownOngoing where !currentIDs.contains(id) {
            let terminal: DeepSeekHarnessTaskSnapshot
            if let reported = terminalByID[id] {
                // turn/end 之后日志投影不再保留 openTurn，并会把 startedAt
                // 回退成最后更新时间。沿用进行中快照的开始时间，完成后
                // 才能冻结在真实耗时，而不是显示 00:00。
                terminal = DeepSeekHarnessTaskSnapshot(
                    id: reported.id,
                    title: reported.title,
                    projectName: reported.projectName,
                    cwd: reported.cwd,
                    state: reported.state,
                    startedAt: previous.startedAt,
                    updatedAt: max(reported.updatedAt, previous.updatedAt)
                )
            } else {
                terminal = DeepSeekHarnessTaskSnapshot(
                    id: previous.id,
                    title: previous.title,
                    projectName: previous.projectName,
                    cwd: previous.cwd,
                    state: .completed,
                    startedAt: previous.startedAt,
                    updatedAt: now
                )
            }
            terminalTasks[id] = (terminal, now.addingTimeInterval(5))
            if terminal.state == .completed {
                unreadCompletions.record(terminal)
            }
            knownOngoing.removeValue(forKey: id)
        }

        terminalTasks = terminalTasks.filter { $0.value.expiresAt > now }
        publishTasks()
        if hasUnreadCompletion,
           let application = NSWorkspace.shared.frontmostApplication,
           Self.isDeepSeekHarnessApplication(application) {
            markCompletionsViewed()
        }
    }

    private func publishTasks() {
        let snapshots = Array(knownOngoing.values) + terminalTasks.values.map(\.snapshot)
            + unreadCompletions.tasks
        let grouped = Dictionary(grouping: snapshots, by: \.id)
        tasks = grouped.values.compactMap { group in
            group.min { $0.state.priority < $1.state.priority }
        }.sorted {
            if $0.state.priority != $1.state.priority { return $0.state.priority < $1.state.priority }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private static func readSessions(knownIDs: Set<String>) -> [DeepSeekHarnessTaskSnapshot]? {
        let allMetadata = projectionMetadata()
        let preferredIDs = Set(allMetadata
            .sorted { $0.logModifiedAt > $1.logModifiedAt }
            .prefix(12)
            .map(\.id))
        let metadata = allMetadata.filter {
            $0.mayBeActive || knownIDs.contains($0.id) || preferredIDs.contains($0.id)
        }
        guard !metadata.isEmpty else { return [] }
        guard let node = nodeExecutable(), let harnessRoot = harnessRoot() else { return nil }

        let script = #"""
        import { readFileSync } from 'node:fs';
        const { scanZstdFrames, createZstdFrameDecoder } = await import(process.argv[1]);
        const result = [];
        for (const path of process.argv.slice(2)) {
          try {
            const source = readFileSync(path);
            let text = '';
            if (path.endsWith('.zstd')) {
              const decoder = createZstdFrameDecoder();
              for (const chunk of decoder.decode(source, scanZstdFrames(source).frames)) text += chunk.toString();
            } else text = source.toString();
            let id = '', cwd = '', openTurn = null, updatedAt = 0;
            const approvals = new Set();
            const pendingCalls = new Map();
            for (const line of text.split('\n')) {
              if (!line) continue;
              const event = JSON.parse(line);
              if (event.type === 'session') { id = event.id; cwd = event.cwd; continue; }
              updatedAt = Math.max(updatedAt, event.time || 0);
              if (event.type === 'turn/start') openTurn = { startedAt: event.time || Date.now() };
              else if (event.type === 'turn/end') openTurn = null;
              else if (event.type === 'approval/asked') approvals.add(event.data.id);
              else if (event.type === 'approval/decided') approvals.delete(event.data.id);
              else if (event.type === 'tool/call') pendingCalls.set(event.data.callId, event.data.name);
              else if (event.type === 'tool/result') {
                const callId = event.data.callId || event.data.message?.source?.callId ||
                  event.data.message?.content?.[0]?.toolCallId;
                if (callId) pendingCalls.delete(callId);
              }
            }
            const awaitsAnswer = [...pendingCalls.values()].some(name =>
              name === 'ask_user_question' || name === 'request_user_input'
            );
            result.push({ id, cwd, state: approvals.size || awaitsAnswer ? 'waiting' : openTurn ? 'working' : 'completed',
              startedAt: openTurn?.startedAt || updatedAt, updatedAt });
          } catch {}
        }
        process.stdout.write(JSON.stringify(result));
        """#

        let process = Process()
        process.executableURL = node
        process.arguments = [
            "--import", harnessRoot.appendingPathComponent("node_modules/tsx/dist/esm/index.mjs").path,
            "-e", script,
            harnessRoot.appendingPathComponent("packages/session/session-persistence-jsonl/src/zstd.ts").path
        ] + metadata.map(\.logURL.path)
        guard let data = ProcessRunner.readStandardOutput(of: process, timeout: 10),
              let readings = try? JSONDecoder().decode([DeepSeekLogReading].self, from: data) else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
        return readings.compactMap { reading in
            guard let item = byID[reading.id] else { return nil }
            let state: DeepSeekHarnessTaskSnapshot.State
            switch reading.state {
            case "waiting": state = .waiting
            case "working": state = .working
            default: state = .completed
            }
            // 冷会话只用于识别刚结束的任务，不重新显示历史记录。
            let lastActivity = max(item.cacheModifiedAt, item.logModifiedAt)
            guard state != .completed || Date().timeIntervalSince(lastActivity) < 15 else { return nil }
            let cwd = reading.cwd.isEmpty ? item.cwd : reading.cwd
            return DeepSeekHarnessTaskSnapshot(
                id: reading.id,
                title: item.title,
                projectName: URL(fileURLWithPath: cwd).lastPathComponent,
                cwd: cwd,
                state: state,
                startedAt: Date(timeIntervalSince1970: reading.startedAt / 1_000),
                updatedAt: Date(timeIntervalSince1970: reading.updatedAt / 1_000)
            )
        }
    }

    private static func projectionMetadata() -> [DeepSeekProjectionMetadata] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheDirectories = [
            home.appendingPathComponent(".dsh/storages/session_projcache/sessions"),
            home.appendingPathComponent("Deepseek-Harness/apps/desktop/.desktop-build/development/home/storages/session_projcache/sessions")
        ]
        var result: [DeepSeekProjectionMetadata] = []
        for cacheDirectory in cacheDirectories {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            let dshHome = cacheDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let logs = sessionLogs(in: dshHome.appendingPathComponent("sessions"))
            for url in urls where url.pathExtension == "json" {
                let id = url.deletingPathExtension().lastPathComponent
                guard let data = try? Data(contentsOf: url),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let record = root["record"] as? [String: Any],
                      let identity = record["identity"] as? [String: Any],
                      let rows = record["rows"] as? [String: Any],
                      let statsRow = rows["sessionStats"] as? [String: Any],
                      let stats = statsRow["val"] as? [String: Any],
                      let logURL = logs[id] else { continue }
                let titleRow = rows["title"] as? [String: Any]
                let title = titleRow?["val"] as? String ?? "DeepSeek Harness 任务"
                let cwd = identity["cwd"] as? String ?? ""
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let logModifiedAt = (try? logURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                result.append(DeepSeekProjectionMetadata(
                    id: id,
                    title: title,
                    cwd: cwd,
                    cacheModifiedAt: modifiedAt,
                    logModifiedAt: logModifiedAt,
                    mayBeActive: !(stats["openStep"] is NSNull),
                    logURL: logURL
                ))
            }
        }
        // 开发版和正式版的 DSH_HOME 可能同时保留同一会话，只读取更新的一份。
        var deduplicated: [String: DeepSeekProjectionMetadata] = [:]
        for item in result {
            if let previous = deduplicated[item.id], previous.logModifiedAt >= item.logModifiedAt {
                continue
            }
            deduplicated[item.id] = item
        }
        return Array(deduplicated.values)
    }

    private static func sessionLogs(in directory: URL) -> [String: URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: URL] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("session"),
                  url.pathExtension == "zstd" || url.pathExtension == "jsonl" else { continue }
            let id = url.deletingLastPathComponent().lastPathComponent
            result[id] = url
        }
        return result
    }

    private static func harnessRoot() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deepseek-Harness")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private static func nodeExecutable() -> URL? {
        let versions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        guard let roots = try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) else { return nil }
        return roots.sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin/node") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
