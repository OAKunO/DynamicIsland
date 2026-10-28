import SwiftUI

enum IslandSettingsPage {
    case home, length, content, functions, recording
}

struct IslandSettingsView: View {
    @ObservedObject var lengthSettings: IslandLengthSettings
    @ObservedObject var displaySettings: IslandDisplaySettings
    @AppStorage("island.settings.lightTheme") private var isLightTheme = false
    @State private var page: IslandSettingsPage

    init(lengthSettings: IslandLengthSettings, displaySettings: IslandDisplaySettings = .shared,
         initialPage: IslandSettingsPage = .home) {
        self.lengthSettings = lengthSettings
        self.displaySettings = displaySettings
        _page = State(initialValue: initialPage)
    }

    private var ink: Color { isLightTheme ? .black : .white }
    private var surface: Color { ink.opacity(isLightTheme ? 0.045 : 0.055) }
    private var accent: Color { isLightTheme ? .blue : .mint }

    var body: some View {
        Group {
            switch page {
            case .length:
                IslandLengthSettingsView(lengthSettings: lengthSettings) { navigate(to: .home) }
            case .home, .content, .functions, .recording:
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 28).padding(.vertical, 22)
                    Divider()
                    ScrollView {
                        Group {
                            if page == .home { homeContent }
                            else if page == .content { displayContent }
                            else if page == .recording { RecordingSettingsContent(isLightTheme: isLightTheme) }
                            else { functionContent }
                        }
                        .frame(maxWidth: 840)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isLightTheme ? Color.white : Color.black)
                .environment(\.colorScheme, isLightTheme ? .light : .dark)
                .background(SettingsWindowAppearance(isLightTheme: isLightTheme))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if page != .home {
                Button { navigate(to: .home) } label: {
                    Label("设置", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回设置首页")
            }
            Image(systemName: page == .home ? "gearshape.fill" : page == .recording ? "record.circle" : page == .functions ? "switch.2" : "eye")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(page == .home ? "灵动岛设置" : page == .recording ? "录屏设置" : page == .functions ? "功能开关" : "展示内容")
                    .font(.system(size: 22, weight: .semibold))
                Text(page == .home ? "管理灵动岛的外观、展示内容与功能" : page == .recording ? "管理录制选项、灵动岛显示和保存位置" : page == .functions ? "选择要启用的灵动岛功能" : "选择哪些功能出现在灵动岛中")
                    .font(.system(size: 12)).foregroundStyle(ink.opacity(0.5))
            }
            Spacer()
            IslandSettingsThemeToggle(isLightTheme: $isLightTheme)
        }
        .foregroundStyle(ink)
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("让灵动岛适合你的习惯")
                    .font(.system(size: 27, weight: .semibold))
                Text("选择要关注的内容、调整显示长度，并管理自动功能。")
                    .font(.system(size: 13)).foregroundStyle(ink.opacity(0.55))
            }
            .padding(.top, 10).padding(.bottom, 8)
            destinationCard(title: "灵动岛长度", detail: "为不同功能与状态单独调整长度，实时预览效果。",
                            symbol: "arrow.left.and.right", color: accent, page: .length, summary: "独立长度 · 实时预览")
            destinationCard(title: "展示内容", detail: "选择 AI Agent、音乐、时间工具和设备状态的显示内容。",
                            symbol: "eye", color: .blue, page: .content,
                            summary: "已开启 \(displaySettings.enabledDisplayCount) / \(IslandDisplayFeature.displayFeatures.count) 项")
            destinationCard(title: "功能开关", detail: "管理解锁问候等自动功能，按你的习惯选择开启或关闭。",
                            symbol: "switch.2", color: .orange, page: .functions,
                            summary: "已开启 \(displaySettings.enabledFunctionCount) / \(IslandDisplayFeature.functionFeatures.count) 项")
            destinationCard(title: "录屏设置", detail: "设置录制范围、声音、倒计时、状态显示与保存位置。",
                            symbol: "record.circle", color: .red, page: .recording, summary: "全屏 · 窗口 · 区域")
        }
        .foregroundStyle(ink)
    }

    private func destinationCard(title: String, detail: String, symbol: String, color: Color,
                                 page: IslandSettingsPage, summary: String) -> some View {
        Button { navigate(to: page) } label: {
            HStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 25, weight: .medium)).foregroundStyle(color)
                    .frame(width: 64, height: 64)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 19, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(ink.opacity(0.55))
                    Text(summary).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ink.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(ink.opacity(0.09), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已开启 \(displaySettings.enabledDisplayCount) 项展示内容")
                        .font(.system(size: 16, weight: .semibold))
                    Text("更改立即生效，并自动保存。关闭展示不会停止任务、播放或计时。")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("时间工具的到时提醒仍会正常显示。")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.55))
                }
                Spacer(minLength: 12)
                Button("全部开启") { displaySettings.enableAllDisplayFeatures() }
                    .buttonStyle(.bordered)
                    .disabled(displaySettings.enabledDisplayCount == IslandDisplayFeature.displayFeatures.count)
            }
            HStack(alignment: .top, spacing: 16) {
                featureGroup("AI Agent", features: [.codex, .deepSeek, .claude])
                featureGroup("时间工具", features: [.timer, .pomodoro, .alarm])
            }
            HStack(alignment: .top, spacing: 16) {
                featureGroup("音乐与音频", features: [.music])
                featureGroup("录屏", features: [.recording])
            }
            featureGroup("系统与设备", features: [.battery, .usb, .computer])
        }
        .foregroundStyle(ink)
    }

    private var functionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("按需开启自动功能")
                    .font(.system(size: 16, weight: .semibold))
                Text("更改立即生效，并自动保存。关闭解锁问候后，解锁屏幕时不再自动弹出问候卡片。")
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            featureGroup("问候", features: IslandDisplayFeature.functionFeatures, isFunction: true)
        }
        .foregroundStyle(ink)
    }

    private func featureGroup(_ title: String, features: [IslandDisplayFeature], isFunction: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink.opacity(0.5)).padding(.bottom, 12)
            ForEach(features) { feature in
                if feature != features.first { Divider().padding(.vertical, 12) }
                HStack(spacing: 11) {
                    featureIcon(feature)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(feature.title).font(.system(size: 13, weight: .medium))
                        Text(feature.detail).font(.system(size: 10))
                            .foregroundStyle(ink.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(feature.title, isOn: Binding(
                        get: { displaySettings.snapshot.isEnabled(feature) },
                        set: { displaySettings.setEnabled($0, for: feature) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(accent)
                    .accessibilityLabel("\(isFunction ? "启用" : "展示")\(feature.title)")
                    .accessibilityIdentifier("\(isFunction ? "function" : "display")-\(feature.rawValue)")
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ink.opacity(0.09), lineWidth: 1) }
    }

    @ViewBuilder
    private func featureIcon(_ feature: IslandDisplayFeature) -> some View {
        switch feature {
        case .codex:
            Image("CodexStatusIcon").resizable().renderingMode(.template).scaledToFit().padding(4)
        case .deepSeek:
            Image("DeepSeekStatusIcon").resizable().scaledToFit().padding(4)
        case .pomodoro:
            TomatoClockIcon(color: ink).frame(width: 20, height: 20)
        default:
            Image(systemName: feature.symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(feature == .claude ? .orange : accent)
        }
    }

    private func navigate(to nextPage: IslandSettingsPage) {
        lengthSettings.endPreview()
        page = nextPage
    }
}
