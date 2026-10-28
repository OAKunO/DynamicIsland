import SwiftUI
import Combine
import AppKit

struct UnlockGreeting: Identifiable, Equatable {
    enum Period: Equatable {
        case morning
        case noon
        case afternoon
        case evening

        var salutation: String {
            switch self {
            case .morning: "早上好"
            case .noon: "中午好"
            case .afternoon: "下午好"
            case .evening: "晚上好"
            }
        }

        var symbolName: String {
            switch self {
            case .morning: "sun.horizon.fill"
            case .noon: "sun.max.fill"
            case .afternoon: "cloud.sun.fill"
            case .evening: "moon.stars.fill"
            }
        }
    }

    let id = UUID()
    let period: Period
    let message: String
    let date: Date

    static func make(for date: Date, calendar: Calendar = .current) -> Self {
        let hour = calendar.component(.hour, from: date)
        let period: Period
        switch hour {
        case 5..<11: period = .morning
        case 11..<13: period = .noon
        case 13..<18: period = .afternoon
        default: period = .evening
        }

        let messages: [String]
        switch period {
        case .morning:
            messages = [
                "新的一天，慢慢来，也会有好事发生。",
                "愿今天的你从容、清醒，也被小小的幸运照亮。",
                "带着好心情出发，今天也值得期待。"
            ]
        case .noon:
            messages = [
                "忙了一上午，记得好好吃饭，也照顾好自己。",
                "先歇一会儿，给下午留一点轻盈和能量。",
                "再忙也别忘了，你的感受同样重要。"
            ]
        case .afternoon:
            messages = [
                "给自己一点耐心，今天仍然有很多可能。",
                "稳稳地做完眼前这一件事，就已经很好了。",
                "喝口水，伸个懒腰，再从容地继续吧。"
            ]
        case .evening:
            messages = [
                "辛苦了，愿你把今天的疲惫轻轻放下。",
                "今天已经很努力了，剩下的时间留给自己吧。",
                "愿夜晚替你收好疲惫，留下安心和松弛。"
            ]
        }

        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        return Self(period: period, message: messages[day % messages.count], date: date)
    }
}

/// Shared state for the persistent time tools and island alerts.
final class IslandModel: ObservableObject {

    let notes: NotesStore
    @Published private(set) var isSessionUnlocked = true
    private var lastUnlockDate: Date?

    /// Called before showing any note-bearing surface. Locking also drops queued greetings.
    func setSessionLocked() {
        isSessionUnlocked = false
        pendingUnlockGreetingDate = nil
        lastUnlockDate = nil
        dismissUnlockGreeting()
        isExpanded = false
    }

    func handleSessionUnlock(at date: Date = Date(), showsGreeting: Bool = true) {
        isSessionUnlocked = true
        if let lastUnlockDate, date.timeIntervalSince(lastUnlockDate) < 2 { return }
        lastUnlockDate = date
        if showsGreeting { presentUnlockGreeting(at: date) }
    }

    @Published var isHovered = false
    @Published var isExpanded = false
    @Published private(set) var timerHours = 0
    @Published private(set) var timerMinutes = 5
    @Published private(set) var timerSeconds = 0
    @Published private(set) var timeRemaining = 0
    @Published private(set) var isTimerRunning = false
    @Published private(set) var isTimerPaused = false
    @Published var isTimerFinished = false
    @Published var selectedTimeTool: IslandTimeTool = .timer {
        didSet {
            if selectedTimeTool != .pomodoro { isPomodoroSettingsPresented = false }
            if selectedTimeTool != .alarm { dismissAlarmEditor() }
        }
    }
    @Published private(set) var pomodoro = PomodoroSession()
    @Published private(set) var pomodoroConfiguration = PomodoroConfiguration()
    @Published var isTimeToolPopoverPresented = false
    @Published var isPomodoroSettingsPresented = false
    @Published var isRecordingSettingsPresented = false
    @Published var alarmTime = Date().addingTimeInterval(3600)
    @Published private(set) var alarms: [CustomAlarm] = []
    @Published private(set) var isAlarmEditorPresented = false
    @Published private(set) var editingAlarmID: UUID?
    var enabledAlarmCount: Int { alarms.filter(\.isEnabled).count }
    var alarmDeadline: Date? { alarms.filter(\.isEnabled).map(\.date).min() }
    @Published private(set) var completionTitle = "计时完成"
    @Published private(set) var completionMessage = "做得好，休息一下吧"
    private var pendingCompletions: [TimeCompletion] = []
    private var alertSound: NSSound?
    private let playsAlertSound: Bool
    private let timeToolDefaults: UserDefaults
    @Published private(set) var activeUnlockGreeting: UnlockGreeting?

    private let maximumDuration = 99 * 60 * 60 + 59 * 60 + 59
    private var endDate: Date?
    private var tickTimer: Timer?
    private var greetingDismissWorkItem: DispatchWorkItem?
    private var completionDismissWorkItem: DispatchWorkItem?
    private var completionDismissID: UUID?
    private var wasExpandedBeforeGreeting = false
    private var pendingUnlockGreetingDate: Date?

    init(previewConfiguration: IslandLengthConfiguration? = nil, playsAlertSound: Bool = true, timeToolDefaults: UserDefaults = .standard, notes: NotesStore = NotesStore()) {
        self.notes = notes
        self.playsAlertSound = playsAlertSound && previewConfiguration == nil
        self.timeToolDefaults = timeToolDefaults
        if previewConfiguration == nil,
           let data = timeToolDefaults.data(forKey: "island.pomodoroConfiguration.v1"),
           let configuration = try? JSONDecoder().decode(PomodoroConfiguration.self, from: data) {
            pomodoroConfiguration = configuration.validated
            pomodoro = PomodoroSession(configuration: pomodoroConfiguration)
        }
        guard let configuration = previewConfiguration else {
            if let data = timeToolDefaults.data(forKey: "island.alarms.v1"),
               let saved = try? JSONDecoder().decode([CustomAlarm].self, from: data) {
                let now = Date()
                alarms = saved.map { alarm in
                    var alarm = alarm
                    if alarm.date <= now { alarm.isEnabled = false }
                    return alarm
                }
                persistAlarms()
                if alarmDeadline != nil { startTicking() }
            }
            return
        }
        isHovered = configuration.mode == .hovered
        isExpanded = configuration.mode.isExpanded && configuration.mode != .expandedMusic && configuration.mode != .expandedAgent
        let timerMode = configuration.mode == .expandedTimerRunning || configuration.mode == .expandedTimerPaused
        isTimerRunning = timerMode || (configuration.timer != .off && configuration.timer != .alarm)
        if configuration.timer == .alarm {
            selectedTimeTool = .alarm
        }
        alarms = (0..<configuration.compactAlarmCount).map { index in
            CustomAlarm(date: Date().addingTimeInterval(TimeInterval(3600 * (index + 1))))
        }
        if configuration.pomodoro != .off {
            if configuration.pomodoro.hasHours == true {
                pomodoroConfiguration.focusMinutes = 62
                pomodoro = PomodoroSession(configuration: pomodoroConfiguration)
            }
            pomodoro.start(at: Date())
            if configuration.pomodoro == .pausedMinutes || configuration.pomodoro == .pausedHours {
                pomodoro.togglePause(at: Date())
            }
        }
        isTimerPaused = configuration.mode == .expandedTimerPaused ||
            configuration.timer == .pausedMinutes || configuration.timer == .pausedHours
        timeRemaining = configuration.timer.hasHours == true ? 3725 : 325
        isTimerFinished = configuration.mode == .expandedTimerFinished
        if configuration.mode == .expandedGreeting {
            activeUnlockGreeting = UnlockGreeting.make(for: Date())
        }
    }

    deinit {
        tickTimer?.invalidate()
        greetingDismissWorkItem?.cancel()
        completionDismissWorkItem?.cancel()
        alertSound?.stop()
    }

    var totalSeconds: Int { timerHours * 60 * 60 + timerMinutes * 60 + timerSeconds }
    var canStartTimer: Bool { totalSeconds > 0 }
    var timeRemainingText: String { Self.timeText(for: timeRemaining) }
    var compactTimeRemainingText: String {
        if timerHasHours {
            return timeRemainingText
        }
        return String(format: "%02d:%02d", timeRemaining / 60, timeRemaining % 60)
    }
    var timerHasHours: Bool { timeRemaining >= 3600 }
    var configuredTimeText: String { Self.timeText(for: totalSeconds) }
    var scheduledEndTimeText: String {
        let now = Date()
        let endDate = now.addingTimeInterval(TimeInterval(totalSeconds))
        let calendar = Calendar.current

        if calendar.isDateInToday(endDate) {
            return Self.endTimeFormatter.string(from: endDate)
        }
        if calendar.isDateInTomorrow(endDate) {
            return "明天 \(Self.endTimeFormatter.string(from: endDate))"
        }
        if calendar.component(.year, from: now) == calendar.component(.year, from: endDate) {
            return Self.dateTimeFormatter.string(from: endDate)
        }
        return Self.yearDateTimeFormatter.string(from: endDate)
    }
    var timerStatusText: String { isTimerPaused ? "已暂停" : "倒计时中" }
    var isPersistentAlertVisible: Bool {
        isTimerFinished || activeUnlockGreeting != nil
    }
    var isUnlockGreetingPresented: Bool {
        activeUnlockGreeting != nil && !isTimerFinished
    }

    /// 每次屏幕解锁时主动展开问候卡片。计时完成优先级更高，
    /// 若计时完成卡片正在展示，问候会在用户处理后补上。
    func presentUnlockGreeting(at date: Date = Date()) {
        guard isSessionUnlocked else { return }
        guard !isTimerFinished else {
            pendingUnlockGreetingDate = date
            return
        }

        greetingDismissWorkItem?.cancel()
        if activeUnlockGreeting == nil {
            wasExpandedBeforeGreeting = isExpanded
        }
        activeUnlockGreeting = UnlockGreeting.make(for: date)
        isExpanded = true
        WindowManager.ensureVisible()

        let work = DispatchWorkItem { [weak self] in
            self?.dismissUnlockGreeting()
        }
        greetingDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5, execute: work)
    }

    func dismissUnlockGreeting() {
        guard activeUnlockGreeting != nil else { return }
        greetingDismissWorkItem?.cancel()
        greetingDismissWorkItem = nil
        activeUnlockGreeting = nil
        if !isTimerFinished {
            isExpanded = wasExpandedBeforeGreeting
        }
    }

    func dismissTimerFinishedAlert() {
        guard isTimerFinished else { return }
        completionDismissWorkItem?.cancel()
        completionDismissWorkItem = nil
        completionDismissID = nil
        alertSound?.stop()
        alertSound = nil
        isTimerFinished = false
        if !pendingCompletions.isEmpty {
            showCompletion(pendingCompletions.removeFirst())
        } else {
            isExpanded = false
            presentPendingUnlockGreetingIfNeeded()
        }
    }

    func setTimer(hours: Int, minutes: Int, seconds: Int) {
        setTimer(totalSeconds: hours * 60 * 60 + minutes * 60 + seconds)
    }

    func setTimer(totalSeconds: Int) {
        let clampedSeconds = min(max(totalSeconds, 0), maximumDuration)
        timerHours = clampedSeconds / 3600
        timerMinutes = clampedSeconds % 3600 / 60
        timerSeconds = clampedSeconds % 60
    }

    func adjustTimer(by seconds: Int) {
        setTimer(totalSeconds: totalSeconds + seconds)
    }

    func applyPreset(minutes: Int) {
        setTimer(totalSeconds: minutes * 60)
    }

    func startTimer() {
        guard canStartTimer else { return }
        timeRemaining = totalSeconds
        isTimerRunning = true
        isTimerPaused = false
        endDate = Date().addingTimeInterval(TimeInterval(timeRemaining))
        startTicking()
    }

    func togglePause() {
        guard isTimerRunning else { return }
        if isTimerPaused {
            isTimerPaused = false
            endDate = Date().addingTimeInterval(TimeInterval(timeRemaining))
            startTicking()
        } else {
            updateTimeRemaining()
            guard isTimerRunning else { return }
            isTimerPaused = true
            endDate = nil
            stopTickingIfIdle()
        }
    }

    func addTime(by seconds: Int) {
        guard isTimerRunning else { return }
        timeRemaining = min(max(timeRemaining + seconds, 0), maximumDuration)
        if timeRemaining == 0 {
            timerFinished()
            return
        }
        if !isTimerPaused {
            endDate = Date().addingTimeInterval(TimeInterval(timeRemaining))
        }
    }

    func cancelTimer() {
        endDate = nil
        isTimerRunning = false
        isTimerPaused = false
        timeRemaining = 0
        stopTickingIfIdle()
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshTimeTools()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // Use a deadline instead of subtracting one on every tick, so a busy run loop cannot make the timer drift.
    private func updateTimeRemaining() {
        guard let endDate else { return }
        timeRemaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        if timeRemaining == 0 {
            timerFinished()
        }
    }

    private func timerFinished() {
        endDate = nil
        timeRemaining = 0
        isTimerRunning = false
        isTimerPaused = false
        enqueueCompletion(.init(tool: .timer, title: "计时完成", message: "做得好，休息一下吧"))
        stopTickingIfIdle()
    }

    var hasActiveTimeTool: Bool { isTimerRunning || pomodoro.isRunning || alarmDeadline != nil }
    func isPaused(_ tool: IslandTimeTool) -> Bool {
        switch tool {
        case .timer: isTimerPaused
        case .pomodoro: pomodoro.isPaused
        case .alarm: false
        }
    }
    func compactText(for tool: IslandTimeTool) -> String {
        if tool == .alarm { return "\(enabledAlarmCount)" }
        let seconds = tool == .timer ? timeRemaining : pomodoro.remaining
        return seconds >= 3600 ? Self.timeText(for: seconds)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var compactTool: IslandTimeTool {
        if isActive(selectedTimeTool) { return selectedTimeTool }
        if isTimerRunning { return .timer }
        if pomodoro.isRunning { return .pomodoro }
        return .alarm
    }
    var compactToolSeconds: Int {
        switch compactTool {
        case .timer: timeRemaining
        case .pomodoro: pomodoro.remaining
        case .alarm: 0
        }
    }
    var compactToolShowsCountdown: Bool { compactTool != .alarm }
    var compactToolHasHours: Bool { compactToolSeconds >= 3600 }
    var compactToolText: String {
        guard compactToolShowsCountdown else { return "" }
        let seconds = compactToolSeconds
        return compactToolHasHours ? Self.timeText(for: seconds) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var compactToolPaused: Bool { compactTool == .timer ? isTimerPaused : compactTool == .pomodoro && pomodoro.isPaused }
    func isActive(_ tool: IslandTimeTool) -> Bool {
        switch tool {
        case .timer: isTimerRunning
        case .pomodoro: pomodoro.isRunning
        case .alarm: alarmDeadline != nil
        }
    }
    func startPomodoro(at now: Date = Date()) {
        pomodoro.start(at: now)
        startTicking()
    }
    func togglePomodoroPause(at now: Date = Date()) {
        if let completedPhase = pomodoro.refresh(at: now) { notifyPomodoro(completedPhase) }
        pomodoro.togglePause(at: now)
        if pomodoro.isPaused { stopTickingIfIdle() } else { startTicking() }
    }
    func resetPomodoro() {
        pomodoro = PomodoroSession(configuration: pomodoroConfiguration)
        stopTickingIfIdle()
    }
    var canEditPomodoroConfiguration: Bool { !pomodoro.isRunning && pomodoro.completedFocusCount == 0 }
    func updatePomodoroConfiguration(_ configuration: PomodoroConfiguration) {
        guard canEditPomodoroConfiguration else { return }
        pomodoroConfiguration = configuration.validated
        pomodoro = PomodoroSession(configuration: pomodoroConfiguration)
        if let data = try? JSONEncoder().encode(pomodoroConfiguration) {
            timeToolDefaults.set(data, forKey: "island.pomodoroConfiguration.v1")
        }
    }
    var canScheduleAlarm: Bool { AlarmSchedule.deadline(for: alarmTime, after: Date()) != nil }
    func beginAddingAlarm(at now: Date = Date()) {
        editingAlarmID = nil
        alarmTime = AlarmSchedule.defaultTime(after: now)
        isTimeToolPopoverPresented = false
        isAlarmEditorPresented = true
    }
    func beginEditingAlarm(_ id: UUID) {
        guard let alarm = alarms.first(where: { $0.id == id }) else { return }
        editingAlarmID = id
        alarmTime = alarm.date
        isTimeToolPopoverPresented = false
        isAlarmEditorPresented = true
    }
    func dismissAlarmEditor() {
        isTimeToolPopoverPresented = false
        isAlarmEditorPresented = false
        editingAlarmID = nil
    }
    func scheduleAlarm(at now: Date = Date()) {
        guard let deadline = AlarmSchedule.deadline(for: alarmTime, after: now) else { return }
        if let id = editingAlarmID {
            guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
            alarms[index].date = deadline
            alarms[index].isEnabled = true
        } else {
            alarms.append(CustomAlarm(date: deadline))
        }
        alarms.sort { $0.date < $1.date }
        persistAlarms()
        dismissAlarmEditor()
        startTicking()
    }
    func setAlarmEnabled(_ id: UUID, _ enabled: Bool, at now: Date = Date()) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        if enabled {
            guard let date = AlarmSchedule.nextDeadline(for: alarms[index].date, after: now) else { return }
            alarms[index].date = date
        }
        alarms[index].isEnabled = enabled
        alarms.sort { $0.date < $1.date }
        persistAlarms()
        if enabled { startTicking() } else { stopTickingIfIdle() }
    }
    func deleteAlarm(_ id: UUID) {
        alarms.removeAll { $0.id == id }
        if editingAlarmID == id { dismissAlarmEditor() }
        persistAlarms()
        stopTickingIfIdle()
    }
    private func persistAlarms() {
        if let data = try? JSONEncoder().encode(alarms) {
            timeToolDefaults.set(data, forKey: "island.alarms.v1")
        }
    }
    // Absolute deadlines keep every clock correct after sleep or a busy run loop.
    func refreshTimeTools(at now: Date = Date()) {
        if let endDate, !isTimerPaused {
            let remaining = max(0, Int(ceil(endDate.timeIntervalSince(now))))
            if timeRemaining != remaining { timeRemaining = remaining }
            if timeRemaining == 0 { timerFinished() }
        }
        if pomodoro.deadline != nil {
            var updatedSession = pomodoro
            let phase = updatedSession.refresh(at: now)
            if updatedSession != pomodoro { pomodoro = updatedSession }
            if let phase { notifyPomodoro(phase) }
        }
        let dueAlarms = alarms.filter { $0.isEnabled && $0.date <= now }
        if !dueAlarms.isEmpty {
            let dueIDs = Set(dueAlarms.map(\.id))
            for index in alarms.indices where dueIDs.contains(alarms[index].id) {
                alarms[index].isEnabled = false
            }
            persistAlarms()
            for alarm in dueAlarms {
                enqueueCompletion(.init(tool: .alarm, title: "闹钟响了",
                    message: "\(Self.dateTimeFormatter.string(from: alarm.date)) · 已到你设定的时间", repeatsSound: true))
            }
        }
        stopTickingIfIdle()
    }
    private func notifyPomodoro(_ phase: PomodoroSession.Phase) {
        let message: String
        if pomodoro.isComplete { message = "已完成本组 \(pomodoro.completedFocusCount) 轮专注，休息一下吧" }
        else if pomodoro.isRunning { message = "已完成 \(pomodoro.completedFocusCount) 轮专注 · 正在\(pomodoro.phase.title)" }
        else { message = "已完成 \(pomodoro.completedFocusCount) 轮专注 · 点击番茄钟开始\(pomodoro.phase.title)" }
        enqueueCompletion(.init(tool: .pomodoro,
            title: pomodoro.isComplete ? "本组番茄钟完成" : (phase == .focus ? "专注完成" : "休息结束"),
            message: message))
    }
    private func stopTickingIfIdle() {
        if endDate == nil && pomodoro.deadline == nil && alarmDeadline == nil { stopTicking() }
    }
    private func enqueueCompletion(_ completion: TimeCompletion) {
        if isTimerFinished { pendingCompletions.append(completion) }
        else { showCompletion(completion) }
    }
    private func showCompletion(_ completion: TimeCompletion) {
        dismissGreetingForPriorityContent()
        completionTitle = completion.title
        completionMessage = completion.message
        selectedTimeTool = completion.tool
        isTimerFinished = true
        isExpanded = true
        WindowManager.ensureVisible()
        if completion.tool == .pomodoro {
            let id = UUID()
            completionDismissID = id
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.completionDismissID == id else { return }
                self.dismissTimerFinishedAlert()
            }
            completionDismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
        guard playsAlertSound else { return }
        if let sound = NSSound(named: completion.repeatsSound ? "Ping" : "Glass") {
            alertSound = sound
            sound.loops = completion.repeatsSound
            sound.play()
        } else { NSSound.beep() }
    }

    private func dismissGreetingForPriorityContent() {
        guard activeUnlockGreeting != nil else { return }
        greetingDismissWorkItem?.cancel()
        greetingDismissWorkItem = nil
        activeUnlockGreeting = nil
        isExpanded = wasExpandedBeforeGreeting
    }

    private func presentPendingUnlockGreetingIfNeeded() {
        guard !isTimerFinished,
              let date = pendingUnlockGreetingDate else { return }
        pendingUnlockGreetingDate = nil
        presentUnlockGreeting(at: date)
    }

    private static func timeText(for totalSeconds: Int) -> String {
        String(
            format: "%02d:%02d:%02d",
            totalSeconds / 3600,
            totalSeconds % 3600 / 60,
            totalSeconds % 60
        )
    }

    private static let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let yearDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}
