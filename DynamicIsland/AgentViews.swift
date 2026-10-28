import SwiftUI
import AppKit

private enum AIExpandedTaskRow: Identifiable {
    case codex(CodexTaskSnapshot)
    case claude(ClaudeCodeTaskSnapshot)
    case deepSeek(DeepSeekHarnessTaskSnapshot)

    var provider: IslandAgentProvider {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .deepSeek: .deepSeek
        }
    }

    var isWorking: Bool {
        switch self {
        case let .codex(task): task.state == .working
        case let .claude(task): task.state == .working
        case let .deepSeek(task): task.state == .working
        }
    }

    var isWaiting: Bool {
        switch self {
        case .codex: false
        case let .claude(task): task.state == .waiting
        case let .deepSeek(task): task.state == .waiting
        }
    }

    var id: String {
        switch self {
        case let .codex(task): "codex:\(task.id)"
        case let .claude(task): "claude:\(task.id)"
        case let .deepSeek(task): "deepseek:\(task.id)"
        }
    }

    private var startedAt: Date {
        switch self {
        case let .codex(task): task.startedAt
        case let .claude(task): task.startedAt
        case let .deepSeek(task): task.startedAt
        }
    }

    static func isEarlierInWorkspace(_ lhs: Self, _ rhs: Self) -> Bool {
        // 展开列表的位置不随日志更新或状态优先级变化；同一开始时间
        // 使用任务 ID 打破平局，避免字典遍历顺序导致行交换。
        lhs.startedAt != rhs.startedAt
            ? lhs.startedAt > rhs.startedAt
            : lhs.id < rhs.id
    }
}

struct AIExpandedCard: View {
    @ObservedObject var codexStatus: CodexStatusMonitor
    @ObservedObject var claudeStatus: ClaudeCodeStatusMonitor
    @ObservedObject var deepSeekStatus: DeepSeekHarnessStatusMonitor
    @State private var selectedProvider: IslandAgentProvider?

    var displaySnapshot = IslandDisplaySettingsSnapshot()

    private var activeTaskCount: Int {
        visibleTaskRows.filter(\.isWorking).count
    }

    private var hasTasks: Bool {
        !visibleTaskRows.isEmpty
    }

    private var waitingTaskCount: Int {
        visibleTaskRows.filter(\.isWaiting).count
    }

    private var availableProviders: [IslandAgentProvider] {
        IslandAgentProvider.allCases.filter { provider in
            allTaskRows.contains { $0.provider == provider }
        }
    }

    private var effectiveSelectedProvider: IslandAgentProvider? {
        selectedProvider.flatMap { availableProviders.contains($0) ? $0 : nil }
    }

    private var visibleTaskRows: [AIExpandedTaskRow] {
        guard let provider = effectiveSelectedProvider else { return allTaskRows }
        return allTaskRows.filter { $0.provider == provider }
    }

    private var allTaskRows: [AIExpandedTaskRow] {
        let providers: [[AIExpandedTaskRow]] = [
            (displaySnapshot.isEnabled(.codex) ? codexStatus.tasks : []).map(AIExpandedTaskRow.codex),
            (displaySnapshot.isEnabled(.claude) ? claudeStatus.tasks : []).map(AIExpandedTaskRow.claude),
            (displaySnapshot.isEnabled(.deepSeek) ? deepSeekStatus.tasks : []).map(AIExpandedTaskRow.deepSeek)
        ].map { $0.sorted { AIExpandedTaskRow.isEarlierInWorkspace($0, $1) } }
        let largestProviderCount = providers.map(\.count).max() ?? 0
        var rows: [AIExpandedTaskRow] = []
        for taskIndex in 0..<largestProviderCount {
            for provider in providers where taskIndex < provider.count {
                rows.append(provider[taskIndex])
            }
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .bold))
                Text("AI 工作台")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(workspaceStatusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(availableProviders) { provider in
                        providerFilterButton(provider)
                    }
                }
            }

            if !hasTasks {
                Text("当前没有运行中的任务")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 7) {
                        ForEach(visibleTaskRows) { row in
                            expandedTaskRow(row)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .scrollIndicators(visibleTaskRows.count > 3 ? .visible : .hidden)
            }

            HStack {
                Spacer()
                if showsProvider(.deepSeek) {
                    Button("打开 DeepSeek") {
                        codexStatus.isExpanded = false
                        deepSeekStatus.openDeepSeekHarness()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.20), in: Capsule())
                }
                if showsProvider(.claude) {
                    Button("打开 Claude") {
                        codexStatus.isExpanded = false
                        claudeStatus.openClaudeCode()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                }
                if showsProvider(.codex) {
                    Button("打开 Codex") {
                        codexStatus.isExpanded = false
                        codexStatus.openCodex()
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 42)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .onChange(of: availableProviders) { _, providers in
            if let selectedProvider, !providers.contains(selectedProvider) {
                self.selectedProvider = nil
            }
        }
    }

    private func showsProvider(_ provider: IslandAgentProvider) -> Bool {
        availableProviders.contains(provider)
            && (effectiveSelectedProvider == nil || effectiveSelectedProvider == provider)
    }

    private func providerFilterButton(_ provider: IslandAgentProvider) -> some View {
        let isSelected = effectiveSelectedProvider == provider
        return Button {
            withAnimation(IslandMotion.control) {
                selectedProvider = isSelected ? nil : provider
            }
        } label: {
            providerFilterIcon(provider)
                .frame(width: 17, height: 17)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(isSelected ? 0.18 : 0.06), in: Circle())
                .overlay {
                    Circle().strokeBorder(isSelected ? Color.cyan : .clear, lineWidth: 1.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "显示全部 agent 的任务" : "只显示 \(provider.shortTitle) 的任务")
        .accessibilityLabel("筛选 \(provider.shortTitle) 任务")
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func providerFilterIcon(_ provider: IslandAgentProvider) -> some View {
        switch provider {
        case .codex:
            Image("CodexStatusIcon")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
        case .claude:
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.orange)
        case .deepSeek:
            Image("DeepSeekStatusIcon")
                .resizable()
                .scaledToFit()
        }
    }

    @ViewBuilder
    private func expandedTaskRow(_ row: AIExpandedTaskRow) -> some View {
        switch row {
        case let .codex(task): codexTaskRow(task)
        case let .claude(task): claudeTaskRow(task)
        case let .deepSeek(task): deepSeekTaskRow(task)
        }
    }

    private func codexTaskRow(_ task: CodexTaskSnapshot) -> some View {
        HStack(spacing: 10) {
            Group {
                if task.state == .working {
                    CodexWorkingIcon()
                } else {
                    Image(systemName: task.state.symbolName)
                        .foregroundStyle(color(for: task.state))
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex · \(task.projectName)")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Text(task.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .lineLimit(1)
            }
            Spacer(minLength: 5)
            if task.state == .completed {
                Text("已完成")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))
            } else {
                AgentElapsedLabel(startedAt: task.startedAt, updatedAt: task.updatedAt,
                                      isWorking: task.state == .working, stateLabel: task.state.label)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 43)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func claudeTaskRow(_ task: ClaudeCodeTaskSnapshot) -> some View {
        HStack(spacing: 10) {
            Group {
                if task.state == .working {
                    ClaudeWorkingIcon()
                } else {
                    Image(systemName: task.state.symbolName)
                        .foregroundStyle(claudeTaskColor(task.state))
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude · \(task.projectName)")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Text(task.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .lineLimit(1)
            }
            Spacer(minLength: 5)
            if task.state == .completed {
                Text("已完成")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))
            } else {
                AgentElapsedClock(
                    startedAt: task.startedAt,
                    updatedAt: task.updatedAt,
                    isWorking: task.state == .working,
                    idleText: task.state.label
                )
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 43)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func deepSeekTaskRow(_ task: DeepSeekHarnessTaskSnapshot) -> some View {
        HStack(spacing: 10) {
            Group {
                if task.state == .working {
                    DeepSeekWorkingIcon()
                } else if task.state == .waiting {
                    Image("DeepSeekStatusIcon")
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: task.state.symbolName)
                        .foregroundStyle(deepSeekTaskColor(task.state))
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("DeepSeek · \(task.projectName)")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Text(task.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .lineLimit(1)
            }
            Spacer(minLength: 5)
            if task.state == .completed {
                Text("已完成")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))
            } else {
                AgentElapsedClock(
                    startedAt: task.startedAt,
                    updatedAt: task.updatedAt,
                    isWorking: task.state == .working,
                    idleText: task.state.label,
                    color: task.state == .waiting ? .yellow : Color.white.opacity(0.56)
                )
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 43)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var statusColor: Color {
        waitingTaskCount > 0 ? .yellow : (activeTaskCount > 0 ? .cyan : .green)
    }

    private var workspaceStatusText: String {
        if waitingTaskCount > 0 {
            return "\(waitingTaskCount) 个待确认"
        }
        return activeTaskCount > 0 ? "\(activeTaskCount) 个进行中" : "最近完成"
    }

    private func claudeTaskColor(_ state: ClaudeCodeTaskSnapshot.State) -> Color {
        switch state {
        case .working: .orange
        case .waiting: .yellow
        case .completed: .green
        case .interrupted: .gray
        }
    }

    private func deepSeekTaskColor(_ state: DeepSeekHarnessTaskSnapshot.State) -> Color {
        switch state {
        case .working: .blue
        case .waiting: .yellow
        case .completed: .green
        case .interrupted: .gray
        }
    }

    private func color(for state: CodexTaskSnapshot.State) -> Color {
        switch state {
        case .working: .white
        case .completed: .green
        case .failed: .red
        case .interrupted: .gray
        }
    }
}

struct ClaudeWorkingIcon: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 2.5
            let pulse = (sin(phase) + 1) / 2
            Image(systemName: "sun.max.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.orange)
                .opacity(0.48 + pulse * 0.52)
                .scaleEffect(0.86 + pulse * 0.14)
                .rotationEffect(.degrees(phase * 7))
        }
        .accessibilityLabel("Claude Code 正在工作")
    }
}

struct CodexWorkingIcon: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 2.7
            let pulse = (sin(phase) + 1) / 2
            Image("CodexStatusIcon")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
                .opacity(0.38 + pulse * 0.62)
                .scaleEffect(0.88 + pulse * 0.12)
        }
        .accessibilityLabel("Codex 正在工作")
    }
}

struct DeepSeekWorkingIcon: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 2.6
            let pulse = (sin(phase) + 1) / 2
            Image("DeepSeekStatusIcon")
                .resizable()
                .scaledToFit()
                .opacity(0.46 + pulse * 0.54)
                .scaleEffect(0.88 + pulse * 0.12)
                .offset(y: sin(phase * 0.72) * 0.7)
        }
        .accessibilityLabel("DeepSeek Harness 正在工作")
    }
}
