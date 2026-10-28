import SwiftUI

struct RecordingTimeLabel: View {
    let text: String
    let isPaused: Bool
    var size: CGFloat = 12
    var isCountingDown = false
    var elapsed: (() -> TimeInterval)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: elapsed == nil || isPaused ? 0.5 : 0.01)) { context in
            let visible = !isPaused || Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)
            let currentText = elapsed.map { RecordingClock.text(seconds: $0()) } ?? text
            Text(currentText)
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.45)
                .foregroundStyle(isCountingDown ? Color.yellow : Color.white)
                .opacity(visible ? 1 : 0.15)
                .accessibilityLabel(isCountingDown ? "录制前倒计时 \(currentText) 秒" :
                                    isPaused ? "录屏已暂停，\(currentText)" : "录屏时长 \(currentText)")
        }
    }
}

struct RecordingStatusDot: View {
    var isCountingDown = false
    var isPaused = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let visible = !isCountingDown || Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)
            Circle().fill(Color.red).frame(width: 7, height: 7)
                .opacity(visible ? 1 : 0.15)
                .accessibilityLabel(isCountingDown ? "即将录屏" : isPaused ? "录屏已暂停" : "正在录屏")
        }
    }
}

struct RecordingToolView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var recorder = ScreenRecordingController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var showsSettings: Bool { model.isRecordingSettingsPresented }
    private var settingsAnimation: Animation { .easeInOut(duration: reduceMotion ? 0.1 : 0.3) }

    var body: some View {
        GeometryReader { geometry in
            let settingsWidth = min(max(0, geometry.size.width - 73), 150)
            HStack(alignment: .top, spacing: 0) {
                controls(compact: showsSettings, isNarrow: geometry.size.width < 220)
                    .frame(width: geometry.size.width - (showsSettings ? settingsWidth + 13 : 0),
                           height: geometry.size.height)
                    .padding(.trailing, showsSettings ? 6 : 0)
                if showsSettings {
                    Rectangle().fill(.white.opacity(0.10))
                        .frame(width: 1, height: max(0, geometry.size.height - 8))
                        .accessibilityHidden(true)
                    RecordingOptionsView(settings: recorder.settings, compact: true, isDisabled: recorder.isBusy) {
                        withAnimation(IslandMotion.container) { model.isRecordingSettingsPresented = false }
                    }
                    .frame(width: settingsWidth, height: geometry.size.height)
                    .foregroundStyle(.white)
                    .environment(\.colorScheme, .dark)
                    .padding(.leading, 6)
                    .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(settingsAnimation, value: showsSettings)
            .clipped()
            .overlay(alignment: .topLeading) {
                if recorder.phase == .idle {
                    RecordingStartControl(progress: showsSettings ? 1 : 0,
                                          panelSize: geometry.size, settingsWidth: settingsWidth) {
                        model.isRecordingSettingsPresented = false
                        model.isExpanded = false
                        recorder.start()
                    }
                    .animation(settingsAnimation, value: showsSettings)
                }
            }
        }
        .onDisappear { model.isRecordingSettingsPresented = false }
    }

    private func controls(compact: Bool, isNarrow: Bool) -> some View {
        VStack(spacing: compact ? 8 : 12) {
            Spacer(minLength: 0)
            if recorder.phase == .countdown {
                HStack(spacing: 7) {
                    RecordingStatusDot(isCountingDown: true)
                    RecordingTimeLabel(text: "\(recorder.countdownRemaining)", isPaused: false,
                                       size: compact ? 30 : 44, isCountingDown: true)
                }
                Text("即将开始录制").font(.system(size: 10)).foregroundStyle(.yellow.opacity(0.7))
                Button("取消") { recorder.cancelPreparation() }
                    .buttonStyle(TimeToolActionStyle(color: .red, secondary: true, compact: compact))
            } else if recorder.isCapturing {
                HStack(spacing: 7) {
                    RecordingStatusDot(isPaused: recorder.isPaused)
                    Text(recorder.isPaused ? "已暂停" : "录制中")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
                RecordingTimeLabel(text: recorder.timeText, isPaused: recorder.isPaused,
                                   size: compact ? 20 : 32, elapsed: { recorder.elapsedTime })
                let layout = compact ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    Button {
                        recorder.togglePause()
                    } label: {
                        Label(recorder.isPaused ? "继续" : "暂停", systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TimeToolActionStyle(color: .red, compact: compact))
                    Button { recorder.stop() } label: {
                        Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TimeToolActionStyle(color: .red, secondary: true, compact: compact))
                }
                .disabled(recorder.isTransitioning)
            } else if recorder.phase == .saving {
                ProgressView().controlSize(.small)
                Text("正在保存录屏…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            } else if recorder.phase == .selecting {
                ProgressView().controlSize(.small)
                Text("选择录制目标").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                Button("取消") { recorder.cancelPreparation() }
                    .buttonStyle(TimeToolActionStyle(color: .red, secondary: true, compact: compact))
            } else {
                // The start control is mounted independently above the resizing
                // settings stack, so its button/style never changes at the end.
                Color.clear.frame(height: compact ? 21 : 29)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 0 : (isNarrow ? 10 : 28))
        .contentShape(Rectangle())
        // 始终保留同一个手势，并让设置按钮位于手势区域上层。
        .simultaneousGesture(TapGesture().onEnded {
            guard compact else { return }
            withAnimation(IslandMotion.container) { model.isRecordingSettingsPresented = false }
        })
        .overlay(alignment: .topTrailing) {
            if !compact {
                Button {
                    withAnimation(IslandMotion.container) { model.isRecordingSettingsPresented = true }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 24)
                        .foregroundStyle(.white)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).accessibilityLabel("设置录屏范围、声音与倒计时")
            }
        }
    }
}

/// Explicitly interpolate the whole control in one coordinate space. In
/// particular, don't animate a ButtonStyle change inside a resizing HStack:
/// SwiftUI can replace its rendered contents when that layout settles.
private struct RecordingStartControl: View, Animatable {
    var progress: CGFloat
    let panelSize: CGSize
    let settingsWidth: CGFloat
    let start: () -> Void
    @ObservedObject private var recorder = ScreenRecordingController.shared

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let fraction = min(max(progress, 0), 1)
        let controlsWidth = panelSize.width - (settingsWidth + 13) * fraction
        let inset = (panelSize.width < 220 ? 10.0 : 28.0) * (1 - fraction)
        let fontSize = 12 - 3 * fraction
        Button(action: start) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red)
                .overlay {
                    HStack(spacing: 4) {
                        Image(systemName: "record.circle")
                        HStack(spacing: 0) {
                            Text("开始")
                            Text("录屏")
                                .fixedSize()
                                .frame(width: 24 * (1 - fraction), alignment: .leading)
                                .clipped()
                                .opacity(1 - fraction)
                        }
                        .lineLimit(1)
                    }
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.9))
                    .allowsHitTesting(false)
                }
                .frame(width: max(1, controlsWidth - inset * 2), height: 29 - 8 * fraction)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("开始录屏")
        .help(recorder.lastSavedURL.map { "上次录屏已保存：\($0.path)" } ?? "选择录制目标后开始录屏")
        .position(x: controlsWidth / 2, y: panelSize.height / 2)
        // The Animatable progress above already supplies every intermediate
        // frame; suppress secondary text/style/layout transitions underneath.
        .transaction { $0.animation = nil }
    }
}

struct RecordingOptionsView: View {
    @ObservedObject var settings: RecordingSettings
    var compact = false
    var isDisabled = false
    var close: (() -> Void)?

    private func binding<Value>(_ key: WritableKeyPath<RecordingConfiguration, Value>) -> Binding<Value> {
        Binding(get: { settings.configuration[keyPath: key] }, set: { settings.configuration[keyPath: key] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 16) {
            if compact {
                HStack(spacing: 5) {
                    Text("设置").font(.system(size: 10, weight: .semibold))
                    Text("自动保存").font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
                    Spacer(minLength: 0)
                    Button { close?() } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .background(.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("收起录屏设置")
                }
            }
            if compact {
                options
            } else {
                ScrollView {
                    options
                }
                .scrollIndicators(.hidden)
            }
        }
        .font(.system(size: compact ? 9 : 13, weight: .medium))
        .toggleStyle(.switch)
        .controlSize(compact ? .mini : .regular)
        .padding(.horizontal, compact ? 2 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            Picker("录制范围", selection: binding(\.source)) {
                ForEach(RecordingSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle("系统声音", isOn: binding(\.systemAudio))
            Toggle("麦克风", isOn: binding(\.microphone))
            Picker("倒计时", selection: binding(\.countdown)) {
                Text("关闭").tag(0)
                ForEach([3, 5, 10], id: \.self) { Text("\($0) 秒").tag($0) }
            }
            .pickerStyle(.menu)
            if compact && isDisabled {
                Text("本次录制已开始，结束后可修改。")
                    .font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .disabled(isDisabled)
    }
}

struct RecordingSettingsContent: View {
    @ObservedObject private var settings = RecordingSettings.shared
    @ObservedObject private var recorder = ScreenRecordingController.shared
    var isLightTheme = false
    private var ink: Color { isLightTheme ? .black : .white }
    private var surface: Color { ink.opacity(isLightTheme ? 0.045 : 0.055) }

    private func binding(_ key: WritableKeyPath<RecordingConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { settings.configuration[keyPath: key] }, set: { settings.configuration[keyPath: key] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text("录制选项").font(.system(size: 16, weight: .semibold))
                RecordingOptionsView(settings: settings, isDisabled: recorder.isBusy).frame(height: 150)
                Text("录制范围、声音与倒计时会记住上次选择。")
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
            }
            .padding(24).background(surface, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 16) {
                Text("灵动岛显示").font(.system(size: 16, weight: .semibold))
                Toggle("在录屏视频中显示灵动岛", isOn: binding(\.includesIsland))
                    .disabled(recorder.isBusy)
                Text("适用于全屏和区域录制；窗口录制只包含所选窗口。")
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
                Divider()
                Toggle("持续显示录制状态", isOn: binding(\.showsStatus))
                Toggle("与音乐、AI 任务等内容共存", isOn: binding(\.coexistsWithOtherActivities))
                Text("单侧显示红点与时长，双侧左边红点、右边时长；暂停时数字闪烁。关闭状态展示不会停止录制。")
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
            }
            .padding(24).background(surface, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 14) {
                Text("保存位置").font(.system(size: 16, weight: .semibold))
                HStack(spacing: 16) {
                    Image(systemName: "folder.fill").foregroundStyle(isLightTheme ? .blue : .mint)
                    Text(settings.directory.path).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择文件夹…") { settings.chooseDirectory() }
                        .buttonStyle(.bordered).disabled(recorder.isBusy)
                }
                Text("录制结束自动保存为 MP4，记住上次选择的文件夹。")
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
            }
            .padding(24).background(surface, in: RoundedRectangle(cornerRadius: 18))
        }
        .font(.system(size: 13))
        .foregroundStyle(ink).toggleStyle(.switch)
        .alert("保存位置设置失败", isPresented: Binding(get: { settings.errorMessage != nil },
                                                  set: { if !$0 { settings.errorMessage = nil } })) {
            Button("知道了") { settings.errorMessage = nil }
        } message: { Text(settings.errorMessage ?? "") }
    }
}
