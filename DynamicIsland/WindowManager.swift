import AppKit
import QuartzCore
import os
import SwiftUI
import Combine
import Observation

/// Presentation belongs to a panel; playback, timers and task data stay shared.
@Observable final class IslandInteractionState {
    var isExpanded = false
    var isHovered = false
    var isTimeToolPopoverPresented = false
    var isPomodoroSettingsPresented = false
    var isRecordingSettingsPresented = false

    func collapse() {
        isExpanded = false
        isTimeToolPopoverPresented = false
        isPomodoroSettingsPresented = false
        isRecordingSettingsPresented = false
    }
}

private struct IslandInteractionKey: EnvironmentKey {
    static let defaultValue: IslandInteractionState? = nil
}

/// A stable display assignment, independent of which screen currently owns focus.
nonisolated struct IslandDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let geometry: IslandNotchGeometry
    let notchCenterX: CGFloat
    /// Unobstructed screens keep a visual black center like the built-in island.
    var islandGeometry: IslandNotchGeometry { geometry.width > 0 ? geometry : .externalIsland }

    @MainActor init(screen: NSScreen) {
        id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        frame = screen.frame
        geometry = IslandNotchGeometry(screen: screen)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchCenterX = (left.maxX + right.minX) / 2
        } else {
            notchCenterX = screen.frame.midX
        }
    }

    init(id: CGDirectDisplayID, frame: CGRect, geometry: IslandNotchGeometry, notchCenterX: CGFloat? = nil) {
        self.id = id
        self.frame = frame
        self.geometry = geometry
        self.notchCenterX = notchCenterX ?? frame.midX
    }
}

nonisolated struct IslandWindowMetrics: Equatable, Sendable {
    var geometry = IslandNotchGeometry.fallback
    var notchCenterX: CGFloat?
    var screenWidth: CGFloat = 1_440
    var expandedWidthLimit: CGFloat { WindowManager.expandedWidthLimit(screenWidth: screenWidth) }
}

private struct IslandWindowMetricsKey: EnvironmentKey {
    static let defaultValue = IslandWindowMetrics()
}

extension EnvironmentValues {
    var islandInteraction: IslandInteractionState? {
        get { self[IslandInteractionKey.self] }
        set { self[IslandInteractionKey.self] = newValue }
    }

    var islandWindowMetrics: IslandWindowMetrics {
        get { self[IslandWindowMetricsKey.self] }
        set { self[IslandWindowMetricsKey.self] = newValue }
    }
}

final class IslandWindowLayout: ObservableObject {
    let interaction = IslandInteractionState()
    @Published fileprivate(set) var metrics: IslandWindowMetrics
    fileprivate weak var window: NSWindow?
    fileprivate var display: IslandDisplay
    fileprivate var configuration = IslandLengthConfiguration()
    fileprivate var targetFrame: CGRect?
    fileprivate var frameMode: IslandLengthMode = .compact
    fileprivate var observers: [NSObjectProtocol] = []
    fileprivate var geometryNotificationPending = false

    init(window: NSWindow?, display: IslandDisplay) {
        self.window = window
        self.display = display
        metrics = IslandWindowMetrics(geometry: display.islandGeometry, screenWidth: display.frame.width)
    }
}

final class WindowManager {

    private struct Motion {
        let duration: TimeInterval
        let timingFunction: CAMediaTimingFunction

        static let expand = Motion(
            duration: 0.60,
            // 超过目标尺寸后回落，让外壳也能呈现展开回弹。
            timingFunction: CAMediaTimingFunction(controlPoints: 0.18, 1.22, 0.32, 1)
        )
        static let collapse = Motion(
            duration: 0.48,
            // 收起时保留较小的回弹，避免紧凑岛被过度压缩。
            timingFunction: CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.32, 1.10)
        )
        static let compact = Motion(
            duration: 0.30,
            timingFunction: CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.20, 1)
        )
    }

    // 岛的基础尺寸（收起 / 悬停 / 展开卡片）
    nonisolated private static let geometryStorage = OSAllocatedUnfairLock(initialState: IslandNotchGeometry.fallback)
    nonisolated private static let compactMeasurements = OSAllocatedUnfairLock(initialState: [String: IslandCompactContentSize]())
    nonisolated static var notchGeometry: IslandNotchGeometry { geometryStorage.withLock { $0 } }
    static var windowNotchCenterX: CGFloat? { primaryLayout?.metrics.notchCenterX }
    nonisolated static func compactContent(for configuration: IslandLengthConfiguration) -> IslandCompactContentSize? {
        compactMeasurements.withLock { $0[configuration.key] }
    }
    nonisolated static var compactHeight: CGFloat { notchGeometry.compactHeight }
    nonisolated static var collapsedSize: CGSize { CGSize(width: notchGeometry.idleWidth, height: compactHeight) }
    nonisolated static var hoveredSize: CGSize {
        // Hover feedback is local to each display.
        CGSize(width: collapsedSize.width + 40, height: compactHeight)
    }
    nonisolated static let expandedSize = CGSize(width: 344, height: 256)
    nonisolated static let greetingExpandedSize = CGSize(width: 424, height: 184)
    nonisolated static let workColumnWidth: CGFloat = 360
    nonisolated static let musicColumnWidth: CGFloat = 340
    nonisolated static let recordingColumnWidth = expandedSize.width * 0.6
    nonisolated static let phoneColumnWidth: CGFloat = 180
    nonisolated static let computerColumnWidth: CGFloat = 180
    nonisolated static let notesColumnWidth: CGFloat = 300
    nonisolated static func expandedWidthLimit(screenWidth: CGFloat) -> CGFloat {
        max(workColumnWidth, min(1_000, floor(screenWidth * 0.85), screenWidth - 48))
    }
    static var currentExpandedWidthLimit: CGFloat {
        primaryLayout?.metrics.expandedWidthLimit ?? expandedWidthLimit(screenWidth: 1_440)
    }
    private static var layouts: [IslandWindowLayout] = []
    private static var primaryLayout: IslandWindowLayout? { layouts.first { $0.window != nil } }
    static var windows: [NSWindow] { layouts.compactMap(\.window) }
    /// Keyboard actions belong to the focused island, or the one under the pointer.
    static var window: NSWindow? {
        if let key = NSApp?.keyWindow, windows.contains(where: { $0 === key }) { return key }
        return windows.first { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) } ?? primaryLayout?.window
    }
    private static var userWantsWindowVisible = true

    static func reportCompactContent(_ content: IslandCompactContentSize, stateKey: String) {
        let changed = compactMeasurements.withLock { values in
            guard values[stateKey] != content else { return false }
            if values.count >= 128 { values.removeAll(keepingCapacity: true) }
            values[stateKey] = content
            return true
        }
        guard changed else { return }
        IslandLengthSettings.shared.geometryDidChange()
        for layout in layouts where !layout.configuration.mode.isExpanded && layout.configuration.key == stateKey {
            updateForState(configuration: layout.configuration, window: layout.window)
        }
    }

    static func layout(for window: NSWindow) -> IslandWindowLayout? {
        layouts.first { $0.window === window }
    }

    private static func refreshWindowGeometry(_ layout: IslandWindowLayout) {
        guard let window = layout.window else { return }
        let next = IslandWindowMetrics(geometry: layout.display.islandGeometry,
            notchCenterX: layout.display.notchCenterX - window.frame.minX, screenWidth: layout.display.frame.width)
        guard next != layout.metrics, !layout.geometryNotificationPending else { return }
        // AppKit can resize while SwiftUI is updating the representable.
        layout.geometryNotificationPending = true
        DispatchQueue.main.async { [weak layout] in
            guard let layout, let window = layout.window else { return }
            layout.geometryNotificationPending = false
            layout.metrics = IslandWindowMetrics(geometry: layout.display.islandGeometry,
                notchCenterX: layout.display.notchCenterX - window.frame.minX, screenWidth: layout.display.frame.width)
            if layout === primaryLayout { IslandLengthSettings.shared.windowGeometryDidChange() }
        }
    }

    static func refreshScreenGeometry() {
        guard let next = primaryLayout?.display.islandGeometry else { return }
        let changed = geometryStorage.withLock { value in
            guard value != next else { return false }
            value = next
            return true
        }
        if changed {
            DispatchQueue.main.async { IslandLengthSettings.shared.geometryDidChange() }
        }
    }

    @discardableResult static func configure(window: NSWindow?, display: IslandDisplay? = nil) -> IslandWindowLayout? {
        guard let window, let display = display ?? NSScreen.screens.first.map(IslandDisplay.init(screen:)) else { return nil }
        if let existing = layout(for: window) { return existing }
        let layout = IslandWindowLayout(window: window, display: display)
        layouts.append(layout)
        layout.observers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { refreshWindowGeometry(layout) }
            }
        }
        refreshScreenGeometry()
        layout.observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in MainActor.assumeIsolated { unregister(window: window) } })

        // 无标题栏
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.remove(.titled)

        // 透明背景
        window.isOpaque = false
        window.backgroundColor = .clear

        // 关键：
        // 不要压在菜单栏上面
        window.level = .statusBar

        // 不显示系统窗口阴影
        window.hasShadow = false

        // 不允许用户拖动
        window.isMovable = false

        // 不显示在 Dock 的窗口列表里
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        // 灵动岛初始尺寸 = 收起状态
        window.setContentSize(defaultSize(for: .init(), geometry: display.islandGeometry))

        position(window: window)
        return layout
    }

    static func unregister(window: NSWindow) {
        guard let layout = layout(for: window) else { return }
        layout.interaction.collapse()
        layout.interaction.isHovered = false
        layout.observers.forEach(NotificationCenter.default.removeObserver)
        layout.observers.removeAll()
        layouts.removeAll { $0 === layout }
        layout.window = nil
        refreshScreenGeometry()
    }

    static func updateDisplay(_ display: IslandDisplay, for window: NSWindow) {
        guard let layout = layout(for: window) else { return }
        layout.display = display
        layout.targetFrame = nil
        refreshScreenGeometry()
        updateForState(configuration: layout.configuration, window: window, animated: false)
        position(window: window)
    }

    nonisolated private struct LayoutFlags {
        let agents: [IslandAgentActivity]
        var codex: IslandAgentActivity? { agents.first { $0.provider == .codex } }
        var claude: IslandAgentActivity? { agents.first { $0.provider == .claude } }
        var deepSeek: IslandAgentActivity? { agents.first { $0.provider == .deepSeek } }
        var working: Bool { agents.allSatisfy(\.isWorking) }
        var multiple: Bool { agents.count > 1 || agents.contains { $0.isMultipleForLayout } }
        var dual: Bool { agents.count > 1 }
        var codexOnly: Bool { agents.count == 1 && codex != nil }
        var codexAndDeepSeek: Bool { codex != nil && deepSeek != nil }
        var mixed: Bool {
            let count = agents.filter(\.isWorking).count
            return dual && count > 0 && count < agents.count
        }
        var claudeWaiting: Bool { (claude?.waiting ?? 0) > 0 }
        var claudeCompleted: Bool { (claude?.completed ?? 0) > 0 }
        var deepSeekWorking: Bool { deepSeek?.isWorking == true }
        var deepSeekWaiting: Bool { (deepSeek?.waiting ?? 0) > 0 }
        var deepSeekCompleted: Bool { (deepSeek?.completed ?? 0) > 0 }
    }

    /// The catalog and the actual island use exactly the same default geometry.
    nonisolated static func defaultSize(for configuration: IslandLengthConfiguration, geometry: IslandNotchGeometry? = nil) -> CGSize {
        let notchGeometry = geometry ?? Self.notchGeometry
        let compactHeight = notchGeometry.compactHeight
        if configuration.mode.isExpanded {
            if configuration.mode == .expandedGreeting {
                return CGSize(width: max(greetingExpandedSize.width, notchGeometry.minimumExpandedWidth),
                              height: greetingExpandedSize.height + (configuration.showsNotes ? 100 : 0))
            }
            if configuration.mode == .expandedTimerFinished {
                return CGSize(width: max(expandedSize.width, notchGeometry.minimumExpandedWidth), height: expandedSize.height)
            }
            let layout = IslandExpandedLayout(configuration: configuration)
            return CGSize(width: max(layout.width, notchGeometry.minimumExpandedWidth), height: layout.height)
        }
        if configuration.mode == .hovered, configuration.orderedAgents.isEmpty,
           configuration.compactActivities.isEmpty {
            return CGSize(width: notchGeometry.idleWidth + 40, height: compactHeight)
        }
        return CGSize(width: compactContent(for: configuration)?.width(geometry: notchGeometry)
                        ?? IslandCompactMetrics.width(for: configuration, geometry: notchGeometry),
                      height: compactHeight)
    }

    /// Historical identity retained for interpreting the archived v1 preferences.
    /// The notch-aware defaults never fall back to these obsolete shell widths.
    nonisolated static func legacyLengthKey(for configuration: IslandLengthConfiguration) -> String? {
        guard configuration.pomodoro == .off && configuration.enabledAlarmCount == 0 && configuration.recording == .off else { return nil }
        guard configuration.timer != .alarm else { return nil }
        guard configuration.mode == .compact else { return nil }
        let flags = LayoutFlags(agents: configuration.orderedAgents)
        let timer = configuration.timer.hasHours.map { $0 ? "hours" : "minutes" } ?? "none"
        let activity: String
        if !flags.agents.isEmpty {
            let values = configuration.music
                ? [flags.working, flags.multiple, flags.dual, flags.mixed, flags.claudeWaiting,
                   flags.claudeCompleted, flags.deepSeekWorking, flags.deepSeekWaiting, flags.deepSeekCompleted]
                : [flags.working, flags.multiple, flags.dual, flags.codexOnly, flags.codexAndDeepSeek,
                   flags.mixed, flags.claudeWaiting, flags.claudeCompleted, flags.deepSeekWorking,
                   flags.deepSeekWaiting, flags.deepSeekCompleted]
            activity = "\(configuration.music ? "audio-ai" : "ai").\(values.map { $0 ? "1" : "0" }.joined()).\(timer)"
        } else if configuration.music {
            activity = "audio.\(timer)"
        } else if configuration.timer != .off {
            activity = "timer.\(timer)"
        } else {
            activity = configuration.usb ? "usb" : "idle"
        }
        let battery = configuration.battery.isCharging ? "charging"
            : (configuration.battery.isVisible ? "battery" : "none")
        return "\(activity).\(battery)\(configuration.usb ? ".usb" : "")"
    }

    static func updateForState(
        configuration: IslandLengthConfiguration,
        window: NSWindow?,
        animated: Bool = true
    ) {
        guard let window, let layout = layout(for: window) else { return }
        let geometry = layout.display.islandGeometry
        let screenWidth = layout.display.frame.width
        let settings = IslandLengthSettings.shared
        let liveState = IslandLengthState(configuration: configuration)
        if settings.currentState != liveState {
            DispatchQueue.main.async { settings.show(liveState) }
        }
        let configuration = settings.previewState?.configuration ?? configuration
        let state = IslandLengthState(configuration: configuration)
        layout.configuration = configuration
        let content = compactContent(for: configuration)
        // Wait for the current view's intrinsic measurement instead of briefly
        // expanding to a worst-case estimate before tightening a second time.
        if !configuration.mode.isExpanded && content == nil { return }
        let base = defaultSize(for: configuration, geometry: geometry)
        let isDashboard = configuration.mode.isExpanded && configuration.mode != .expandedGreeting &&
            configuration.mode != .expandedTimerFinished
        let height = isDashboard
            ? IslandExpandedLayout(configuration: configuration, maximumWidth: expandedWidthLimit(screenWidth: screenWidth)).height
            : base.height
        let width: CGFloat
        if !configuration.mode.isExpanded, content != nil,
           settings.customWidth(for: state) == nil,
           settings.previewState == nil || settings.previewDraftWidth == nil {
            width = base.width
        } else {
            width = CGFloat(settings.width(for: state, geometry: geometry, screenWidth: screenWidth,
                draftWidth: settings.previewState == nil ? nil : settings.previewDraftWidth))
        }
        let maximumHeight = max(expandedSize.height, layout.display.frame.height - 48)
        let nextSize = CGSize(width: width, height: min(height, maximumHeight))
        let oldMode = layout.frameMode
        layout.frameMode = configuration.mode
        let nextFrame = frame(for: nextSize, layout: layout)
        guard layout.targetFrame == nil || !nextFrame.approximatelyEquals(layout.targetFrame!, tolerance: 0.01) else { return }
        layout.targetFrame = nextFrame
        if !animated {
            window.setFrame(nextFrame, display: true)
            refreshWindowGeometry(layout)
            return
        }
        let motion: Motion
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            motion = Motion(duration: 0.12, timingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
        } else if configuration.mode.isExpanded {
            motion = .expand
        } else if oldMode.isExpanded {
            motion = .collapse
        } else {
            motion = .compact
        }
        animateFrame(of: window, to: nextSize, layout: layout, motion: motion)
    }

    // 菜单栏：显示 / 隐藏灵动岛
    static func toggleVisible() {
        userWantsWindowVisible.toggle()
        applyWindowVisibility(animated: true)
    }

    /// 解锁问候属于主动展示事件；即使用户此前从菜单隐藏了岛，也要让同一个窗口可见。
    static func ensureVisible() {
        userWantsWindowVisible = true
        applyWindowVisibility(animated: true)
    }

    static func refreshVisibility() {
        applyWindowVisibility(animated: false)
    }

    private static func applyWindowVisibility(animated: Bool) {
        for window in windows { applyWindowVisibility(to: window, animated: animated) }
    }

    private static func applyWindowVisibility(to window: NSWindow, animated: Bool) {
        let shouldBeVisible = userWantsWindowVisible || IslandLengthSettings.shared.previewState != nil
        guard shouldBeVisible != window.isVisible else { return }

        if !shouldBeVisible {
            guard animated else {
                window.orderOut(nil)
                window.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            } completionHandler: {
                // A newly connected screen or greeting may have made the islands visible again.
                if !userWantsWindowVisible && IslandLengthSettings.shared.previewState == nil { window.orderOut(nil) }
                window.alphaValue = 1
            }
        } else {
            position(window: window)
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    /// Settings live inside the time column, so the island always stays centered.
    nonisolated static func islandFrame(for size: CGSize, on screenFrame: CGRect) -> CGRect {
        let workspaceOrigin = screenFrame.midX - size.width / 2
        return CGRect(x: workspaceOrigin, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    // 顶部贴屏幕顶，水平居中。
    private static func frame(for size: CGSize, layout: IslandWindowLayout) -> NSRect {
        let display = layout.display
        if !layout.configuration.mode.isExpanded, let content = compactContent(for: layout.configuration) {
            return content.frame(on: display.frame, geometry: display.islandGeometry,
                                 notchCenterX: display.notchCenterX, shellWidth: size.width)
        }
        return islandFrame(for: size, on: display.frame)
    }

    // 带动画地把窗口移到指定尺寸。
    private static func animateFrame(of window: NSWindow, to size: CGSize, layout: IslandWindowLayout, motion: Motion) {
        let frame = frame(for: size, layout: layout)
        if window.frame.approximatelyEquals(frame) { return }
        if !window.isVisible {
            window.setFrame(frame, display: true)
            refreshWindowGeometry(layout)
            return
        }

        // 动画过程中持续重绘 SwiftUI 内容，避免窗口先变、内容后跳的割裂感。
        window.contentView?.wantsLayer = true
        window.contentView?.layerContentsRedrawPolicy = .duringViewResize
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.duration
            context.timingFunction = motion.timingFunction
            window.animator().setFrame(frame, display: true)
        }
    }

    static func position(window: NSWindow) {
        guard let layout = layout(for: window) else { return }
        let frame = frame(for: window.frame.size, layout: layout)
        window.setFrameOrigin(frame.origin)
        layout.targetFrame = frame
        refreshWindowGeometry(layout)
    }
}

private extension CGSize {
    func approximatelyEquals(_ other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) < tolerance &&
        abs(minY - other.minY) < tolerance &&
        size.approximatelyEquals(other.size, tolerance: tolerance)
    }
}
