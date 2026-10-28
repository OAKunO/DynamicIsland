import SwiftUI

struct IslandLengthSettingsView: View {
    @ObservedObject var lengthSettings: IslandLengthSettings
    @AppStorage("island.settings.lightTheme") private var isLightTheme = false
    @State private var query = IslandLengthCatalogQuery()
    @State private var pageIndex = 0
    @State private var catalogPage = IslandLengthCatalogPage(states: [], total: 0)
    @State private var isLoading = false
    private let pageSize = 40
    var onBack: (() -> Void)? = nil

    private var ink: Color { isLightTheme ? .black : .white }
    private var surface: Color { ink.opacity(isLightTheme ? 0.045 : 0.055) }
    private var accent: Color { isLightTheme ? .blue : .mint }
    private var request: CatalogRequest {
        CatalogRequest(query: query, page: pageIndex,
                       revision: query.modifiedOnly ? lengthSettings.revision : 0,
                       geometryRevision: lengthSettings.geometryRevision)
    }

    init(lengthSettings: IslandLengthSettings, initialQuery: IslandLengthCatalogQuery? = nil, onBack: (() -> Void)? = nil) {
        self.lengthSettings = lengthSettings
        self.onBack = onBack
        let configuration = lengthSettings.currentState.configuration
        var initial = initialQuery ?? IslandLengthCatalogQuery()
        if initialQuery == nil {
            initial.category = configuration.category
            initial.combination = IslandAgentCombination.matching(configuration.orderedAgents.map(\.provider)) ?? .codex
            initial.music = configuration.music
            initial.timer = configuration.timer
            initial.battery = configuration.battery
            initial.usb = configuration.usb
            initial.phone = configuration.phone
            initial.computer = configuration.computer
        }
        _query = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 16)
            currentStateCard
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                catalog
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isLightTheme ? Color.white : Color.black)
        .environment(\.colorScheme, isLightTheme ? .light : .dark)
        .background(SettingsWindowAppearance(isLightTheme: isLightTheme))
        .onChange(of: query) { _, _ in pageIndex = 0 }
        .task(id: request) {
            await loadCatalog(request)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Label("设置", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回设置首页")
            }
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("灵动岛长度").font(.system(size: 21, weight: .semibold))
                Text("每种状态，独立长度")
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
            }
            Spacer()
            IslandSettingsThemeToggle(isLightTheme: $isLightTheme)
        }
        .foregroundStyle(ink)
    }

    private var currentStateCard: some View {
        let state = lengthSettings.displayedState
        return HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(lengthSettings.previewState == nil ? "自动检测 · 当前状态" : "预览中 · 示例状态")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    Text(state.configuration.mode.isExpanded ? "展开" : "收起")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(ink.opacity(0.08), in: Capsule())
                }
                Text(state.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(state.title)
                if state.configuration.mode.isExpanded {
                    Text(state.configuration.activityTitle)
                        .font(.system(size: 10)).foregroundStyle(ink.opacity(0.5)).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Text("默认 \(lengthSettings.defaultWidth(for: state)) pt")
                    Text(lengthSettings.isModified(state) ? "已自定义" : "使用默认长度")
                    Button("在列表中定位", action: locateCurrentState)
                        .buttonStyle(.plain).foregroundStyle(accent)
                }
                .font(.system(size: 10)).foregroundStyle(ink.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 10) {
                    IslandLengthEditor(settings: lengthSettings, state: state, large: true)
                    previewButton(for: state)
                }
                HStack(spacing: 10) {
                    Text("回车保存 · Esc 取消")
                        .font(.system(size: 10)).foregroundStyle(ink.opacity(0.5))
                    Button("恢复默认") { lengthSettings.resetWidth(for: state) }
                        .buttonStyle(.plain).font(.system(size: 10))
                        .foregroundStyle(accent).disabled(!lengthSettings.isModified(state))
                }
            }
        }
        .foregroundStyle(ink)
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 1)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("状态分类")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ink.opacity(0.42)).padding(.horizontal, 10).padding(.bottom, 7)
            ForEach(IslandLengthCategory.allCases) { category in
                Button {
                    query.category = category
                    query.focusedConfiguration = nil
                    query.search = ""
                    if category == .timer && query.timer == .off { query.timer = .runningMinutes }
                    if category == .devices || category == .expanded { query.timer = .off }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: category.symbol).frame(width: 17)
                        Text(category.title)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: query.category == category ? .semibold : .regular))
                    .foregroundStyle(query.category == category ? accent : ink.opacity(0.65))
                    .padding(.horizontal, 10).padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(query.category == category ? accent.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("×1：一个任务\n×2+：两个及以上任务\n\n目录包含尚未触发的状态。")
                .font(.system(size: 10)).foregroundStyle(ink.opacity(0.4)).lineSpacing(4)
                .padding(.horizontal, 10)
        }
        .padding(12).frame(width: 166)
        .background(surface)
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("长度设置 / \(query.category.title)")
                        .font(.system(size: 10)).foregroundStyle(ink.opacity(0.4))
                    Text(query.category.title).font(.system(size: 18, weight: .semibold))
                }
                Spacer()
                Picker("显示状态", selection: $query.modifiedOnly) {
                    Text("全部").tag(false)
                    Text("已修改").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 134)
            }
            if query.focusedConfiguration != nil {
                HStack {
                    Label(lengthSettings.previewState == nil ? "已定位当前精确组合" : "已定位预览精确组合", systemImage: "scope")
                    Spacer()
                    Button("显示全部组合") { query.focusedConfiguration = nil }
                        .buttonStyle(.plain).foregroundStyle(accent)
                }
                .font(.system(size: 11)).padding(10)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            } else {
                filters
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(ink.opacity(0.4))
                TextField("搜索当前分类中的完整状态名称", text: $query.search)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !query.search.isEmpty {
                    Button { query.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(ink.opacity(0.4))
                }
            }
            .padding(9).background(surface, in: RoundedRectangle(cornerRadius: 7))
            tableHeader
            Divider()
            ScrollView {
                if catalogPage.states.isEmpty && !isLoading {
                    ContentUnavailableView("没有匹配的状态", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("调整状态筛选，或切换到“全部”。"))
                        .frame(maxWidth: .infinity).padding(.top, 36)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(catalogPage.states) { state in
                            stateRow(state)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(CatalogRequest(query: query, page: pageIndex, revision: 0,
                               geometryRevision: 0))
            .opacity(isLoading ? 0.45 : 1)
            .allowsHitTesting(!isLoading)
            .overlay { if isLoading { ProgressView().controlSize(.small) } }
            Divider()
            pagination
        }
        .padding(18).foregroundStyle(ink)
    }

    @ViewBuilder
    private var filters: some View {
        if query.category == .agents {
            Picker("来源组合", selection: $query.combination) {
                ForEach(IslandAgentCombination.allCases) { combination in
                    Text(combination.title).tag(combination)
                }
            }
            .font(.system(size: 12))
            HStack(alignment: .top, spacing: 12) {
                ForEach(query.combination.providers) { provider in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(provider.title).font(.system(size: 11, weight: .medium))
                        Picker("\(provider.title) 状态", selection: agentStatusBinding(provider)) {
                            ForEach(IslandAgentStatusFilter.allCases.filter { $0.isSupported(by: provider) }) { status in
                                Text(status.title).tag(status)
                            }
                        }.labelsHidden()
                        Picker("\(provider.title) 任务数量", selection: agentCountBinding(provider)) {
                            ForEach(IslandAgentCountFilter.allCases) { count in Text(count.title).tag(count) }
                        }.labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 11))
                }
            }
        }
        if query.category != .expanded {
            HStack(alignment: .top, spacing: 8) {
                if query.category == .agents {
                    filterColumn("音乐") {
                        Picker("音乐", selection: $query.music) {
                            Text("无音乐").tag(false)
                            Text("音乐播放").tag(true)
                        }.labelsHidden()
                    }
                }
                if query.category == .agents || query.category == .music || query.category == .timer {
                    filterColumn("计时器") {
                        Picker("计时器", selection: $query.timer) {
                            ForEach(IslandTimerActivity.allCases.filter { query.category != .timer || $0 != .off }) { timer in
                                Text(timer.title).tag(timer)
                            }
                        }.labelsHidden()
                    }
                }
                filterColumn("电池") {
                    Picker("电池", selection: $query.battery) {
                        ForEach(IslandBatteryActivity.allCases) { battery in Text(battery.title).tag(battery) }
                    }.labelsHidden()
                }
                filterColumn("设备") {
                    Picker("USB 设备", selection: $query.usb) {
                        Text("无 USB").tag(false)
                        Text("USB 连接").tag(true)
                    }.labelsHidden()
                }
            }
            .font(.system(size: 11))
        } else {
            HStack(alignment: .top, spacing: 12) {
                filterColumn("手机") {
                    Picker("手机详情区域", selection: Binding(get: { query.phone }, set: {
                        query.phone = $0
                        query.focusedConfiguration = nil
                    })) {
                        Text("未连接").tag(false)
                        Text("已连接").tag(true)
                    }.labelsHidden()
                }
                filterColumn("本机") {
                    Picker("电脑详情区域", selection: Binding(get: { query.computer }, set: {
                        query.computer = $0
                        query.focusedConfiguration = nil
                    })) {
                        Text("隐藏").tag(false)
                        Text("显示").tag(true)
                    }.labelsHidden()
                }
                Text("展开页面按页面独立保存长度，高度保持原有布局。")
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
                    .padding(.top, 18)
            }
        }
    }

    private func filterColumn<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(ink.opacity(0.45))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tableHeader: some View {
        HStack(spacing: 10) {
            Text("状态组合").frame(maxWidth: .infinity, alignment: .leading)
            Text("默认 pt").frame(width: 56)
            Text("当前长度").frame(width: 172)
            Text("恢复").frame(width: 28)
            Text("预览").frame(width: 64)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.45))
        .padding(.horizontal, 10)
    }

    private func stateRow(_ state: IslandLengthState) -> some View {
        let current = state.key == lengthSettings.currentState.key
        let previewing = state.key == lengthSettings.previewState?.key
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(state.title).font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if current || previewing || lengthSettings.isModified(state) {
                    HStack(spacing: 6) {
                        if current { Text("当前").foregroundStyle(accent) }
                        if previewing { Text("预览中").foregroundStyle(accent) }
                        if lengthSettings.isModified(state) { Text("已修改").foregroundStyle(ink.opacity(0.5)) }
                    }.font(.system(size: 9, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(lengthSettings.defaultWidth(for: state))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(ink.opacity(0.45))
                .frame(width: 56)
            IslandLengthEditor(settings: lengthSettings, state: state, large: false)
                .frame(width: 172)
            Button { lengthSettings.resetWidth(for: state) } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(ink.opacity(0.6))
            .disabled(!lengthSettings.isModified(state)).help("恢复此状态的默认长度")
            previewButton(for: state)
        }
        .padding(10)
        .background(current || previewing ? accent.opacity(0.07) : surface,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func previewButton(for state: IslandLengthState) -> some View {
        let previewing = lengthSettings.previewState?.key == state.key
        return Button(previewing ? "退出预览" : "预览") {
            lengthSettings.togglePreview(for: state)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(previewing ? accent : ink.opacity(0.65))
        .frame(width: 64, height: 28)
        .background(previewing ? accent.opacity(0.12) : ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .help(previewing ? "恢复实际状态" : "在顶部灵动岛预览此状态，调整长度会同步显示")
        .accessibilityLabel("\(previewing ? "退出预览" : "预览")：\(state.title)")
    }

    private var pagination: some View {
        let pages = max(1, (catalogPage.total + pageSize - 1) / pageSize)
        return HStack(spacing: 10) {
            Text("\(catalogPage.total.formatted()) 个状态")
                .font(.system(size: 10)).foregroundStyle(ink.opacity(0.5))
            Spacer()
            Button { pageIndex -= 1 } label: { Image(systemName: "chevron.left") }
                .disabled(pageIndex == 0 || isLoading)
            Text("\(pageIndex + 1) / \(pages)")
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
            Button { pageIndex += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(pageIndex + 1 >= pages || isLoading)
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private func agentStatusBinding(_ provider: IslandAgentProvider) -> Binding<IslandAgentStatusFilter> {
        Binding(get: { query.agentFilters[provider]?.status ?? .all }, set: { value in
            var filter = query.agentFilters[provider] ?? IslandAgentCatalogFilter()
            filter.status = value
            query.agentFilters[provider] = filter
        })
    }

    private func agentCountBinding(_ provider: IslandAgentProvider) -> Binding<IslandAgentCountFilter> {
        Binding(get: { query.agentFilters[provider]?.count ?? .all }, set: { value in
            var filter = query.agentFilters[provider] ?? IslandAgentCatalogFilter()
            filter.count = value
            query.agentFilters[provider] = filter
        })
    }

    private func locateCurrentState() {
        let configuration = lengthSettings.displayedState.configuration
        query.category = configuration.category
        query.combination = IslandAgentCombination.matching(configuration.orderedAgents.map(\.provider)) ?? .codex
        query.music = configuration.music
        query.timer = configuration.timer
        query.battery = configuration.battery
        query.usb = configuration.usb
        query.phone = configuration.phone
        query.computer = configuration.computer
        query.search = ""
        query.modifiedOnly = false
        query.focusedConfiguration = configuration
        pageIndex = 0
    }

    private func loadCatalog(_ request: CatalogRequest) async {
        isLoading = true
        if !request.query.search.isEmpty {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        let saved = lengthSettings.snapshot
        let worker = Task.detached(priority: .userInitiated) {
            request.query.page(request.page, size: 40, saved: saved)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        let maxPage = max(0, (result.total - 1) / pageSize)
        if pageIndex > maxPage {
            pageIndex = maxPage
            return
        }
        catalogPage = result
        isLoading = false
    }
}

nonisolated private struct CatalogRequest: Hashable, Sendable {
    let query: IslandLengthCatalogQuery
    let page: Int
    let revision: Int
    let geometryRevision: Int
}

/// Every row edits its own captured state, including when live detection changes
/// while a current-state input is focused.
private struct IslandLengthEditor: View {
    @ObservedObject var settings: IslandLengthSettings
    let state: IslandLengthState
    let large: Bool
    @State private var draft = ""
    @State private var editingState: IslandLengthState?
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: large ? 8 : 4) {
                adjustmentButton("minus", by: -1)
                TextField("长度", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: large ? 28 : 13, weight: .semibold, design: .rounded))
                    .monospacedDigit().multilineTextAlignment(.center)
                    .frame(width: large ? 98 : 52)
                    .focused($focused)
                    .accessibilityLabel("\(state.title)的长度")
                    .help("输入整数长度，按回车保存；Esc 取消")
                    .onSubmit { if commit() { focused = false } }
                    .onExitCommand {
                        settings.updatePreviewWidth(nil, for: editingState ?? state)
                        editingState = nil
                        draft = String(settings.width(for: state))
                        message = nil
                        focused = false
                    }
                Text("pt").font(.system(size: 10)).foregroundStyle(.secondary)
                adjustmentButton("plus", by: 1)
            }
            .padding(large ? 8 : 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: large ? 10 : 6))
            if let message {
                Text(message).font(.system(size: 9)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: large ? 250 : 172, alignment: .trailing)
            }
        }
        .onAppear { draft = String(settings.width(for: state)) }
        .onChange(of: draft) { _, value in
            guard focused else { return }
            let target = editingState ?? state
            let width = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            let validWidth = width.flatMap { settings.allowedWidthRange(for: target).contains($0) ? $0 : nil }
            settings.updatePreviewWidth(validWidth, for: target)
        }
        .onChange(of: focused) { _, value in
            if value {
                editingState = state
                message = nil
            } else if editingState != nil {
                _ = commit()
                settings.updatePreviewWidth(nil, for: editingState ?? state)
                editingState = nil
                draft = String(settings.width(for: state))
            }
        }
        .onChange(of: state.key) { _, _ in
            if editingState != nil {
                let saved = commit()
                message = saved ? "已保存原状态，当前状态已切换" : "状态已切换，无效输入未保存"
                editingState = nil
                focused = false
            }
            draft = String(settings.width(for: state))
        }
        .onChange(of: settings.revision) { _, _ in
            if !focused { draft = String(settings.width(for: state)) }
        }
        .onChange(of: settings.geometryRevision) { _, _ in
            if !focused { draft = String(settings.width(for: state)) }
        }
        .onDisappear {
            if editingState != nil { _ = commit() }
        }
    }

    private func adjustmentButton(_ symbol: String, by amount: Int) -> some View {
        Button {
            if focused {
                guard commit() else { return }
                focused = false
            }
            settings.setWidth(settings.width(for: state) + amount, for: state)
            draft = String(settings.width(for: state))
            message = nil
        } label: {
            Image(systemName: symbol).font(.system(size: large ? 12 : 10, weight: .bold))
                .frame(width: large ? 28 : 22, height: large ? 30 : 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(symbol == "plus" ? "增加" : "减少") 1 pt")
    }

    @discardableResult
    private func commit() -> Bool {
        let target = editingState ?? state
        let range = settings.allowedWidthRange(for: target)
        guard let value = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(value) else {
            message = "请输入 \(range.lowerBound)–\(range.upperBound) 的整数"
            return false
        }
        settings.setWidth(value, for: target)
        settings.updatePreviewWidth(nil, for: target)
        editingState = nil
        draft = String(settings.width(for: state))
        message = nil
        return true
    }
}

struct IslandSettingsThemeToggle: View {
    @Binding var isLightTheme: Bool
    private var ink: Color { isLightTheme ? .black : .white }
    var body: some View {
        Button {
            let nextTheme = !isLightTheme
            IslandSettingsWindow.transitionTheme(to: nextTheme) {
                withAnimation(.easeInOut(duration: IslandSettingsWindow.themeTransitionDuration)) {
                    isLightTheme = nextTheme
                }
            }
        } label: {
            ZStack {
                Image(systemName: "sun.max.fill")
                    .opacity(isLightTheme ? 1 : 0)
                    .scaleEffect(isLightTheme ? 1 : 0.8)
                Image(systemName: "moon.fill")
                    .opacity(isLightTheme ? 0 : 1)
                    .scaleEffect(isLightTheme ? 0.8 : 1)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(ink.opacity(0.8))
            .frame(width: 36, height: 36)
            .background {
                Circle().fill(LinearGradient(
                    colors: [ink.opacity(0.09), ink.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            }
            .overlay { Circle().strokeBorder(ink.opacity(0.10), lineWidth: 0.5) }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isLightTheme ? "切换为深色主题" : "切换为浅色主题")
        .accessibilityLabel(isLightTheme ? "切换为深色主题" : "切换为浅色主题")
        .accessibilityValue(isLightTheme ? "当前为浅色主题" : "当前为深色主题")
    }

}
