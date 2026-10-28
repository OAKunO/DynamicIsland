import SwiftUI

/// The right half of the time card; its controls never resize the island.
struct PomodoroSettingsView: View {
    @ObservedObject var model: IslandModel
    @State var showsSeconds = false

    private func binding<Value>(_ key: WritableKeyPath<PomodoroConfiguration, Value>) -> Binding<Value> {
        Binding(get: { model.pomodoroConfiguration[keyPath: key] }, set: { value in
            var configuration = model.pomodoroConfiguration
            configuration[keyPath: key] = value
            model.updatePomodoroConfiguration(configuration)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("设置").font(.system(size: 10, weight: .semibold))
                Text(model.canEditPomodoroConfiguration ? "自动保存" : "需重置")
                    .font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
                    .help(model.canEditPomodoroConfiguration ? "设置会自动保存" : "本组已开始，重置后可修改参数")
                Spacer(minLength: 0)
                Button {
                    WindowManager.window?.makeFirstResponder(nil)
                    withAnimation(IslandMotion.control) { showsSeconds.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text("秒")
                        Image(systemName: showsSeconds ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(showsSeconds ? Color.orange : .white.opacity(0.5))
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsSeconds ? "收起秒钟设置" : "展开秒钟设置")
                Button {
                    WindowManager.window?.makeFirstResponder(nil)
                    withAnimation(IslandMotion.container) { model.isPomodoroSettingsPresented = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("收起番茄钟设置")
            }
            ScrollView {
                VStack(spacing: 4) {
                    durationRow("专注", minutes: binding(\.focusMinutes), seconds: binding(\.focusSeconds), maximumMinutes: 180)
                    durationRow("短休", minutes: binding(\.shortBreakMinutes), seconds: binding(\.shortBreakSeconds), maximumMinutes: 60)
                    durationRow("长休", minutes: binding(\.longBreakMinutes), seconds: binding(\.longBreakSeconds), maximumMinutes: 120)
                    HStack(spacing: 3) {
                        Text("长休间隔").foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 0)
                        numberEditor("长休息间隔", value: binding(\.longBreakInterval), range: 1...12)
                        Text("轮").foregroundStyle(.white.opacity(0.35))
                    }
                    Divider().overlay(.white.opacity(0.04)).padding(.vertical, 1)
                    HStack(spacing: 3) {
                        Toggle("无限循环", isOn: binding(\.isUnlimited)).fixedSize()
                        Spacer(minLength: 0)
                        if !model.pomodoroConfiguration.isUnlimited {
                            numberEditor("本组专注轮数", value: binding(\.rounds), range: 1...99)
                            Text("轮").foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    HStack {
                        Toggle("自动切换", isOn: binding(\.autoAdvance)).fixedSize()
                        Spacer(minLength: 0)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 9, weight: .medium))
            .disabled(!model.canEditPomodoroConfiguration)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .preferredColorScheme(.dark)
    }

    private func durationRow(_ title: String, minutes: Binding<Int>, seconds: Binding<Int>, maximumMinutes: Int) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
            numberEditor("\(title)分钟", value: minutes,
                         range: (seconds.wrappedValue > 0 ? 0 : 1)...maximumMinutes)
            Text("分").foregroundStyle(.white.opacity(0.35))
            if showsSeconds {
                numberEditor("\(title)秒钟", value: seconds, range: 0...59)
                Text("秒").foregroundStyle(.white.opacity(0.35))
            } else if seconds.wrappedValue > 0 {
                Text("\(seconds.wrappedValue)秒").foregroundStyle(.orange.opacity(0.7))
                    .monospacedDigit().contentTransition(.numericText())
            }
        }
        .frame(height: 19)
    }

    private func numberEditor(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 2) {
            AnimatedNumberField(title, value: value, range: range,
                                digitSize: 10, fieldWidth: 24, fieldHeight: 18,
                                weight: .semibold, cornerRadius: 4,
                                backgroundOpacity: 0.08, focusColor: .orange)
            Stepper(title, value: value, in: range).labelsHidden()
                .fixedSize()
                .accessibilityLabel("调整\(title)")
        }
    }
}

struct TimeToolActionStyle: ButtonStyle {
    var color: Color
    var secondary = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 9 : 12, weight: .semibold))
            .foregroundStyle(secondary ? .white.opacity(0.8) : Color.black.opacity(0.9))
            .padding(.vertical, compact ? 5 : 7)
            .padding(.horizontal, compact ? 6 : 12)
            .background(secondary ? Color.white.opacity(0.09) : color, in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
