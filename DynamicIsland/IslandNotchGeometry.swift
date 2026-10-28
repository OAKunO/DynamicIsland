import AppKit

/// All dimensions are AppKit points, including scaled display modes.
nonisolated struct IslandNotchGeometry: Equatable, Sendable {
    static let horizontalSafety: CGFloat = 10
    static let fallback = Self(width: 185, height: 32)
    let width: CGFloat
    let height: CGFloat

    var protectedWidth: CGFloat { width > 0 ? ceil(width) + 2 * Self.horizontalSafety : 0 }
    var compactHeight: CGFloat { max(32, height) }
    var idleWidth: CGFloat { max(190, protectedWidth) }
    // Keep the complete 24-point settings button beyond the protected region.
    var minimumExpandedWidth: CGFloat { protectedWidth + 2 * (14 + 24) }

    @MainActor init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            self.init(width: max(0, right.minX - left.maxX), height: screen.safeAreaInsets.top)
        } else {
            self.init(width: 0, height: 0)
        }
    }

    init(width: CGFloat, height: CGFloat) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    func exclusionRect(in bounds: CGRect, centerX: CGFloat? = nil) -> CGRect {
        let width = min(protectedWidth, bounds.width)
        return CGRect(x: (centerX ?? bounds.midX) - width / 2, y: bounds.minY,
                      width: width, height: min(height, bounds.height)).intersection(bounds)
    }
}

/// Intrinsic layout widths, independent of the window's current proposal.
nonisolated struct IslandCompactContentSize: Equatable, Sendable {
    let left: CGFloat
    let right: CGFloat

    init(left: CGFloat, right: CGFloat) {
        // Ignore subpixel noise while rounding capacity outward on Retina displays.
        self.left = left.isFinite ? ceil(max(0, left) * 2) / 2 : 0
        self.right = right.isFinite ? ceil(max(0, right) * 2) / 2 : 0
    }

    func width(geometry: IslandNotchGeometry) -> CGFloat {
        if left == 0 && right == 0 { return geometry.idleWidth }
        return geometry.protectedWidth + left + right + 2 * IslandCompactMetrics.outerPadding
    }

    func notchCenterX(geometry: IslandNotchGeometry, shellWidth: CGFloat) -> CGFloat {
        if left == 0 && right == 0 { return shellWidth / 2 }
        let extra = max(0, shellWidth - width(geometry: geometry))
        return IslandCompactMetrics.outerPadding + left + geometry.protectedWidth / 2 + extra / 2
    }

    func frame(on screen: CGRect, geometry: IslandNotchGeometry,
               notchCenterX: CGFloat? = nil, shellWidth: CGFloat? = nil) -> CGRect {
        let width = shellWidth ?? self.width(geometry: geometry)
        return CGRect(x: (notchCenterX ?? screen.midX) - self.notchCenterX(geometry: geometry, shellWidth: width),
                      y: screen.maxY - geometry.compactHeight,
                      width: width, height: geometry.compactHeight)
    }
}

/// Component budgets replace per-combination shell widths. The view anchors the
/// actual, intrinsic content at the protected edges; spare capacity is outward.
nonisolated enum IslandCompactMetrics {
    static let outerPadding: CGFloat = 14
    static let dividerWidth: CGFloat = 25 // 12 + one-point separator + 12

    struct Lanes: Sendable {
        var left: CGFloat = 0
        var right: CGFloat = 0
        var maximum: CGFloat { max(left, right) }
    }

    private static func text(_ value: String, size: CGFloat = 12, mono: Bool = false) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            : NSFont.systemFont(ofSize: size, weight: .semibold)
        return ceil((value as NSString).size(withAttributes: [.font: font]).width)
    }

    private struct AgentText: Sendable {
        let name: CGFloat
        let completed: CGFloat
        let interrupted: CGFloat
        let failed: CGFloat
        let completedBadge: CGFloat
    }

    private static let agentText: [IslandAgentProvider: AgentText] = Dictionary(uniqueKeysWithValues:
        IslandAgentProvider.allCases.map { provider in
            let name = provider == .claude ? "Claude" : provider.title
            return (provider, AgentText(name: text(name), completed: text("\(name) · 已完成"),
                interrupted: text("\(name) · 已中断"), failed: text("\(name) · 运行失败"),
                completedBadge: text("\(name) · 已完成", size: 10)))
        })
    // Stable across single/multiple tasks and the minutes-to-hours transition.
    private static let elapsedWidth = text("99:59:59", size: 10, mono: true)
    private static let countWidth = text("×99", size: 10)
    private static let waitingWidth = 6 + 4 + text("待确认", size: 10)

    static func agentLanes(_ activity: IslandAgentActivity, paired: Bool) -> Lanes {
        let measured = agentText[activity.provider]!
        let ongoing = activity.working > 0 || activity.waiting > 0
        let onlyCompleted = activity.completed > 0 && activity.taskCount == activity.completed
        let unread: CGFloat = activity.completed > 0 ? 13 : 0 // six-point dot plus spacing
        var lanes = Lanes()
        if !paired && onlyCompleted {
            lanes = Lanes(left: 28, right: measured.completedBadge)
        } else if ongoing {
            // A newly completed task must not change a still-working provider's budget.
            lanes.left = 18 + 13 + (paired ? 0 : 7 + measured.name)
            lanes.right = countWidth + 7 + elapsedWidth
            if activity.waiting > 0 { lanes.right += 7 + waitingWidth }
        } else if activity.failed > 0 {
            lanes = Lanes(left: 25 + measured.failed + unread, right: elapsedWidth)
        } else if activity.completed > 0 {
            // Runtime task ordering may put a recent interruption ahead of an
            // unread completion, even though both share the same activity key.
            lanes = Lanes(left: 25 + max(measured.completed,
                activity.interrupted > 0 ? measured.interrupted : 0) + unread,
                right: activity.interrupted > 0 ? elapsedWidth : 0)
        } else {
            lanes = Lanes(left: 25 + measured.interrupted, right: elapsedWidth)
        }
        if paired { return Lanes(left: lanes.left + 7 + lanes.right + 2,
                                 right: lanes.left + 7 + lanes.right + 2) }
        return Lanes(left: lanes.left + 2, right: lanes.right + 2)
    }

    static func agentWidth(for configuration: IslandLengthConfiguration) -> CGFloat {
        let agents = configuration.orderedAgents
        // Three sources rotate through two visible slots. Reserve the widest
        // source so a rotation never resizes the shell or invades the notch.
        return agents.map { agentLanes($0, paired: agents.count > 1).maximum }.max() ?? 0
    }

    static func toolWidth(_ activity: CompactActivity, configuration: IslandLengthConfiguration,
                          dual: Bool) -> CGFloat {
        switch activity {
        case .audio: return dual ? 24 : 21 + 6 + 24
        case .timer, .pomodoro:
            let timer = activity == .timer ? configuration.timer : configuration.pomodoro
            let label: CGFloat = timer.hasHours == true ? 60 : 38
            return dual ? max(16, label) : 16 + 6 + label
        case .recording: return dual ? 60 : 7 + 6 + 60
        case .alarm:
            let label = CGFloat(String(configuration.compactAlarmCount).count) * 8
            return dual ? max(16, label) : 16 + 6 + label
        case .battery: return dual ? 41 : (configuration.battery.isCharging ? 29.25 : 21.75)
        case .usb: return dual ? 60 : 16 + 6 + 60
        }
    }

    static func laneWidth(for configuration: IslandLengthConfiguration) -> CGFloat {
        let activities = configuration.compactActivities
        let agent = agentWidth(for: configuration)
        let singleCount = activities.count / 2
        let laneCount = singleCount + activities.count % 2
        let separators = CGFloat(max(0, laneCount - 1) + (agent > 0 && laneCount > 0 ? 1 : 0))
        func singles(_ values: [CompactActivity]) -> CGFloat {
            values.map { toolWidth($0, configuration: configuration, dual: false) }
                .sorted(by: >).prefix(singleCount).reduce(0, +)
        }
        // Any tool can be the newest, split activity. This covers every arrival
        // order algebraically, without enumerating millions of preference keys.
        let tools = activities.count.isMultiple(of: 2) ? singles(activities)
            : activities.map { dual in
                toolWidth(dual, configuration: configuration, dual: true)
                    + singles(activities.filter { $0 != dual })
            }.max() ?? 0
        return agent + tools + separators * dividerWidth
    }

    static func width(for configuration: IslandLengthConfiguration, geometry: IslandNotchGeometry) -> CGFloat {
        let lane = laneWidth(for: configuration)
        return lane == 0 ? geometry.idleWidth
            : max(geometry.idleWidth, ceil(geometry.protectedWidth + 2 * (outerPadding + lane)))
    }
}
