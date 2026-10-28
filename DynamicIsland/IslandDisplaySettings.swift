import Combine
import Foundation

nonisolated enum IslandDisplayFeature: String, CaseIterable, Identifiable, Sendable {
    case codex, deepSeek, claude, music, timer, pomodoro, alarm, battery, usb, computer, recording, notes, unlockGreeting
    static var displayFeatures: [Self] { allCases.filter { $0 != .unlockGreeting } }
    static var functionFeatures: [Self] { [.unlockGreeting] }
    var id: Self { self }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .deepSeek: "DeepSeek"
        case .claude: "Claude Code"
        case .music: "音乐与音频"
        case .timer: "倒计时"
        case .pomodoro: "番茄钟"
        case .alarm: "闹钟"
        case .recording: "录屏"
        case .battery: "电池状态"
        case .usb: "USB 连接"
        case .computer: "本机信息"
        case .notes: "备忘录与待办"
        case .unlockGreeting: "解锁问候"
        }
    }
    var detail: String {
        switch self {
        case .codex, .deepSeek, .claude: "任务状态、运行时长与完成提示"
        case .music: "封面、动态波形与播放信息"
        case .timer: "剩余时间与暂停状态"
        case .pomodoro: "专注、休息与暂停状态"
        case .alarm: "闹钟图标与已启用数量"
        case .recording: "录屏工具、录制时长与暂停状态"
        case .battery: "充电时长、电量与低电量提示"
        case .usb: "连接图标、设备类型与展开后的手机详情"
        case .computer: "展开后显示电脑电量、系统、存储与硬件详情"
        case .notes: "展开时查看置顶与待办，解锁后显示简短摘要"
        case .unlockGreeting: "解锁屏幕时显示“早上好”等问候卡片"
        }
    }
    var symbol: String {
        switch self {
        case .codex: "terminal"
        case .deepSeek: "fish.fill"
        case .claude: "sun.max.fill"
        case .music: "music.note"
        case .timer, .pomodoro: "timer"
        case .alarm: "alarm.fill"
        case .recording: "record.circle"
        case .battery: "battery.100percent"
        case .usb: "cable.connector"
        case .computer: "laptopcomputer"
        case .notes: "note.text"
        case .unlockGreeting: "sun.horizon.fill"
        }
    }
}

nonisolated struct IslandDisplaySettingsSnapshot: Equatable, Sendable {
    var hiddenFeatures: Set<IslandDisplayFeature> = []

    func isEnabled(_ feature: IslandDisplayFeature) -> Bool { !hiddenFeatures.contains(feature) }
    func isProviderEnabled(_ provider: IslandAgentProvider) -> Bool {
        switch provider {
        case .codex: isEnabled(.codex)
        case .claude: isEnabled(.claude)
        case .deepSeek: isEnabled(.deepSeek)
        }
    }
    func isActivityEnabled(_ activity: CompactActivity) -> Bool {
        switch activity {
        case .audio: isEnabled(.music)
        case .timer: isEnabled(.timer)
        case .pomodoro: isEnabled(.pomodoro)
        case .alarm: isEnabled(.alarm)
        case .recording: isEnabled(.recording)
        case .battery: isEnabled(.battery)
        case .usb: isEnabled(.usb)
        }
    }

    func filtering(_ configuration: IslandLengthConfiguration) -> IslandLengthConfiguration {
        var result = configuration
        result.agents = configuration.agents.filter { isProviderEnabled($0.provider) }
        if result.agents != configuration.agents {
            result.expandedTaskCount = result.agents.reduce(0) { $0 + $1.taskCount }
        }
        if !isEnabled(.music) { result.music = false }
        if !isEnabled(.timer) && result.timer != .alarm { result.timer = .off }
        if !isEnabled(.pomodoro) { result.pomodoro = .off }
        if !isEnabled(.alarm) {
            result.enabledAlarmCount = 0
            if result.timer == .alarm { result.timer = .off }
        }
        if !isEnabled(.battery) { result.battery = .normal }
        if !isEnabled(.usb) { result.usb = false; result.phone = false }
        if !isEnabled(.computer) { result.computer = false }
        if !isEnabled(.recording) { result.recording = .off }
        result.showsTimeTools = isEnabled(.timer) || isEnabled(.pomodoro) || isEnabled(.alarm)
        result.showsNotes = configuration.showsNotes && isEnabled(.notes)
        result.showsRecordingTools = isEnabled(.recording)
        return result
    }

    func forRecording(isActive: Bool, showsStatus: Bool, coexists: Bool) -> Self {
        guard isActive, showsStatus, isEnabled(.recording), !coexists else { return self }
        var result = self
        result.hiddenFeatures.formUnion(IslandDisplayFeature.displayFeatures.filter { $0 != .recording })
        return result
    }
}

/// Display preferences retain running tool state. Automatic features such as
/// unlock greetings share the persisted store and have their own settings page.
final class IslandDisplaySettings: ObservableObject {
    static let shared = IslandDisplaySettings()
    @Published private(set) var snapshot: IslandDisplaySettingsSnapshot
    private let defaults: UserDefaults
    private let defaultsKey = "island.hiddenDisplayFeatures.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snapshot = .init(hiddenFeatures: Set((defaults.stringArray(forKey: defaultsKey) ?? [])
            .compactMap(IslandDisplayFeature.init(rawValue:))))
    }

    var enabledCount: Int { IslandDisplayFeature.allCases.count - snapshot.hiddenFeatures.count }
    var enabledDisplayCount: Int { IslandDisplayFeature.displayFeatures.filter(snapshot.isEnabled).count }
    var enabledFunctionCount: Int { IslandDisplayFeature.functionFeatures.filter(snapshot.isEnabled).count }
    func setEnabled(_ enabled: Bool, for feature: IslandDisplayFeature) {
        guard snapshot.isEnabled(feature) != enabled else { return }
        var next = snapshot
        if enabled { next.hiddenFeatures.remove(feature) }
        else { next.hiddenFeatures.insert(feature) }
        snapshot = next
        persist()
    }

    func enableAll() {
        guard !snapshot.hiddenFeatures.isEmpty else { return }
        snapshot = .init()
        persist()
    }

    func enableAllDisplayFeatures() {
        var next = snapshot
        next.hiddenFeatures.subtract(IslandDisplayFeature.displayFeatures)
        guard next != snapshot else { return }
        snapshot = next
        persist()
    }

    private func persist() {
        defaults.set(snapshot.hiddenFeatures.map(\.rawValue).sorted(), forKey: defaultsKey)
    }
}
