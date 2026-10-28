import SwiftUI
import AppKit
import Combine

/// Intrinsic content stays attached to the protected edges as the shell grows.
private struct CompactNotchLayout: Layout {
    let gap: CGFloat
    let notchCenterX: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: proposal.width ?? (gap + sizes.reduce(0) { $0 + $1.width }),
                      height: proposal.height ?? WindowManager.compactHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let center = notchCenterX ?? bounds.midX
        subviews[0].place(at: CGPoint(x: center - gap / 2, y: bounds.midY),
                          anchor: .trailing, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: center + gap / 2, y: bounds.midY),
                          anchor: .leading, proposal: .unspecified)
    }
}

/// A final safeguard for every page, including transitions and priority alerts.
private struct NotchContentMask: Shape {
    let geometry: IslandNotchGeometry
    let notchCenterX: CGFloat?
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if geometry.protectedWidth > 0 {
            path.addRect(geometry.exclusionRect(in: rect, centerX: notchCenterX))
        }
        return path
    }
}

nonisolated private struct CompactContentPreference: Equatable {
    var stateKey = ""
    var left: CGFloat?
    var right: CGFloat?
}

nonisolated private struct CompactContentPreferenceKey: PreferenceKey {
    static var defaultValue: CompactContentPreference { CompactContentPreference() }
    static func reduce(value: inout CompactContentPreference, nextValue: () -> CompactContentPreference) {
        let next = nextValue()
        guard !next.stateKey.isEmpty else { return }
        if value.stateKey != next.stateKey { value = next; return }
        if let left = next.left { value.left = left }
        if let right = next.right { value.right = right }
    }
}

struct ContentView: View {
    @ObservedObject var model: IslandModel
    @StateObject private var audioPlayback: AudioPlaybackMonitor
    @StateObject private var codexStatus: CodexStatusMonitor
    @StateObject private var claudeStatus: ClaudeCodeStatusMonitor
    @StateObject private var deepSeekStatus: DeepSeekHarnessStatusMonitor
    @StateObject private var batteryStatus: BatteryStatusMonitor
    @StateObject private var usbConnection: USBConnectionMonitor
    @StateObject private var computerInformation: ComputerInformationMonitor
    @ObservedObject private var lengthSettings = IslandLengthSettings.shared
    @ObservedObject private var displaySettings: IslandDisplaySettings
    @ObservedObject private var recorder = ScreenRecordingController.shared
    private let honorsDisplaySettings: Bool
    @State private var aiRotationIndex = 0
    @State private var compactActivityOrder: [CompactActivity] = []

    private let previewConfiguration: IslandLengthConfiguration?

    init(model: IslandModel, previewConfiguration: IslandLengthConfiguration? = nil, displaySettings: IslandDisplaySettings? = nil) {
        self.model = model
        self.displaySettings = displaySettings ?? .shared
        honorsDisplaySettings = previewConfiguration == nil || displaySettings != nil
        self.previewConfiguration = previewConfiguration
        _audioPlayback = StateObject(wrappedValue: AudioPlaybackMonitor(previewConfiguration: previewConfiguration))
        _codexStatus = StateObject(wrappedValue: CodexStatusMonitor(
            previewTasks: previewConfiguration.map { IslandPreviewTasks.codex($0) },
            previewExpanded: previewConfiguration?.mode == .expandedAgent
        ))
        _claudeStatus = StateObject(wrappedValue: ClaudeCodeStatusMonitor(previewTasks: previewConfiguration.map { IslandPreviewTasks.claude($0) }))
        _deepSeekStatus = StateObject(wrappedValue: DeepSeekHarnessStatusMonitor(previewTasks: previewConfiguration.map { IslandPreviewTasks.deepSeek($0) }))
        _batteryStatus = StateObject(wrappedValue: BatteryStatusMonitor(previewConfiguration: previewConfiguration))
        _usbConnection = StateObject(wrappedValue: USBConnectionMonitor(previewConfiguration: previewConfiguration))
        _computerInformation = StateObject(wrappedValue: ComputerInformationMonitor(preview: previewConfiguration != nil))
    }

    private let aiRotationTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var displaySnapshot: IslandDisplaySettingsSnapshot {
        let base: IslandDisplaySettingsSnapshot = honorsDisplaySettings ? displaySettings.snapshot : .init()
        if let previewConfiguration {
            var preview = base
            if !previewConfiguration.showsTimeTools {
                preview.hiddenFeatures.formUnion([.timer, .pomodoro, .alarm])
            }
            if !previewConfiguration.showsRecordingTools { preview.hiddenFeatures.insert(.recording) }
            return preview
        }
        return recorder.displaySnapshot(base)
    }

    private var isAIVisible: Bool { !availableAIProviders.isEmpty }

    private var isAnyExpanded: Bool {
        model.isExpanded || (displaySnapshot.isEnabled(.music) && audioPlayback.isExpanded)
            || (displaySnapshot.isEnabled(.codex) && codexStatus.isExpanded)
    }

    var body: some View {
        // 外壳始终是同一个 Shape；状态变化时只改变窗口尺寸和内部内容。
        // 避免紧凑岛与展开卡片交叉淡入时，顶部背景叠加闪动。
        IslandShape()
            .fill(.black)
            .overlay {
                IslandShape()
                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
            }
            .overlay(alignment: .top) {
                ZStack {
                    ZStack {
                        if previewConfiguration == nil, let state = lengthSettings.previewState {
                            IslandStatePreview(configuration: state.configuration)
                                .id(state.configuration)
                                .allowsHitTesting(false)
                        } else if model.isPersistentAlertVisible {
                            CardView(model: model, displaySnapshot: displaySnapshot)
                                .transition(.islandContent)
                        } else if isAnyExpanded {
                            ExpandedIslandDashboard(
                                model: model,
                                audioPlayback: audioPlayback,
                                codexStatus: codexStatus,
                                claudeStatus: claudeStatus,
                                deepSeekStatus: deepSeekStatus,
                                usbConnection: usbConnection,
                                computerInformation: computerInformation,
                                batteryStatus: batteryStatus,
                                includesComputer: previewConfiguration?.computer ?? true,
                                includesNotes: previewConfiguration?.showsNotes ?? true,
                                displaySnapshot: displaySnapshot,
                                usesWindowLayout: previewConfiguration == nil
                            )
                            .transition(.islandContent)
                        } else {
                            compactIsland
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                // 页面只在同一个灵动岛外壳内移动。不能让每一页各自携带
                // 矩形背景，否则缩放/横移时会在四角露出方形边缘。
                .clipShape(IslandShape())
                .mask(NotchContentMask(geometry: WindowManager.notchGeometry, notchCenterX: WindowManager.windowNotchCenterX).fill(style: FillStyle(eoFill: true)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay {
                if !isAnyExpanded && lengthSettings.previewState == nil && previewConfiguration == nil {
                    Button {
                        model.isExpanded = true
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("展开灵动岛")
                }
            }
            .overlay(alignment: .topTrailing) {
                if isAnyExpanded && lengthSettings.previewState == nil && previewConfiguration == nil {
                    Button {
                        IslandSettingsWindow.show()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.76))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开设置")
                    .padding(.top, 2)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .mask(NotchContentMask(geometry: WindowManager.notchGeometry, notchCenterX: WindowManager.windowNotchCenterX).fill(style: FillStyle(eoFill: true)))
                }
            }
            .overlay {
                if !model.isSessionUnlocked {
                    IslandShape().fill(.black)
                        .overlay {
                            Image(systemName: "lock.fill").foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .mask(NotchContentMask(geometry: WindowManager.notchGeometry, notchCenterX: WindowManager.windowNotchCenterX).fill(style: FillStyle(eoFill: true)))
                        }
                        .allowsHitTesting(true)
                }
            }
            .accessibilityHidden(!model.isSessionUnlocked)
            .transaction { if !model.isSessionUnlocked { $0.animation = nil } }
            .animation(IslandMotion.container, value: model.isExpanded)
            .animation(IslandMotion.container, value: audioPlayback.isExpanded)
            .animation(IslandMotion.container, value: codexStatus.isExpanded)
            .animation(IslandMotion.content, value: audioPlayback.isPlaying)
            .animation(IslandMotion.content, value: codexStatus.task)
            .animation(IslandMotion.content, value: claudeStatus.task)
            .animation(IslandMotion.content, value: deepSeekStatus.task)
            .animation(IslandMotion.providerPage, value: displayedAIProviders)
            .animation(IslandMotion.content, value: badgeOnlyProviders)
            .animation(IslandMotion.content, value: compactLayout)
            .onChange(of: visibleCompactActivities, initial: true) { _, visible in
                compactActivityOrder = CompactActivityLayout(
                    visible: visible, previousOrder: compactActivityOrder
                ).orderedActivities
            }
            .onChange(of: displaySnapshot) { _, visibility in
                if !visibility.isEnabled(.unlockGreeting) { model.dismissUnlockGreeting() }
            }
            .animation(IslandMotion.content, value: batteryStatus.isVisible)
            .animation(IslandMotion.content, value: usbConnection.device)
            .animation(IslandMotion.content, value: usbConnection.phone)
            .onReceive(aiRotationTimer) { _ in
                if availableAIProviders.count > 2 || pinnedAIProviders.count == 1 {
                    aiRotationIndex = (aiRotationIndex + 1) % 3_000
                }
            }
            .animation(IslandMotion.container, value: lengthSettings.previewState?.key)
            .environment(\.colorScheme, .dark)
            .alert("录屏提示", isPresented: Binding(get: { recorder.errorMessage != nil },
                                                 set: { if !$0 { recorder.errorMessage = nil } })) {
                Button("知道了") { recorder.errorMessage = nil }
            } message: { Text(recorder.errorMessage ?? "") }
            .background {
                if previewConfiguration == nil {
                    WindowAccessor(
                        model: model,
                        notes: model.notes,
                        audioPlayback: audioPlayback,
                        codexStatus: codexStatus,
                        claudeStatus: claudeStatus,
                        deepSeekStatus: deepSeekStatus,
                        batteryStatus: batteryStatus,
                        usbConnection: usbConnection
                    )
                }
            }
    }

    private var visibleCompactActivities: [CompactActivity] {
        var activities: [CompactActivity] = []
        if audioPlayback.isPlaying { activities.append(.audio) }
        if model.isTimerRunning { activities.append(.timer) }
        if model.pomodoro.isRunning { activities.append(.pomodoro) }
        if model.enabledAlarmCount > 0 { activities.append(.alarm) }
        if batteryStatus.isVisible { activities.append(.battery) }
        if usbConnection.device != nil { activities.append(.usb) }
        if previewConfiguration?.recording.hasHours != nil || (previewConfiguration == nil && recorder.compactActivity != .off) {
            activities.append(.recording)
        }
        return activities.filter { displaySnapshot.isActivityEnabled($0) }
    }

    private var compactLayout: CompactActivityLayout {
        CompactActivityLayout(visible: visibleCompactActivities, previousOrder: compactActivityOrder)
    }

    private var compactIsland: some View {
        let configuration = previewConfiguration ?? WindowAccessor.configuration(
            model: model, notes: model.notes, audioPlayback: audioPlayback,
            codexStatus: codexStatus, claudeStatus: claudeStatus, deepSeekStatus: deepSeekStatus,
            batteryStatus: batteryStatus, usbConnection: usbConnection, recorder: recorder,
            visibility: displaySnapshot)
        let key = configuration.key
        return CompactNotchLayout(gap: WindowManager.notchGeometry.protectedWidth,
                                  notchCenterX: WindowManager.windowNotchCenterX) {
            compactLane(.left)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: CompactContentPreferenceKey.self,
                            value: CompactContentPreference(stateKey: key, left: proxy.size.width))
                    }
                }
            compactLane(.right)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: CompactContentPreferenceKey.self,
                            value: CompactContentPreference(stateKey: key, right: proxy.size.width))
                    }
                }
        }
        .padding(.horizontal, IslandCompactMetrics.outerPadding)
        .frame(height: WindowManager.compactHeight)
        .foregroundStyle(.white)
        .onPreferenceChange(CompactContentPreferenceKey.self) { value in
            guard let left = value.left, let right = value.right else { return }
            let content = IslandCompactContentSize(left: left, right: right)
            DispatchQueue.main.async {
                WindowManager.reportCompactContent(content, stateKey: value.stateKey)
            }
        }
    }

    private func compactLane(_ side: CompactSide) -> some View {
        HStack(spacing: 12) {
            if side == .right, isAIVisible {
                compactAIContent(side)
                if !compactLayout.activities(on: side).isEmpty { compactDivider }
            }
            let activities = compactLayout.activities(on: side)
            ForEach(activities) { activity in
                if activity != activities.first { compactDivider }
                compactActivityContent(activity, side: side, isDual: activity == compactLayout.dual)
            }
            if side == .left, isAIVisible {
                if !activities.isEmpty { compactDivider }
                compactAIContent(side)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func compactAIContent(_ side: CompactSide) -> some View {
        let providers = displayedAIProviders
        let isPaired = providers.count == 2
        let laneProviders = isPaired ? [providers[side == .left ? 0 : 1]] : providers
        return HStack(spacing: 12) {
            ForEach(laneProviders) { provider in
                compactProviderSlot(provider, side: side, isPaired: isPaired)
            }
        }
    }

    @ViewBuilder
    private func compactActivityContent(_ activity: CompactActivity, side: CompactSide, isDual: Bool) -> some View {
        switch activity {
        case .recording:
            if isDual {
                if side == .left { recordingDot }
                else { recordingTimeLabel }
            } else {
                HStack(spacing: 6) {
                    recordingDot
                    recordingTimeLabel
                }
            }
        case .audio:
            if isDual {
                if side == .left { compactAudioIcon }
                else { AudioWaveformView(themeColor: audioPlayback.artworkThemeColor) }
            } else {
                HStack(spacing: 6) {
                    compactAudioIcon
                    AudioWaveformView(themeColor: audioPlayback.artworkThemeColor)
                }
            }
        case .timer, .pomodoro, .alarm:
            let tool: IslandTimeTool = activity == .timer ? .timer : activity == .pomodoro ? .pomodoro : .alarm
            if isDual {
                if side == .left { compactTimeToolIcon(tool) }
                else { compactTimeToolLabel(tool) }
            } else {
                HStack(spacing: 6) {
                    compactTimeToolIcon(tool)
                    compactTimeToolLabel(tool)
                }
            }
        case .battery:
            if isDual && side == .left {
                if let status = batteryStatus.status {
                    BatteryTimeRemainingLabel(batteryStatus: batteryStatus, isCharging: status.isCharging)
                }
            } else {
                compactBattery
            }
        case .usb:
            if isDual {
                if side == .left { compactUSBIcon }
                else { compactUSBLabel }
            } else {
                HStack(spacing: 6) { compactUSBIcon; compactUSBLabel }
            }
        }
    }

    private var compactAudioIcon: some View {
        Image(nsImage: audioPlayback.sourceIcon ?? fallbackAudioIcon)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 21)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var recordingDot: some View {
        RecordingStatusDot(isCountingDown: recordingIsCountingDown, isPaused: recordingIsPaused)
    }

    private var recordingIsCountingDown: Bool {
        previewConfiguration == nil && recorder.phase == .countdown
    }

    private var recordingTimeLabel: some View {
        RecordingTimeLabel(text: recordingText, isPaused: recordingIsPaused,
                           isCountingDown: recordingIsCountingDown,
                           elapsed: previewConfiguration == nil && !recordingIsCountingDown
                               ? { recorder.elapsedTime } : nil)
    }

    private var recordingText: String {
        if let previewConfiguration { return previewConfiguration.recording.hasHours == true ? "01:02:05" : "01:25.30" }
        return recorder.compactText
    }
    private var recordingIsPaused: Bool {
        if let previewConfiguration { return [.pausedMinutes, .pausedHours].contains(previewConfiguration.recording) }
        return recorder.isPaused
    }

    private var fallbackAudioIcon: NSImage {
        NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "音频播放") ?? NSImage()
    }

    private var compactUSBIcon: some View {
        Image(systemName: "cable.connector")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.cyan)
    }

    private func compactTimeToolIcon(_ tool: IslandTimeTool) -> some View {
        TimeToolIcon(tool: tool, isPaused: model.isPaused(tool), size: 16)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(model.isPaused(tool) ? Color.yellow : Color.mint)
            .frame(width: 16, height: 24)
            .animation(IslandMotion.content, value: model.isPaused(tool))
    }

    private func compactTimeToolLabel(_ tool: IslandTimeTool) -> some View {
        Text(tool == .alarm ? "\(model.enabledAlarmCount)" : model.compactText(for: tool))
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText(countsDown: tool != .alarm))
            .animation(IslandMotion.control, value: model.compactText(for: tool))
            .accessibilityLabel(tool == .alarm ? "\(model.enabledAlarmCount) 个已启用的闹钟" : model.compactText(for: tool))
    }

    private var availableAIProviders: [IslandAgentProvider] {
        IslandAgentProvider.allCases.filter {
            switch $0 {
            case .codex: displaySnapshot.isEnabled(.codex) && codexStatus.isVisible
            case .claude: displaySnapshot.isEnabled(.claude) && claudeStatus.isVisible
            case .deepSeek: displaySnapshot.isEnabled(.deepSeek) && deepSeekStatus.isVisible
            }
        }
    }

    private var badgeOnlyProviders: [IslandAgentProvider] {
        availableAIProviders.filter { hasUnreadCompletion($0) && !hasOtherTaskStatus($0) }
    }

    private func hasOtherTaskStatus(_ provider: IslandAgentProvider) -> Bool {
        switch provider {
        case .codex: codexStatus.tasks.contains { $0.state != .completed }
        case .claude: claudeStatus.tasks.contains { $0.state != .completed }
        case .deepSeek: deepSeekStatus.tasks.contains { $0.state != .completed }
        }
    }

    private var pinnedAIProviders: [IslandAgentProvider] {
        var providers: [IslandAgentProvider] = []
        // 待确认优先；未查看的完成提醒持续占用可轮换的槽位。
        for provider in availableAIProviders where isProviderWaiting(provider) {
            providers.append(provider)
        }
        for provider in availableAIProviders
            where hasUnreadCompletion(provider) && !providers.contains(provider) {
            providers.append(provider)
        }
        return providers
    }

    private var displayedAIProviders: [IslandAgentProvider] {
        // Completed-only providers occupy the same slots as every other status.
        // Otherwise a working/completed pair incorrectly becomes one split
        // provider plus a completion badge spread across both sides.
        let available = availableAIProviders
        guard available.count > 2 else { return available }
        let pinned = pinnedAIProviders
        if pinned.count > 2 {
            let start = aiRotationIndex % pinned.count
            return [pinned[start], pinned[(start + 1) % pinned.count]]
        }
        if pinned.count == 2 { return pinned }
        if let fixed = pinned.first {
            let rotating = available.filter { $0 != fixed }
            return [rotating[aiRotationIndex % rotating.count], fixed]
        }
        let start = aiRotationIndex % available.count
        return [available[start], available[(start + 1) % available.count]]
    }

    @ViewBuilder
    private func compactProviderContent(_ provider: IslandAgentProvider, side: CompactSide, showsName: Bool = true) -> some View {
        switch provider {
        case .codex: compactCodexContent(side: side, showsName: showsName)
        case .claude: compactClaudeContent(side: side, showsName: showsName)
        case .deepSeek: compactDeepSeekContent(side: side, showsName: showsName)
        }
    }

    private func compactProviderSlot(_ provider: IslandAgentProvider, side: CompactSide, isPaired: Bool) -> some View {
        ZStack {
            Group {
                if isPaired {
                    // Every state keeps its icon and associated content together
                    // when two providers share the island, including terminal states.
                    HStack(spacing: 7) {
                        compactProviderContent(provider, side: .left, showsName: !isProviderOngoing(provider))
                        compactProviderContent(provider, side: .right)
                    }
                    .accessibilityLabel(provider.shortTitle)
                } else if badgeOnlyProviders.contains(provider) {
                    if side == .left {
                        HStack(spacing: 4) {
                            compactProviderIcon(provider).frame(width: 18, height: 18)
                            unreadCompletionDot
                        }
                        .accessibilityLabel("\(provider.shortTitle) 有未查看的完成任务")
                    } else {
                        Text("\(provider.shortTitle) · 已完成")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.56))
                    }
                } else {
                    compactProviderContent(provider, side: side)
                }
            }
            .id(provider)
            .transition(.compactProviderPage)
        }
        .clipped()
    }

    private func isProviderWaiting(_ provider: IslandAgentProvider) -> Bool {
        switch provider {
        case .codex: false
        case .claude: !claudeStatus.waitingTasks.isEmpty
        case .deepSeek: deepSeekStatus.isWaiting
        }
    }

    private func isProviderOngoing(_ provider: IslandAgentProvider) -> Bool {
        switch provider {
        case .codex: codexStatus.activeTaskCount > 0
        case .claude: claudeStatus.ongoingTaskCount > 0
        case .deepSeek: deepSeekStatus.ongoingTaskCount > 0
        }
    }

    private func hasUnreadCompletion(_ provider: IslandAgentProvider) -> Bool {
        switch provider {
        case .codex: codexStatus.hasUnreadCompletion
        case .claude: claudeStatus.hasUnreadCompletion
        case .deepSeek: deepSeekStatus.hasUnreadCompletion
        }
    }

    private var unreadCompletionDot: some View {
        Circle()
            .fill(Color.blue)
            .frame(width: 6, height: 6)
            .accessibilityLabel("有未查看的完成任务")
    }

    @ViewBuilder
    private func compactProviderIcon(_ provider: IslandAgentProvider) -> some View {
        switch provider {
        case .codex:
            Image("CodexStatusIcon")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
        case .claude:
            Image(systemName: "sun.max.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.orange)
        case .deepSeek:
            Image("DeepSeekStatusIcon")
                .resizable()
                .scaledToFit()
        }
    }

    private var compactDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 16)
    }

    private var compactBattery: some View {
        Group {
            if let status = batteryStatus.status {
                CompactBatteryView(status: status)
            }
        }
        .fixedSize()
    }

    private var compactUSBLabel: some View {
        Text(usbConnection.device?.type ?? "USB 设备")
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .help(usbConnection.device?.name ?? "USB 设备")
            .accessibilityLabel("USB 已连接：\(usbConnection.device?.type ?? "USB 设备")")
    }

    private func compactCodexContent(side: CompactSide, showsName: Bool) -> some View {
        HStack(spacing: 7) {
            if side == .left {
                Group {
                    if codexStatus.isWorking {
                        CodexWorkingIcon()
                    } else if codexStatus.task?.state == .completed {
                        Image("CodexStatusIcon")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: codexStatus.task?.state.symbolName ?? "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(codexColor)
                    }
                }
                .frame(width: 18, height: 18)
                if codexStatus.hasUnreadCompletion { unreadCompletionDot }
                if showsName {
                    Text(codexStatus.isWorking ? "Codex" : "Codex · \(codexStatus.task?.state.label ?? "")")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
            } else {
                if codexStatus.activeTaskCount > 0 {
                    Text("×\(codexStatus.activeTaskCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                        .contentTransition(.numericText(value: Double(codexStatus.activeTaskCount)))
                        .animation(IslandMotion.control, value: codexStatus.activeTaskCount)
                }
                if let task = codexStatus.activeTasks.first ?? codexStatus.task,
                   task.state != .completed {
                    AgentElapsedLabel(startedAt: task.startedAt, updatedAt: task.updatedAt,
                                      isWorking: task.state == .working, stateLabel: task.state.label)
                }
            }
        }
    }

    private var codexColor: Color {
        switch codexStatus.task?.state {
        case .working: .cyan
        case .completed: .green
        case .failed: .red
        case .interrupted: .gray
        case nil: .white
        }
    }

    private func compactClaudeContent(side: CompactSide, showsName: Bool) -> some View {
        HStack(spacing: 7) {
            if side == .left {
                Group {
                    if claudeStatus.isWorking {
                        ClaudeWorkingIcon()
                    } else if claudeStatus.task?.state == .waiting {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.orange)
                    } else if claudeStatus.task?.state == .completed {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: claudeStatus.task?.state.symbolName ?? "sparkles")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(claudeColor)
                    }
                }
                .frame(width: 18, height: 18)
                if claudeStatus.hasUnreadCompletion { unreadCompletionDot }
                if showsName {
                    Text(claudeStatus.task?.state == .waiting
                         ? "Claude"
                         : (claudeStatus.isWorking ? "Claude" : "Claude · \(claudeStatus.task?.state.label ?? "")"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
            } else {
                if claudeStatus.ongoingTaskCount > 0 {
                    Text("×\(claudeStatus.ongoingTaskCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.56))
                        .contentTransition(.numericText(value: Double(claudeStatus.ongoingTaskCount)))
                        .animation(IslandMotion.control, value: claudeStatus.ongoingTaskCount)
                }
                if let task = claudeStatus.task, task.state != .completed {
                    AgentElapsedLabel(startedAt: task.startedAt, updatedAt: task.updatedAt,
                                      isWorking: task.state == .working, stateLabel: task.state.label)
                }
                if claudeStatus.task?.state == .waiting {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 6, height: 6)
                        Text("待确认")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var claudeColor: Color {
        switch claudeStatus.task?.state {
        case .working: .orange
        case .waiting: .yellow
        case .completed: .green
        case .interrupted: .gray
        case nil: .white
        }
    }

    private func compactDeepSeekContent(side: CompactSide, showsName: Bool) -> some View {
        HStack(spacing: 7) {
            if side == .left {
                Group {
                    if deepSeekStatus.isWaiting {
                        Image("DeepSeekStatusIcon")
                            .resizable()
                            .scaledToFit()
                    } else if deepSeekStatus.isWorking {
                        DeepSeekWorkingIcon()
                    } else if deepSeekStatus.task?.state == .completed {
                        Image("DeepSeekStatusIcon")
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: deepSeekStatus.task?.state.symbolName ?? "fish.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(deepSeekColor)
                    }
                }
                .frame(width: 18, height: 18)
                if deepSeekStatus.hasUnreadCompletion { unreadCompletionDot }
                if showsName {
                    Text(deepSeekStatus.isWaiting
                         ? "DeepSeek"
                         : (deepSeekStatus.isWorking ? "DeepSeek" : "DeepSeek · \(deepSeekStatus.task?.state.label ?? "")"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
            } else {
                if deepSeekStatus.ongoingTaskCount > 0 {
                    Text("×\(deepSeekStatus.ongoingTaskCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                        .contentTransition(.numericText(value: Double(deepSeekStatus.ongoingTaskCount)))
                        .animation(IslandMotion.control, value: deepSeekStatus.ongoingTaskCount)
                }
                if let task = deepSeekStatus.task, task.state != .completed {
                    AgentElapsedLabel(startedAt: task.startedAt, updatedAt: task.updatedAt,
                                      isWorking: task.state == .working, stateLabel: task.state.label)
                }
                if deepSeekStatus.isWaiting {
                    HStack(spacing: 4) {
                        Circle().fill(Color.yellow).frame(width: 6, height: 6)
                        Text("待确认")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var deepSeekColor: Color {
        switch deepSeekStatus.task?.state {
        case .working: .blue
        case .waiting: .yellow
        case .completed: .green
        case .interrupted: .gray
        case nil: .white
        }
    }

}

private struct BatteryTimeRemainingLabel: View {
    @ObservedObject var batteryStatus: BatteryStatusMonitor
    let isCharging: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let isFullyCharged = isCharging && batteryStatus.status?.percentage == 100
            let estimatedDate = isCharging
                ? batteryStatus.status?.estimatedFullDate
                : batteryStatus.status?.estimatedEmptyDate
            let minutes = estimatedDate.map {
                max(0, Int(ceil($0.timeIntervalSince(context.date) / 60)))
            }
            Text(isFullyCharged ? "已充满" : Self.displayText(for: minutes))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(isCharging
                    ? Color(red: 101 / 255, green: 220 / 255, blue: 122 / 255)
                    : .red)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText(countsDown: true))
                .animation(IslandMotion.control, value: minutes)
                .animation(IslandMotion.control, value: isFullyCharged)
                .accessibilityLabel(isFullyCharged
                    ? "已充满"
                    : Self.accessibilityText(for: minutes, isCharging: isCharging))
        }
    }

    private static func displayText(for minutes: Int?) -> String {
        guard let minutes else { return "计算中" }
        if minutes >= 60 { return "\(minutes / 60)h\(minutes % 60)m" }
        return "\(minutes)m"
    }

    private static func accessibilityText(for minutes: Int?, isCharging: Bool) -> String {
        guard let minutes else {
            return isCharging ? "正在计算充满时间" : "正在计算剩余使用时间"
        }
        let prefix = isCharging ? "预计距离充满还有" : "预计剩余使用时间"
        return "\(prefix) \(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}

/// Separate the persistent tools, task list and playback within one island.
private struct DashedIslandDivider: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
            }
            .stroke(Color.gray.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
        }
        .frame(width: 1)
        .padding(.top, 42)
        .padding(.bottom, 18)
        .accessibilityHidden(true)
    }
}

private struct ExpandedIslandDashboard: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var audioPlayback: AudioPlaybackMonitor
    @ObservedObject var codexStatus: CodexStatusMonitor
    @ObservedObject var claudeStatus: ClaudeCodeStatusMonitor
    @ObservedObject var deepSeekStatus: DeepSeekHarnessStatusMonitor
    @ObservedObject var usbConnection: USBConnectionMonitor
    @ObservedObject var computerInformation: ComputerInformationMonitor
    @ObservedObject var batteryStatus: BatteryStatusMonitor
    var includesComputer = true
    var includesNotes = true
    @ObservedObject private var lengthSettings = IslandLengthSettings.shared
    var displaySnapshot = IslandDisplaySettingsSnapshot()
    var usesWindowLayout = true

    private var taskCount: Int {
        (displaySnapshot.isEnabled(.codex) ? codexStatus.tasks.count : 0)
            + (displaySnapshot.isEnabled(.claude) ? claudeStatus.tasks.count : 0)
            + (displaySnapshot.isEnabled(.deepSeek) ? deepSeekStatus.tasks.count : 0)
    }
    private var showsMusic: Bool { displaySnapshot.isEnabled(.music) && audioPlayback.isPlaying }
    private var hasEnabledTimeTools: Bool {
        displaySnapshot.isEnabled(.timer) || displaySnapshot.isEnabled(.pomodoro) || displaySnapshot.isEnabled(.alarm)
    }
    private var showsRecordingColumn: Bool { displaySnapshot.isEnabled(.recording) }
    private var showsComputer: Bool { includesComputer && displaySnapshot.isEnabled(.computer) }
    private var showsNotes: Bool { includesNotes && model.isSessionUnlocked && displaySnapshot.isEnabled(.notes) }
    private var showsPhone: Bool { displaySnapshot.isEnabled(.usb) && usbConnection.phone != nil }
    private var configuration: IslandLengthConfiguration {
        IslandLengthConfiguration(mode: .expandedTimerSetup,
            music: showsMusic, expandedTaskCount: taskCount, showsTimeTools: hasEnabledTimeTools,
            showsRecordingTools: showsRecordingColumn, phone: showsPhone, showsNotes: showsNotes, computer: showsComputer)
    }
    private var layout: IslandExpandedLayout {
        IslandExpandedLayout(configuration: configuration,
            maximumWidth: usesWindowLayout ? WindowManager.currentExpandedWidthLimit : 1_000)
    }
    private var workspaceWidth: CGFloat {
        CGFloat(lengthSettings.width(for: IslandLengthState(configuration: configuration)))
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = layout
            let width = usesWindowLayout ? workspaceWidth : geometry.size.width
            let extraWidth = max(0, width - layout.width)
            let flexibleGroup = layout.groups.max { $0.width < $1.width }?.id
            HStack(alignment: .top, spacing: 0) {
                ForEach(layout.groups) { group in
                    if group.id != layout.groups.first?.id { DashedIslandDivider() }
                    ExpandedIslandGroup(group: group,
                                        width: group.width + (group.id == flexibleGroup ? extraWidth : 0), model: model) { column, height in
                        columnContent(column, height: height)
                    }
                }
            }
            .frame(height: layout.height, alignment: .top)
            // Keep page widths stable while AppKit animates the window shell.
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            model.isPomodoroSettingsPresented = false
            model.isRecordingSettingsPresented = false
        }
    }

    @ViewBuilder
    private func columnContent(_ column: IslandExpandedColumn, height: CGFloat) -> some View {
        Group {
            switch column {
            case .computer:
                ComputerDetailsView(computer: computerInformation, battery: batteryStatus)
            case .work:
                AIExpandedCard(codexStatus: codexStatus, claudeStatus: claudeStatus,
                               deepSeekStatus: deepSeekStatus, displaySnapshot: displaySnapshot)
            case .music:
                AudioExpandedCard(audioPlayback: audioPlayback)
            case .time:
                CardView(model: model, embedded: true, displaySnapshot: displaySnapshot)
            case .notes:
                NotesCard(store: model.notes, model: model)
            case .phone:
                if let phone = usbConnection.phone {
                    PhoneDetailsView(device: phone, information: usbConnection.phoneInformation)
                        .id(phone.registryID)
                }
            case .recording:
                RecordingToolView(model: model)
                    .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(model: IslandModel())
    }
}
