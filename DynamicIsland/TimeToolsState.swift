import Foundation

nonisolated enum IslandTimeTool: String, CaseIterable, Identifiable, Sendable {
    case timer, pomodoro, alarm
    var id: Self { self }
    var title: String {
        switch self {
        case .timer: "计时器"
        case .pomodoro: "番茄钟"
        case .alarm: "定时闹钟"
        }
    }
    var symbol: String {
        switch self {
        case .timer: "timer"
        case .pomodoro: "timer" // TimeToolIcon supplies the custom tomato drawing.
        case .alarm: "alarm.fill"
        }
    }
}

nonisolated struct TimeCompletion: Sendable {
    let tool: IslandTimeTool
    let title: String
    let message: String
    var repeatsSound = false
}

nonisolated struct PomodoroConfiguration: Codable, Equatable, Sendable {
    var focusMinutes = 25
    var focusSeconds = 0
    var shortBreakMinutes = 5
    var shortBreakSeconds = 0
    var longBreakMinutes = 15
    var longBreakSeconds = 0
    var longBreakInterval = 4
    var rounds = 4
    var isUnlimited = true
    var autoAdvance = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case focusMinutes, focusSeconds, shortBreakMinutes, shortBreakSeconds
        case longBreakMinutes, longBreakSeconds, longBreakInterval, rounds, isUnlimited, autoAdvance
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        focusMinutes = try values.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? focusMinutes
        focusSeconds = try values.decodeIfPresent(Int.self, forKey: .focusSeconds) ?? 0
        shortBreakMinutes = try values.decodeIfPresent(Int.self, forKey: .shortBreakMinutes) ?? shortBreakMinutes
        shortBreakSeconds = try values.decodeIfPresent(Int.self, forKey: .shortBreakSeconds) ?? 0
        longBreakMinutes = try values.decodeIfPresent(Int.self, forKey: .longBreakMinutes) ?? longBreakMinutes
        longBreakSeconds = try values.decodeIfPresent(Int.self, forKey: .longBreakSeconds) ?? 0
        longBreakInterval = try values.decodeIfPresent(Int.self, forKey: .longBreakInterval) ?? longBreakInterval
        rounds = try values.decodeIfPresent(Int.self, forKey: .rounds) ?? rounds
        isUnlimited = try values.decodeIfPresent(Bool.self, forKey: .isUnlimited) ?? isUnlimited
        autoAdvance = try values.decodeIfPresent(Bool.self, forKey: .autoAdvance) ?? autoAdvance
    }

    var validated: Self {
        var result = self
        result.focusSeconds = min(max(focusSeconds, 0), 59)
        result.shortBreakSeconds = min(max(shortBreakSeconds, 0), 59)
        result.longBreakSeconds = min(max(longBreakSeconds, 0), 59)
        result.focusMinutes = min(max(focusMinutes, result.focusSeconds > 0 ? 0 : 1), 180)
        result.shortBreakMinutes = min(max(shortBreakMinutes, result.shortBreakSeconds > 0 ? 0 : 1), 60)
        result.longBreakMinutes = min(max(longBreakMinutes, result.longBreakSeconds > 0 ? 0 : 1), 120)
        result.longBreakInterval = min(max(longBreakInterval, 1), 12)
        result.rounds = min(max(rounds, 1), 99)
        return result
    }
    func duration(for phase: PomodoroSession.Phase) -> Int {
        switch phase {
        case .focus: focusMinutes * 60 + focusSeconds
        case .shortBreak: shortBreakMinutes * 60 + shortBreakSeconds
        case .longBreak: longBreakMinutes * 60 + longBreakSeconds
        }
    }
}

/// After a long sleep, advance only one phase and start the next deadline from
/// now; never credit focus rounds that the user did not actually complete.
nonisolated struct PomodoroSession: Equatable, Sendable {
    enum Phase: Sendable {
        case focus, shortBreak, longBreak
        var title: String {
            switch self {
            case .focus: "专注"
            case .shortBreak: "短休息"
            case .longBreak: "长休息"
            }
        }
    }
    private(set) var phase: Phase = .focus
    let configuration: PomodoroConfiguration
    private(set) var completedFocusCount = 0
    private(set) var remaining: Int
    private(set) var deadline: Date?
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var isComplete = false

    init(configuration: PomodoroConfiguration = .init()) {
        self.configuration = configuration.validated
        remaining = self.configuration.duration(for: .focus)
    }
    var phaseDuration: Int { configuration.duration(for: phase) }
    var progress: Double { min(max(1 - Double(remaining) / Double(phaseDuration), 0), 1) }

    mutating func start(at now: Date) {
        guard !isRunning, !isComplete else { return }
        isRunning = true
        isPaused = false
        deadline = now.addingTimeInterval(TimeInterval(remaining))
    }
    mutating func togglePause(at now: Date) {
        guard isRunning else { return }
        if isPaused {
            deadline = now.addingTimeInterval(TimeInterval(remaining))
        } else {
            remaining = max(0, Int(ceil(deadline?.timeIntervalSince(now) ?? 0)))
            deadline = nil
        }
        isPaused.toggle()
    }
    @discardableResult
    mutating func refresh(at now: Date) -> Phase? {
        guard let deadline else { return nil }
        remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        guard remaining == 0 else { return nil }
        let completed = phase
        if phase == .focus {
            completedFocusCount += 1
            if !configuration.isUnlimited && completedFocusCount >= configuration.rounds {
                self.deadline = nil
                isRunning = false
                isPaused = false
                isComplete = true
                return completed
            }
            phase = completedFocusCount.isMultiple(of: configuration.longBreakInterval) ? .longBreak : .shortBreak
        } else { phase = .focus }
        self.deadline = nil
        isRunning = false
        isPaused = false
        remaining = phaseDuration
        if configuration.autoAdvance { start(at: now) }
        return completed
    }
}

nonisolated struct CustomAlarm: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var isEnabled = true
}

nonisolated enum AlarmSchedule {
    static func defaultTime(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .minute, for: now.addingTimeInterval(3600))?.start
            ?? now.addingTimeInterval(3600)
    }

    static func nextDeadline(for date: Date, after now: Date, calendar: Calendar = .current) -> Date? {
        if let future = deadline(for: date, after: now, calendar: calendar) { return future }
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime)
    }

    static func deadline(for date: Date, after now: Date, calendar: Calendar = .current) -> Date? {
        guard let minute = calendar.dateInterval(of: .minute, for: date)?.start, minute > now else { return nil }
        return minute
    }
}
