import Foundation

nonisolated enum IslandExpandedColumn: String, CaseIterable, Identifiable, Sendable {
    case computer, work, music, time, notes, phone, recording
    var id: Self { self }
    var title: String {
        switch self {
        case .computer: "电脑"
        case .work: "工作台"
        case .music: "音乐"
        case .time: "计时"
        case .notes: "备忘录"
        case .phone: "手机"
        case .recording: "录屏"
        }
    }
    var width: CGFloat {
        switch self {
        case .computer: WindowManager.computerColumnWidth
        case .work: WindowManager.workColumnWidth
        case .music: WindowManager.musicColumnWidth
        case .time: WindowManager.expandedSize.width
        case .notes: WindowManager.notesColumnWidth
        case .phone: WindowManager.phoneColumnWidth
        case .recording: WindowManager.recordingColumnWidth
        }
    }
}

/// Merge the closest-width columns only until the workspace fits its budget.
/// Shared by the window, length settings, previews and the actual dashboard.
nonisolated struct IslandExpandedLayout: Equatable, Sendable {
    static let navigationHeight: CGFloat = 26
    struct Group: Identifiable, Equatable, Sendable {
        var columns: [IslandExpandedColumn]
        var id: String { columns.map(\.rawValue).joined(separator: ".") }
        var width: CGFloat { columns.map(\.width).max() ?? 0 }
    }
    let groups: [Group]
    var width: CGFloat { Self.width(of: groups) }
    var isPaged: Bool { groups.contains { $0.columns.count > 1 } }
    var height: CGFloat { WindowManager.expandedSize.height + (isPaged ? Self.navigationHeight : 0) }

    static func columns(for configuration: IslandLengthConfiguration) -> [IslandExpandedColumn] {
        let work = configuration.expandedTaskCount > 0 || !configuration.orderedAgents.isEmpty || configuration.mode == .expandedAgent
        var columns: [IslandExpandedColumn] = []
        if configuration.computer { columns.append(.computer) }
        if work { columns.append(.work) }
        if configuration.music || configuration.mode == .expandedMusic { columns.append(.music) }
        if configuration.showsTimeTools { columns.append(.time) }
        if configuration.showsNotes { columns.append(.notes) }
        if configuration.phone { columns.append(.phone) }
        if configuration.showsRecordingTools { columns.append(.recording) }
        return columns.isEmpty ? [.time] : columns
    }

    init(configuration: IslandLengthConfiguration, maximumWidth: CGFloat = 1_000) {
        var groups = Self.columns(for: configuration).map { Group(columns: [$0]) }
        while Self.width(of: groups) > maximumWidth && groups.count > 1 {
            var bestPair = (0, 1)
            var bestScore = CGFloat.infinity
            for left in groups.indices {
                for right in groups.indices where right > left {
                    let sameSizeClass = (groups[left].width <= 210) == (groups[right].width <= 210)
                    let score = abs(groups[left].width - groups[right].width) + (sameSizeClass ? 0 : 1_000)
                    if score < bestScore {
                        bestScore = score
                        bestPair = (left, right)
                    }
                }
            }
            groups[bestPair.0].columns += groups[bestPair.1].columns
            groups.remove(at: bestPair.1)
        }
        self.groups = groups
    }

    private static func width(of groups: [Group]) -> CGFloat {
        groups.reduce(0) { $0 + $1.width } + CGFloat(max(0, groups.count - 1))
    }
}

/// One page per horizontal gesture; vertical scrolling and momentum never turn pages.
nonisolated struct IslandPageSwipe {
    private var distance = 0.0
    private var didTurnPage = false
    private var lastTimestamp = -Double.infinity

    mutating func consume(deltaX: Double, deltaY: Double, startsGesture: Bool,
                          isMomentum: Bool, timestamp: Double) -> Int? {
        if startsGesture || timestamp - lastTimestamp > 0.3 {
            distance = 0
            didTurnPage = false
        }
        lastTimestamp = timestamp
        guard !isMomentum, !didTurnPage, abs(deltaX) > abs(deltaY) * 1.3 else { return nil }
        if distance * deltaX < 0 { distance = 0 }
        distance += deltaX
        guard abs(distance) >= 45 else { return nil }
        didTurnPage = true
        return distance < 0 ? 1 : -1
    }
}

nonisolated enum IslandLengthCategory: String, CaseIterable, Identifiable, Sendable {
    case agents, music, timer, devices, expanded
    var id: Self { self }
    var title: String {
        switch self {
        case .agents: "AI Agent"
        case .music: "音乐"
        case .timer: "计时器"
        case .devices: "基础与设备"
        case .expanded: "展开页面"
        }
    }
    var symbol: String {
        switch self {
        case .agents: "terminal"
        case .music: "music.note"
        case .timer: "timer"
        case .devices: "powerplug"
        case .expanded: "rectangle.expand.vertical"
        }
    }
}

nonisolated enum IslandAgentStatus: String, CaseIterable, Sendable {
    case working, waiting, completed, failed, interrupted
    var title: String {
        switch self {
        case .working: "工作"
        case .waiting: "待确认"
        case .completed: "已完成"
        case .failed: "失败"
        case .interrupted: "中断"
        }
    }
}

nonisolated enum IslandAgentProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, deepSeek
    var id: Self { self }
    var shortTitle: String { self == .claude ? "Claude" : title }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .deepSeek: "DeepSeek"
        }
    }
    var supportedStatuses: [IslandAgentStatus] {
        self == .codex ? [.working, .completed, .failed, .interrupted]
            : [.working, .waiting, .completed, .interrupted]
    }
}

/// Each visible task status has a count bucket: absent, one, or two-or-more.
/// This retains simultaneous working/waiting/results and the existing layout's
/// single/multiple task distinction without enumerating arbitrary task IDs.
nonisolated struct IslandAgentActivity: Hashable, Sendable, Identifiable {
    let provider: IslandAgentProvider
    let working: Int
    let waiting: Int
    let completed: Int
    let failed: Int
    let interrupted: Int

    init(provider: IslandAgentProvider, statuses: [IslandAgentStatus]) {
        self.provider = provider
        func count(_ status: IslandAgentStatus) -> Int {
            guard provider.supportedStatuses.contains(status) else { return 0 }
            return min(statuses.filter { $0 == status }.count, 2)
        }
        working = count(.working)
        waiting = count(.waiting)
        completed = count(.completed)
        failed = count(.failed)
        interrupted = count(.interrupted)
    }

    var id: String { "\(provider.rawValue):\(working)\(waiting)\(completed)\(failed)\(interrupted)" }
    var taskCount: Int { working + waiting + completed + failed + interrupted }
    var ongoingCount: Int { working + waiting }
    var statusCount: Int { provider.supportedStatuses.filter { count($0) > 0 }.count }
    var isWorking: Bool { working > 0 }
    var isMultipleForLayout: Bool { provider == .codex ? working > 1 : ongoingCount > 1 }

    func count(_ status: IslandAgentStatus) -> Int {
        switch status {
        case .working: working
        case .waiting: waiting
        case .completed: completed
        case .failed: failed
        case .interrupted: interrupted
        }
    }

    var title: String {
        let parts = provider.supportedStatuses.compactMap { status -> String? in
            let value = count(status)
            guard value > 0 else { return nil }
            return "\(status.title) ×\(value == 1 ? "1" : "2+")"
        }
        return "\(provider.title)：\(parts.joined(separator: "、"))"
    }

    static func variants(for provider: IslandAgentProvider) -> [Self] {
        // Four supported statuses, each with three count buckets: 3^4 - 1 = 80.
        (1..<81).map { code in
            var remainder = code
            var statuses: [IslandAgentStatus] = []
            for status in provider.supportedStatuses {
                let count = remainder % 3
                remainder /= 3
                statuses.append(contentsOf: Array(repeating: status, count: count))
            }
            return Self(provider: provider, statuses: statuses)
        }.sorted {
            if $0.taskCount != $1.taskCount { return $0.taskCount < $1.taskCount }
            return $0.id > $1.id
        }
    }
}

nonisolated enum IslandAgentCombination: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, deepSeek, codexClaude, codexDeepSeek, claudeDeepSeek, allThree
    var id: Self { self }
    var providers: [IslandAgentProvider] {
        switch self {
        case .codex: [.codex]
        case .claude: [.claude]
        case .deepSeek: [.deepSeek]
        case .codexClaude: [.codex, .claude]
        case .codexDeepSeek: [.codex, .deepSeek]
        case .claudeDeepSeek: [.claude, .deepSeek]
        case .allThree: IslandAgentProvider.allCases
        }
    }
    var title: String { providers.map(\.title).joined(separator: " + ") }
    static func matching(_ providers: [IslandAgentProvider]) -> Self? {
        allCases.first { Set($0.providers) == Set(providers) }
    }
}

nonisolated enum IslandTimerActivity: String, CaseIterable, Identifiable, Sendable {
    case off, runningMinutes, runningHours, pausedMinutes, pausedHours, alarm
    var id: Self { self }
    var title: String {
        switch self {
        case .off: "无计时器"
        case .alarm: "闹钟已开启"
        case .runningMinutes: "计时运行 · 分秒"
        case .runningHours: "计时运行 · 含小时"
        case .pausedMinutes: "计时暂停 · 分秒"
        case .pausedHours: "计时暂停 · 含小时"
        }
    }
    var hasHours: Bool? {
        switch self {
        case .off, .alarm: nil
        case .runningMinutes, .pausedMinutes: false
        case .runningHours, .pausedHours: true
        }
    }
}

nonisolated enum IslandBatteryActivity: String, CaseIterable, Identifiable, Sendable {
    case normal, charging, low, lowCharging
    var id: Self { self }
    var title: String {
        switch self {
        case .normal: "正常电量"
        case .charging: "充电"
        case .low: "低电量"
        case .lowCharging: "低电量 + 充电"
        }
    }
    var isVisible: Bool { self != .normal }
    var isCharging: Bool { self == .charging || self == .lowCharging }
}

nonisolated enum IslandLengthMode: String, CaseIterable, Identifiable, Sendable {
    case compact, hovered
    case expandedMusic, expandedAgent
    case expandedTimerSetup, expandedTimerRunning, expandedTimerPaused, expandedTimerFinished
    case expandedGreeting
    var id: Self { self }
    var isExpanded: Bool { self != .compact && self != .hovered }
    var title: String {
        switch self {
        case .compact: "收起"
        case .hovered: "待机悬停"
        case .expandedMusic: "展开 · 计时 + 音乐"
        case .expandedAgent: "展开 · 计时 + 工作台"
        case .expandedTimerSetup: "展开 · 计时设置"
        case .expandedTimerRunning: "展开 · 计时运行"
        case .expandedTimerPaused: "展开 · 计时暂停"
        case .expandedTimerFinished: "展开 · 计时完成提醒"
        case .expandedGreeting: "展开 · 解锁问候"
        }
    }
    static var expandedModes: [Self] { allCases.filter(\.isExpanded) }
}

nonisolated struct IslandLengthConfiguration: Hashable, Sendable {
    var mode: IslandLengthMode = .compact
    var agents: [IslandAgentActivity] = []
    var music = false
    var timer: IslandTimerActivity = .off
    var battery: IslandBatteryActivity = .normal
    var usb = false
    var expandedTaskCount = 0
    var pomodoro: IslandTimerActivity = .off
    var enabledAlarmCount = 0
    var showsTimeTools = true
    var recording: IslandTimerActivity = .off
    var showsRecordingTools = true
    var phone = false
    var showsNotes = false
    var computer = false

    var compactAlarmCount: Int { max(enabledAlarmCount, timer == .alarm ? 1 : 0) }
    var compactActivities: [CompactActivity] {
        var activities: [CompactActivity] = []
        if music { activities.append(.audio) }
        if timer.hasHours != nil { activities.append(.timer) }
        if pomodoro.hasHours != nil { activities.append(.pomodoro) }
        if compactAlarmCount > 0 { activities.append(.alarm) }
        if battery.isVisible { activities.append(.battery) }
        if usb { activities.append(.usb) }
        if recording.hasHours != nil { activities.append(.recording) }
        return activities
    }

    var orderedAgents: [IslandAgentActivity] {
        agents.filter { $0.taskCount > 0 }.sorted { $0.provider.rawValue < $1.provider.rawValue }
    }
    var category: IslandLengthCategory {
        if mode.isExpanded { return .expanded }
        if !orderedAgents.isEmpty { return .agents }
        if music { return .music }
        if timer != .off || pomodoro != .off || enabledAlarmCount > 0 || recording != .off { return .timer }
        return .devices
    }
    var key: String {
        if mode.isExpanded {
            if mode == .expandedGreeting || mode == .expandedTimerFinished { return "v2.\(mode.rawValue)" }
            return "v4.\(mode.rawValue)." + IslandExpandedLayout.columns(for: self).map(\.rawValue).joined(separator: ".")
        }
        var components = ["v2", mode.rawValue, orderedAgents.map(\.id).joined(separator: "+"),
                music ? "music" : "silent", timer.rawValue, battery.rawValue,
                usb ? "usb" : "no-usb"]
        if pomodoro != .off { components.append("pomodoro-\(pomodoro.rawValue)") }
        if enabledAlarmCount > 0 { components.append("alarms-\(enabledAlarmCount)") }
        if recording != .off { components.append("recording-\(recording.rawValue)") }
        return components.joined(separator: ".")
    }
    var activityTitle: String {
        var parts = orderedAgents.map(\.title)
        if music { parts.append("音乐播放") }
        if timer != .off { parts.append(timer.title) }
        if pomodoro != .off { parts.append("番茄钟 · \(pomodoro.title)") }
        if enabledAlarmCount > 0 && timer != .alarm { parts.append("闹钟已开启 ×\(enabledAlarmCount)") }
        if battery != .normal { parts.append(battery.title) }
        if usb { parts.append("USB 连接") }
        if recording != .off { parts.append("录屏 · \(recording.hasHours == true ? "时分秒" : "分秒")\(recording == .pausedMinutes || recording == .pausedHours ? " · 暂停" : "")") }
        return parts.isEmpty ? "待机" : parts.joined(separator: " + ")
    }
    var title: String {
        if mode.isExpanded {
            guard mode != .expandedGreeting && mode != .expandedTimerFinished else { return mode.title }
            return mode.title + (phone ? " + 手机" : "") + (computer ? " + 本机" : "")
        }
        if mode == .hovered { return activityTitle == "待机" ? "待机悬停" : "待机悬停 + \(activityTitle)" }
        return activityTitle
    }
    var minimumWidth: Int {
        if !mode.isExpanded { return Int(ceil(WindowManager.defaultSize(for: self).width)) }
        return mode == .expandedGreeting ? Int(max(360, WindowManager.notchGeometry.minimumExpandedWidth))
            : Int(WindowManager.defaultSize(for: self).width)
    }
}

nonisolated struct IslandLengthState: Equatable, Identifiable, Sendable {
    let configuration: IslandLengthConfiguration
    var id: String { key }
    var key: String { configuration.key }
    var title: String { configuration.title }
    var defaultWidth: Int { Int(ceil(WindowManager.defaultSize(for: configuration).width)) }
    var legacyKey: String? { WindowManager.legacyLengthKey(for: configuration) }
}

nonisolated enum IslandAgentStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all, working, waiting, completed, failed, interrupted, mixed
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部状态"
        case .mixed: "多种状态共存"
        default: "含\(IslandAgentStatus(rawValue: rawValue)!.title)"
        }
    }
    func matches(_ activity: IslandAgentActivity) -> Bool {
        if self == .all { return true }
        if self == .mixed { return activity.statusCount > 1 }
        return activity.count(IslandAgentStatus(rawValue: rawValue)!) > 0
    }
    func isSupported(by provider: IslandAgentProvider) -> Bool {
        self == .all || self == .mixed || provider.supportedStatuses.contains {
            $0.rawValue == rawValue
        }
    }
}

nonisolated enum IslandAgentCountFilter: String, CaseIterable, Identifiable, Sendable {
    case all, single, multiple
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部任务数量"
        case .single: "单任务"
        case .multiple: "多任务"
        }
    }
    func matches(_ activity: IslandAgentActivity) -> Bool {
        self == .all || (self == .single ? activity.taskCount == 1 : activity.taskCount > 1)
    }
}

nonisolated struct IslandAgentCatalogFilter: Hashable, Sendable {
    var status: IslandAgentStatusFilter = .all
    var count: IslandAgentCountFilter = .all
}

nonisolated struct IslandLengthCatalogPage: Sendable {
    let states: [IslandLengthState]
    let total: Int
}

/// Mixed-radix indexing permits exhaustive catalog access without materializing
/// hundreds of thousands of combinations. Only a page of rows is constructed.
nonisolated struct IslandLengthCatalogQuery: Hashable, Sendable {
    var category: IslandLengthCategory = .agents
    var combination: IslandAgentCombination = .codex
    var agentFilters: [IslandAgentProvider: IslandAgentCatalogFilter] = [:]
    var music = false
    var timer: IslandTimerActivity = .off
    var battery: IslandBatteryActivity = .normal
    var usb = false
    var phone = false
    var computer = false
    var search = ""
    var modifiedOnly = false
    var focusedConfiguration: IslandLengthConfiguration?

    func page(_ page: Int, size: Int, saved: IslandLengthSettingsSnapshot) -> IslandLengthCatalogPage {
        if let configuration = focusedConfiguration {
            let state = IslandLengthState(configuration: configuration)
            let matches = (!modifiedOnly || saved.isModified(state)) &&
                (search.isEmpty || state.title.localizedCaseInsensitiveContains(search))
            return IslandLengthCatalogPage(states: matches && page == 0 ? [state] : [], total: matches ? 1 : 0)
        }
        let profiles: [[IslandAgentActivity]] = category == .agents
            ? combination.providers.map { provider in
                let filter = agentFilters[provider] ?? IslandAgentCatalogFilter()
                return IslandAgentActivity.variants(for: provider).filter {
                    filter.status.matches($0) && filter.count.matches($0)
                }
            } : []
        let baseCount: Int
        switch category {
        case .agents: baseCount = profiles.reduce(1) { $0 * $1.count }
        case .devices: baseCount = usb ? 1 : 2
        case .expanded: baseCount = IslandLengthMode.expandedModes.count
        default: baseCount = 1
        }
        let start = max(page, 0) * size
        let tokens = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let needsFiltering = !tokens.isEmpty || modifiedOnly
        var results: [IslandLengthState] = []
        var matchedCount = 0
        let indexes = needsFiltering ? 0..<baseCount : min(start, baseCount)..<min(start + size, baseCount)
        for index in indexes {
            if index % 256 == 0, Task.isCancelled { break }
            var configuration = IslandLengthConfiguration(
                music: category == .music || (category == .agents && music),
                timer: category == .timer && timer == .off ? .runningMinutes : timer,
                battery: battery, usb: usb
            )
            switch category {
            case .agents:
                var remainder = index
                configuration.agents = profiles.map { variants in
                    defer { remainder /= variants.count }
                    return variants[remainder % variants.count]
                }
            case .devices:
                configuration.mode = index == 0 ? .compact : .hovered
                configuration.timer = .off
            case .expanded:
                configuration = IslandLengthConfiguration(mode: IslandLengthMode.expandedModes[index], usb: phone, phone: phone, computer: computer)
            case .music, .timer: break
            }
            let state = IslandLengthState(configuration: configuration)
            if needsFiltering {
                let title = state.title.lowercased()
                guard tokens.allSatisfy({ title.contains($0) }) else { continue }
                guard !modifiedOnly || saved.isModified(state) else { continue }
                if matchedCount >= start, results.count < size { results.append(state) }
                matchedCount += 1
            } else {
                results.append(state)
            }
        }
        return IslandLengthCatalogPage(states: results, total: needsFiltering ? matchedCount : baseCount)
    }
}
