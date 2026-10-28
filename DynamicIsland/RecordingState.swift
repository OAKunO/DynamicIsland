import Foundation

nonisolated enum RecordingSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case screen, window, region
    var id: Self { self }
    var title: String {
        switch self {
        case .screen: "全屏"
        case .window: "窗口"
        case .region: "区域"
        }
    }
}

nonisolated struct RecordingConfiguration: Codable, Equatable, Sendable {
    var source: RecordingSource = .screen
    var systemAudio = true
    var microphone = false
    var countdown = 3
    var includesIsland = true
    var showsStatus = true
    var coexistsWithOtherActivities = true

    var validated: Self {
        var result = self
        if ![0, 3, 5, 10].contains(countdown) { result.countdown = 3 }
        return result
    }
}

/// Uses a monotonic clock, so changing the system clock cannot change the duration.
nonisolated struct RecordingClock: Sendable {
    private var accumulated: TimeInterval = 0
    private var startedAt: TimeInterval?

    mutating func resume(at uptime: TimeInterval) {
        guard startedAt == nil else { return }
        startedAt = uptime
    }
    mutating func pause(at uptime: TimeInterval) {
        guard let startedAt else { return }
        accumulated += max(0, uptime - startedAt)
        self.startedAt = nil
    }
    func elapsed(at uptime: TimeInterval) -> TimeInterval {
        accumulated + (startedAt.map { max(0, uptime - $0) } ?? 0)
    }
    static func text(seconds: TimeInterval) -> String {
        let hundredths = Int((max(0, seconds) * 100 + 0.0000001).rounded(.down))
        let wholeSeconds = hundredths / 100
        if wholeSeconds >= 3600 {
            return String(format: "%02d:%02d:%02d", wholeSeconds / 3600,
                          wholeSeconds % 3600 / 60, wholeSeconds % 60)
        }
        if wholeSeconds >= 60 {
            return String(format: "%02d:%02d.%02d", wholeSeconds / 60,
                          wholeSeconds % 60, hundredths % 100)
        }
        return String(format: "%02d.%02d", wholeSeconds, hundredths % 100)
    }
}

nonisolated enum RecordingFileName {
    static func name(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "灵动岛录频\(formatter.string(from: date)).mp4"
    }
}
