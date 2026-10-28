import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {

    @ObservedObject private var lengthSettings = IslandLengthSettings.shared
    @ObservedObject private var displaySettings = IslandDisplaySettings.shared
    @ObservedObject var model: IslandModel
    @ObservedObject var notes: NotesStore
    @ObservedObject var audioPlayback: AudioPlaybackMonitor
    @ObservedObject var codexStatus: CodexStatusMonitor
    @ObservedObject var claudeStatus: ClaudeCodeStatusMonitor
    @ObservedObject var deepSeekStatus: DeepSeekHarnessStatusMonitor
    @ObservedObject var batteryStatus: BatteryStatusMonitor
    @ObservedObject var usbConnection: USBConnectionMonitor
    @ObservedObject private var recorder = ScreenRecordingController.shared

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let configuration = lengthConfiguration

        DispatchQueue.main.async {
            // 窗口由 AppDelegate 创建并配置，这里只管启动鼠标监听
            context.coordinator.startMonitoring(
                view: view,
                model: model,
                audioPlayback: audioPlayback,
                codexStatus: codexStatus,
                claudeStatus: claudeStatus,
                deepSeekStatus: deepSeekStatus
            )
            WindowManager.updateForState(configuration: configuration, window: view.window)
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        WindowManager.updateForState(
            configuration: lengthConfiguration,
            window: nsView.window
        )
    }

    private var lengthConfiguration: IslandLengthConfiguration {
        Self.configuration(model: model, notes: notes, audioPlayback: audioPlayback,
            codexStatus: codexStatus, claudeStatus: claudeStatus, deepSeekStatus: deepSeekStatus,
            batteryStatus: batteryStatus, usbConnection: usbConnection, recorder: recorder,
            visibility: recorder.displaySnapshot(displaySettings.snapshot))
    }

    static func configuration(model: IslandModel, notes: NotesStore, audioPlayback: AudioPlaybackMonitor,
        codexStatus: CodexStatusMonitor, claudeStatus: ClaudeCodeStatusMonitor,
        deepSeekStatus: DeepSeekHarnessStatusMonitor, batteryStatus: BatteryStatusMonitor,
        usbConnection: USBConnectionMonitor, recorder: ScreenRecordingController,
        visibility: IslandDisplaySettingsSnapshot) -> IslandLengthConfiguration {
        let codex = IslandAgentActivity(provider: .codex, statuses: codexStatus.tasks.map {
            switch $0.state {
            case .working: .working
            case .completed: .completed
            case .failed: .failed
            case .interrupted: .interrupted
            }
        })
        let claude = IslandAgentActivity(provider: .claude, statuses: claudeStatus.tasks.map {
            switch $0.state {
            case .working: .working
            case .waiting: .waiting
            case .completed: .completed
            case .interrupted: .interrupted
            }
        })
        let deepSeek = IslandAgentActivity(provider: .deepSeek, statuses: deepSeekStatus.tasks.map {
            switch $0.state {
            case .working: .working
            case .waiting: .waiting
            case .completed: .completed
            case .interrupted: .interrupted
            }
        })
        var configuration = IslandLengthConfiguration(
            agents: [codex, claude, deepSeek].filter { $0.taskCount > 0 },
            music: audioPlayback.isPlaying,
            usb: usbConnection.device != nil,
            phone: usbConnection.phone != nil,
            computer: true
        )
        configuration.showsNotes = model.isSessionUnlocked &&
            (model.activeUnlockGreeting == nil || !notes.unlockMemos.isEmpty)
        configuration.expandedTaskCount = codexStatus.tasks.count + claudeStatus.tasks.count + deepSeekStatus.tasks.count
        if model.isTimerRunning {
            configuration.timer = model.isTimerPaused
                ? (model.timerHasHours ? .pausedHours : .pausedMinutes)
                : (model.timerHasHours ? .runningHours : .runningMinutes)
        }
        if model.pomodoro.isRunning {
            let hasHours = model.pomodoro.remaining >= 3600
            configuration.pomodoro = model.pomodoro.isPaused
                ? (hasHours ? .pausedHours : .pausedMinutes)
                : (hasHours ? .runningHours : .runningMinutes)
        }
        configuration.enabledAlarmCount = model.enabledAlarmCount
        if configuration.timer == .off && configuration.pomodoro == .off && model.enabledAlarmCount > 0 {
            configuration.timer = .alarm
        }
        if let status = batteryStatus.status {
            configuration.battery = status.isCharging
                ? (status.isLow ? .lowCharging : .charging)
                : (status.isLow ? .low : .normal)
        }
        configuration.recording = recorder.compactActivity
        configuration = visibility.filtering(configuration)
        let isExpanded = model.isExpanded ||
            (visibility.isEnabled(.codex) && codexStatus.isExpanded) ||
            (visibility.isEnabled(.music) && audioPlayback.isExpanded && audioPlayback.isPlaying)
        if isExpanded {
            if model.isTimerFinished {
                configuration.mode = .expandedTimerFinished
            } else if model.activeUnlockGreeting != nil {
                configuration.mode = .expandedGreeting
            } else {
                configuration.mode = .expandedTimerSetup
            }
        } else if model.isHovered, configuration.agents.isEmpty,
                  !configuration.music, configuration.compactActivities.isEmpty {
            configuration.mode = .hovered
        }
        return configuration
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    // 鼠标轮询仅负责悬停和自动收起；点击交给 SwiftUI 原生按钮。
    // - 轮询鼠标位置判断悬停（窗口动画中也不会误判）
    // - 展开后鼠标移出 → 短暂宽限期，移回就重置，否则自动收起
    final class Coordinator {
        private weak var view: NSView?
        private weak var model: IslandModel?
        private weak var audioPlayback: AudioPlaybackMonitor?
        private weak var codexStatus: CodexStatusMonitor?
        private weak var claudeStatus: ClaudeCodeStatusMonitor?
        private weak var deepSeekStatus: DeepSeekHarnessStatusMonitor?
        private var timer: Timer?
        private var collapseWorkItem: DispatchWorkItem?
        private var hasHoveredExpandedPanel = false

        private let autoCollapseDelay: TimeInterval = 0.5

        func startMonitoring(
            view: NSView,
            model: IslandModel,
            audioPlayback: AudioPlaybackMonitor,
            codexStatus: CodexStatusMonitor,
            claudeStatus: ClaudeCodeStatusMonitor,
            deepSeekStatus: DeepSeekHarnessStatusMonitor
        ) {
            self.view = view
            self.model = model
            self.audioPlayback = audioPlayback
            self.codexStatus = codexStatus
            self.claudeStatus = claudeStatus
            self.deepSeekStatus = deepSeekStatus

            stopMonitoring()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.pollMouse()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer


        }

        func stopMonitoring() {
            timer?.invalidate()
            timer = nil
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
        }

        private func pollMouse() {
            if IslandLengthSettings.shared.previewState != nil {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
                return
            }
            guard let model else { return }
            guard let window = view?.window, window.isVisible else { return }

            let mouse = NSEvent.mouseLocation
            // 已进入后扩大退出边界，避免鼠标停在动画边缘时反复触发伸缩。
            let hoverRect = model.isHovered
                ? window.frame.insetBy(dx: -8, dy: -6)
                : window.frame.insetBy(dx: -1, dy: -2)

            // CGRect.contains 不包含最大边界；鼠标顶到屏幕最上方时可能正好等于 maxY。
            // 单独补一条顶部命中带，让最顶端也能稳定触发悬停。
            let topEdgeRect = NSRect(
                x: window.frame.minX - 1,
                y: window.frame.maxY - 2,
                width: window.frame.width + 2,
                height: 5
            )
            let inside = hoverRect.contains(mouse) || topEdgeRect.contains(mouse)

            if inside != model.isHovered {
                model.isHovered = inside
            }
            handleAutoCollapse(inside: inside)
        }

        // 展开状态下：鼠标移出开始倒计时，移回则取消重置
        private func handleAutoCollapse(inside: Bool) {
            guard let model else { return }
            let isAnythingExpanded = model.isExpanded ||
                audioPlayback?.isExpanded == true || codexStatus?.isExpanded == true
            guard isAnythingExpanded else {
                hasHoveredExpandedPanel = false
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
                return
            }
            // 番茄钟设置仍遵循移出后收起；其他时间输入保留编辑时的展开状态。
            if !model.isPomodoroSettingsPresented, view?.window?.firstResponder is NSTextView {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
                return
            }
            // 计时完成和解锁问候由各自的展示逻辑控制收起。
            guard !model.isPersistentAlertVisible, !model.isTimeToolPopoverPresented else {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
                return
            }

            if inside {
                hasHoveredExpandedPanel = true
                // 鼠标移回岛上：取消倒计时（重置）
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
            } else if hasHoveredExpandedPanel && collapseWorkItem == nil {
                // 鼠标移出且还没排定：宽限期结束后收起
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.collapseWorkItem = nil
                    guard IslandLengthSettings.shared.previewState == nil else { return }
                    guard let model = self.model,
                          !model.isPersistentAlertVisible,
                          !model.isTimeToolPopoverPresented,
                          model.isPomodoroSettingsPresented ||
                            !(self.view?.window?.firstResponder is NSTextView) else { return }
                    if model.isPomodoroSettingsPresented {
                        self.view?.window?.makeFirstResponder(nil)
                        model.isPomodoroSettingsPresented = false
                    }
                    model.isExpanded = false
                    self.audioPlayback?.collapseMusicCard()
                    self.codexStatus?.isExpanded = false
                }
                collapseWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + autoCollapseDelay, execute: work)
            }
        }

    }
}
