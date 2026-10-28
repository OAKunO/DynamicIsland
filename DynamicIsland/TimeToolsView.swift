import SwiftUI
import AppKit

struct CardView: View {
    @ObservedObject var model: IslandModel
    var embedded = false
    var displaySnapshot = IslandDisplaySettingsSnapshot()

    private var visibleTimeTools: [IslandTimeTool] {
        IslandTimeTool.allCases.filter { tool in
            switch tool {
            case .timer: displaySnapshot.isEnabled(.timer)
            case .pomodoro: displaySnapshot.isEnabled(.pomodoro)
            case .alarm: displaySnapshot.isEnabled(.alarm)
            }
        }
    }
    private var displayedTimeTool: IslandTimeTool? {
        visibleTimeTools.contains(model.selectedTimeTool) ? model.selectedTimeTool : visibleTimeTools.first
    }

    private enum ContentMode: Equatable {
        case setup
        case running
        case finished
        case greeting(id: UUID)
    }

    private var contentMode: ContentMode {
        if model.isTimerFinished { return .finished }
        if let greeting = model.activeUnlockGreeting { return .greeting(id: greeting.id) }
        if model.isTimerRunning { return .running }
        return .setup
    }

    var body: some View {
        ZStack {
            if model.isTimerFinished {
                finishedContent
                    .transition(.islandContent)
            } else if let greeting = model.activeUnlockGreeting {
                VStack(spacing: 12) {
                    UnlockGreetingView(greeting: greeting) {
                        model.dismissUnlockGreeting()
                    }
                    if model.isSessionUnlocked && displaySnapshot.isEnabled(.notes) {
                        UnlockNotesSummary(store: model.notes, model: model)
                    }
                }
                .transition(.islandContent)
            } else if let displayedTimeTool {
                VStack(spacing: 10) {
                    timeToolTabs
                        .frame(height: 34)
                    Group {
                        switch displayedTimeTool {
                        case .timer:
                            if model.isTimerRunning { runningContent } else { timerSetup }
                        case .pomodoro: pomodoroContent
                        case .alarm:
                            TimelineView(.periodic(from: .now, by: 1)) { _ in alarmContent }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash").font(.system(size: 24)).foregroundStyle(.white.opacity(0.45))
                    Text("时间工具已隐藏").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    Button("选择展示内容") { IslandSettingsWindow.show(page: .content) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, embedded ? 30 : 16)
        .padding(.bottom, embedded ? 2 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(IslandMotion.content, value: contentMode)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .onDisappear { model.dismissAlarmEditor() }
    }

    private var finishedContent: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(model.completionTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Text(model.completionMessage)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.58))
            Button {
                model.dismissTimerFinishedAlert()
            } label: {
                Text("知道了")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            Spacer(minLength: 0)
        }
    }

    private var timeToolTabs: some View {
        HStack(spacing: 4) {
            ForEach(visibleTimeTools) { tool in
                Button {
                    model.dismissAlarmEditor()
                    withAnimation(IslandMotion.control) { model.selectedTimeTool = tool }
                } label: {
                    HStack(spacing: 6) {
                        Label { Text(tool.title) } icon: {
                            TimeToolIcon(tool: tool, size: 13)
                                .opacity(tool == .pomodoro && displayedTimeTool != tool ? 0.45 : 1)
                        }
                        if model.isActive(tool) {
                            Circle().fill(Color.mint).frame(width: 4, height: 4)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(displayedTimeTool == tool ? Color.white.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(displayedTimeTool == tool ? .white : .white.opacity(0.45))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(displayedTimeTool == tool ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pomodoroContent: some View {
        GeometryReader { geometry in
            let settingsWidth = min(geometry.size.width * 0.47, 150)
            let isSplit = model.isPomodoroSettingsPresented
            HStack(alignment: .top, spacing: 0) {
                pomodoroPreview(compact: isSplit)
                    .frame(width: geometry.size.width - (isSplit ? settingsWidth + 13 : 0),
                           height: geometry.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        guard isSplit else { return }
                        WindowManager.window?.makeFirstResponder(nil)
                        withAnimation(IslandMotion.container) {
                            model.isPomodoroSettingsPresented = false
                        }
                    }, including: isSplit ? .all : .none)
                    .padding(.trailing, isSplit ? 6 : 0)
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(width: isSplit ? 1 : 0, height: max(0, geometry.size.height - 8))
                    .opacity(isSplit ? 1 : 0)
                    .accessibilityHidden(true)
                PomodoroSettingsView(model: model)
                    .frame(width: settingsWidth, height: geometry.size.height)
                    .frame(width: isSplit ? settingsWidth : 0, alignment: .leading)
                    .clipped()
                    .opacity(isSplit ? 1 : 0)
                    .padding(.leading, isSplit ? 6 : 0)
                    .allowsHitTesting(isSplit)
                    .disabled(!isSplit)
                    .accessibilityHidden(!isSplit)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(IslandMotion.container, value: isSplit)
            .clipped()
        }
    }

    private func pomodoroPreview(compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 6) {
            HStack {
                Label { Text(model.pomodoro.isComplete ? "本组完成" : model.pomodoro.phase.title) } icon: {
                    TimeToolIcon(tool: .pomodoro, size: compact ? 12 : 16)
                }
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .font(.system(size: compact ? 10 : 12, weight: .medium))
                Spacer()
                if !compact {
                    Text(model.pomodoroConfiguration.isUnlimited
                         ? "\(model.pomodoro.completedFocusCount) 轮 · ∞"
                         : "\(model.pomodoro.completedFocusCount) / \(model.pomodoroConfiguration.rounds) 轮")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        .contentTransition(.numericText())
                        .animation(IslandMotion.control, value: model.pomodoro.completedFocusCount)
                        .animation(IslandMotion.control, value: model.pomodoroConfiguration.rounds)
                    Button {
                        withAnimation(IslandMotion.container) { model.isPomodoroSettingsPresented.toggle() }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 26, height: 24)
                            .foregroundStyle(model.isPomodoroSettingsPresented ? Color.orange : .white)
                            .background(.white.opacity(model.isPomodoroSettingsPresented ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain).accessibilityLabel("设置番茄钟时长与循环")
                }
            }
            if compact {
                Text(model.pomodoroConfiguration.isUnlimited
                     ? "\(model.pomodoro.completedFocusCount) 轮 · ∞"
                     : "\(model.pomodoro.completedFocusCount) / \(model.pomodoroConfiguration.rounds) 轮")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    .monospacedDigit().contentTransition(.numericText())
            }
            Text(String(format: "%02d:%02d", model.pomodoro.remaining / 60, model.pomodoro.remaining % 60))
                .font(.system(size: compact ? 23 : 34, weight: .medium, design: .rounded))
                .tracking(-0.8).monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(IslandMotion.control, value: model.pomodoro.remaining)
                .frame(maxWidth: .infinity)
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.orange.opacity(0.9))
                            .frame(width: geometry.size.width * (model.pomodoro.isComplete ? 1 : model.pomodoro.progress))
                    }
            }
            .frame(height: 3)
            .accessibilityElement()
            .accessibilityLabel("阶段进度")
            .accessibilityValue("\(Int(model.pomodoro.progress * 100))%")
            let durationLayout = compact ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 6))
            durationLayout {
                durationBadge("专注", duration: model.pomodoroConfiguration.duration(for: .focus), color: .orange, compact: compact)
                durationBadge("短休", duration: model.pomodoroConfiguration.duration(for: .shortBreak), color: .mint, compact: compact)
                durationBadge("长休", duration: model.pomodoroConfiguration.duration(for: .longBreak), color: .blue, compact: compact)
            }
            HStack(spacing: compact ? 4 : 8) {
                Button {
                    if model.pomodoro.isComplete { model.resetPomodoro(); model.startPomodoro() }
                    else if model.pomodoro.isRunning { model.togglePomodoroPause() }
                    else { model.startPomodoro() }
                } label: {
                    Label(model.pomodoro.isComplete ? "再来一组" : (model.pomodoro.isRunning ? (model.pomodoro.isPaused ? "继续" : "暂停") : (compact ? "开始" : "开始\(model.pomodoro.phase.title)")),
                          systemImage: model.pomodoro.isRunning && !model.pomodoro.isPaused ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TimeToolActionStyle(color: .orange, compact: compact))
                Button("重置") { model.resetPomodoro() }
                    .buttonStyle(TimeToolActionStyle(color: .orange, secondary: true, compact: compact))
            }
            Text(compact
                 ? "每 \(model.pomodoroConfiguration.longBreakInterval) 轮长休息\n\(model.pomodoroConfiguration.autoAdvance ? "自动切换" : "手动切换")"
                 : "每 \(model.pomodoroConfiguration.longBreakInterval) 轮长休息 · \(model.pomodoroConfiguration.autoAdvance ? "自动切换阶段" : "手动开始下一阶段")")
                .font(.system(size: compact ? 8 : 10, weight: .regular))
                .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.45))
                .contentTransition(.numericText(value: Double(model.pomodoroConfiguration.longBreakInterval)))
                .animation(IslandMotion.control, value: model.pomodoroConfiguration.longBreakInterval)
        }
    }

    private func durationBadge(_ title: String, duration: Int, color: Color, compact: Bool = false) -> some View {
        let durationText = duration % 60 == 0 ? "\(duration / 60) 分" : "\(duration / 60)分\(duration % 60)秒"
        return Button {
            if compact { WindowManager.window?.makeFirstResponder(nil) }
            withAnimation(IslandMotion.container) { model.isPomodoroSettingsPresented = !compact }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color.opacity(0.85)).frame(width: 4, height: 4)
                Text(title).foregroundStyle(.white.opacity(0.55))
                Text(durationText).foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.numericText(value: Double(duration)))
                    .animation(IslandMotion.control, value: duration)
            }
            .font(.system(size: compact ? 8 : 10, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 2 : 5)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(durationText)，点击设置")
    }

    private func alarmComponent(_ component: Calendar.Component) -> Binding<Int> {
        Binding(get: { Calendar.current.component(component, from: model.alarmTime) }, set: { value in
            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: model.alarmTime)
            if component == .hour { components.hour = value } else { components.minute = value }
            if let date = Calendar.current.date(from: components) { model.alarmTime = date }
        })
    }

    private var alarmContent: some View {
        Group {
            if model.isAlarmEditorPresented {
                alarmEditor
            } else {
                alarmList
            }
        }
    }

    private var alarmList: some View {
        VStack(spacing: 8) {
            // Keep the scroll container alive so the last row can finish its exit.
            ZStack {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.alarms) { alarm in
                            alarmRow(alarm)
                                .transition(.alarmRowRemoval)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                if model.alarms.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "alarm").font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("还没有闹钟").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            Button { model.beginAddingAlarm() } label: {
                Label("新增闹钟", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(TimeToolActionStyle(color: .blue))
            .padding(.bottom, embedded ? 11.5 : 0)
        }
    }

    private func alarmRow(_ alarm: CustomAlarm) -> some View {
        HStack(spacing: 10) {
            Button { model.beginEditingAlarm(alarm.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(alarm.date, format: .dateTime.hour().minute())
                        .font(.system(size: 23, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(alarm.isEnabled ? 1 : 0.45))
                    Text(alarm.date, format: .dateTime.month().day().weekday())
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("修改闹钟，\(alarm.date.formatted(date: .abbreviated, time: .shortened))")
            Toggle("启用闹钟", isOn: Binding(
                get: { model.alarms.first(where: { $0.id == alarm.id })?.isEnabled ?? alarm.isEnabled },
                set: { model.setAlarmEnabled(alarm.id, $0) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.blue)
            .accessibilityLabel("启用闹钟，\(alarm.date.formatted(date: .abbreviated, time: .shortened))")
            .help("启用已过期的闹钟时，将安排在下一次相同时间响铃")
            Button {
                withAnimation(IslandMotion.alarmDeletion) {
                    model.deleteAlarm(alarm.id)
                }
            } label: {
                Image(systemName: "trash").font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 26, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("删除闹钟").accessibilityLabel("删除闹钟")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .allowsHitTesting(model.alarms.contains { $0.id == alarm.id })
    }

    private var alarmEditor: some View {
        VStack(spacing: 5) {
            HStack {
                Button { model.dismissAlarmEditor() } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text(model.editingAlarmID == nil ? "新增闹钟" : "修改闹钟")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 11, weight: .medium))
            Button { model.isTimeToolPopoverPresented = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar").foregroundStyle(Color.blue.opacity(0.9))
                    Text(model.alarmTime, format: .dateTime.year().month().day().weekday())
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).accessibilityLabel("选择响铃日期")
            .popover(isPresented: $model.isTimeToolPopoverPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("选择响铃日期").font(.system(size: 15, weight: .semibold))
                    DatePicker("日期", selection: $model.alarmTime,
                               in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden()
                    Button("完成") { model.isTimeToolPopoverPresented = false }
                        .buttonStyle(TimeToolActionStyle(color: .blue))
                }
                .padding(16).frame(width: 300)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .preferredColorScheme(.dark)
            }
            HStack(spacing: 12) {
                TimeUnitEditor(value: alarmComponent(.hour), range: 0...23, title: "时", digitSize: 32, fieldWidth: 52)
                Text(":").font(.system(size: 30, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35)).padding(.top, -16)
                TimeUnitEditor(value: alarmComponent(.minute), range: 0...59, title: "分", digitSize: 32, fieldWidth: 52)
            }
            Button { model.scheduleAlarm() } label: {
                Label(model.editingAlarmID == nil ? "添加闹钟" : "保存闹钟", systemImage: "bell.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(TimeToolActionStyle(color: .blue))
            .disabled(!model.canScheduleAlarm)
            .opacity(model.canScheduleAlarm ? 1 : 0.4)
            Text(model.canScheduleAlarm ? "选择日期与时间，到点自动响铃" : "这个时间已过，请选择未来的日期或时间")
                .font(.system(size: 10)).foregroundStyle(model.canScheduleAlarm ? .white.opacity(0.45) : .orange)
                .multilineTextAlignment(.center)
        }
    }

    private var timerSetup: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.mint)
                Text("设置倒计时")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(model.configuredTimeText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .contentTransition(.numericText(value: Double(model.totalSeconds)))
                    .animation(IslandMotion.control, value: model.totalSeconds)
            }

            HStack(spacing: 8) {
                ForEach([1, 5, 15, 25], id: \.self) { minutes in
                    Button("\(minutes) 分") {
                        model.applyPreset(minutes: minutes)
                    }
                    .buttonStyle(PresetButtonStyle(isSelected: model.totalSeconds == minutes * 60))
                }
            }

            HStack(spacing: 5) {
                TimeUnitEditor(
                    value: Binding(
                        get: { model.timerHours },
                        set: {
                            model.setTimer(
                                hours: $0,
                                minutes: model.timerMinutes,
                                seconds: model.timerSeconds
                            )
                        }
                    ),
                    range: 0...99,
                    title: "小时"
                )

                timeSeparator

                TimeUnitEditor(
                    value: Binding(
                        get: { model.timerMinutes },
                        set: {
                            model.setTimer(
                                hours: model.timerHours,
                                minutes: $0,
                                seconds: model.timerSeconds
                            )
                        }
                    ),
                    range: 0...59,
                    title: "分钟"
                )

                timeSeparator

                TimeUnitEditor(
                    value: Binding(
                        get: { model.timerSeconds },
                        set: {
                            model.setTimer(
                                hours: model.timerHours,
                                minutes: model.timerMinutes,
                                seconds: $0
                            )
                        }
                    ),
                    range: 0...59,
                    title: "秒"
                )
            }

            Button {
                model.startTimer()
            } label: {
                Label("开始计时", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TimeToolActionStyle(color: .blue))
            .disabled(!model.canStartTimer)
            .opacity(model.canStartTimer ? 1 : 0.45)

            Text("将在 \(model.scheduledEndTimeText) 结束计时")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))
                .contentTransition(.numericText())
                .animation(IslandMotion.content, value: model.totalSeconds)
        }
    }

    private var timeSeparator: some View {
        Text(":")
            .font(.system(size: 24, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.42))
            .padding(.top, -17)
    }

    private var runningContent: some View {
        VStack(spacing: 10) {
            HStack {
                Label(model.timerStatusText, systemImage: model.isTimerPaused ? "pause.circle.fill" : "timer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.isTimerPaused ? Color.yellow : Color.mint)
                Spacer()
                Button {
                    model.addTime(by: -60)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("减 1 分钟")
                .tint(Color.white.opacity(0.82))
                Button {
                    model.addTime(by: 60)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("加 1 分钟")
                .tint(Color.white.opacity(0.82))
            }

            Text(model.timeRemainingText)
                .font(.system(size: 36, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText(countsDown: true))
                .animation(IslandMotion.control, value: model.timeRemaining)

            HStack(spacing: 10) {
                Button {
                    model.togglePause()
                } label: {
                    Label(model.isTimerPaused ? "继续" : "暂停", systemImage: model.isTimerPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isTimerPaused ? .mint : .gray)

                Button(role: .destructive) {
                    model.cancelTimer()
                } label: {
                    Label("结束", systemImage: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct UnlockGreetingView: View {
    let greeting: UnlockGreeting
    let dismiss: () -> Void

    @State private var appeared = false

    private var accent: Color {
        switch greeting.period {
        case .morning: .orange
        case .noon: .yellow
        case .afternoon: .cyan
        case .evening: .indigo
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 17) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.16))
                    Circle()
                        .stroke(accent.opacity(0.34), lineWidth: 1)
                    Image(systemName: greeting.period.symbolName)
                        .font(.system(size: 25, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(accent)
                        .rotationEffect(.degrees(appeared ? 0 : -12))
                }
                .frame(width: 58, height: 58)
                .scaleEffect(appeared ? 1 : 0.72)

                VStack(alignment: .leading, spacing: 7) {
                    Text(greeting.period.salutation)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(greeting.message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(2)

                    Text(Self.dateFormatter.string(from: greeting.date))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.76))
                }
                .offset(x: appeared ? 0 : 14)
                .opacity(appeared ? 1 : 0)
            }
            .padding(.bottom, 25)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .frame(width: 25, height: 25)
                    .background(Color.white.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .scaleEffect(appeared ? 1 : 0.72)
            .opacity(appeared ? 1 : 0)
        }
        .background(Color.black)
        .onAppear {
            withAnimation(IslandMotion.content.delay(0.08)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(greeting.period.salutation)，\(greeting.message)")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 · EEEE"
        return formatter
    }()
}

private struct TimeUnitEditor: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let title: String
    var digitSize: CGFloat = 23
    var fieldWidth: CGFloat = 36
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                adjustmentButton(symbol: "minus") {
                    value = value == range.lowerBound ? range.upperBound : value - 1
                }

                AnimatedNumberField(title, value: $value, range: range,
                                    digitSize: digitSize, fieldWidth: fieldWidth,
                                    fieldHeight: max(30, digitSize + 7))

                adjustmentButton(symbol: "plus") {
                    value = value == range.upperBound ? range.lowerBound : value + 1
                }
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.52))
        }
    }

    private func adjustmentButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(width: 18, height: 26)
                .background(
                    Color.white.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                // 把整个方块作为命中区域，而不只是中间的 SF Symbol。
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PresetButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.82))
            .frame(maxWidth: .infinity)
            .frame(height: 27)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .background(isSelected ? Color.mint : Color.white.opacity(configuration.isPressed ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(IslandMotion.control, value: configuration.isPressed)
            .animation(IslandMotion.content, value: isSelected)
    }
}
