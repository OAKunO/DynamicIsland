import SwiftUI

/// Separate sample models keep real timers, tasks and playback running while
/// the same production layout is displayed for length editing.
struct IslandStatePreview: View {
    let configuration: IslandLengthConfiguration
    @StateObject private var model: IslandModel

    init(configuration: IslandLengthConfiguration) {
        self.configuration = configuration
        _model = StateObject(wrappedValue: IslandModel(previewConfiguration: configuration))
    }

    var body: some View {
        ContentView(model: model, previewConfiguration: configuration)
            .frame(height: WindowManager.defaultSize(for: configuration).height)
            .accessibilityLabel("长度预览：\(configuration.title)")
    }
}

enum IslandPreviewTasks {
    private static func statuses(_ provider: IslandAgentProvider, in configuration: IslandLengthConfiguration) -> [IslandAgentStatus] {
        let activity = configuration.agents.first { $0.provider == provider }
        // A catalog entry for an expanded page can have no compact activities.
        if activity == nil, configuration.mode == .expandedAgent { return [.working] }
        let priority: [IslandAgentStatus] = [.waiting, .working, .failed, .completed, .interrupted]
        return priority.flatMap { Array(repeating: $0, count: activity?.count($0) ?? 0) }
    }

    static func codex(_ configuration: IslandLengthConfiguration) -> [CodexTaskSnapshot] {
        let now = Date()
        return statuses(.codex, in: configuration).enumerated().map { index, status in
            let state: CodexTaskSnapshot.State
            switch status {
            case .working, .waiting: state = .working
            case .completed: state = .completed
            case .failed: state = .failed
            case .interrupted: state = .interrupted
            }
            return CodexTaskSnapshot(
                id: "preview-codex-\(index)", rootThreadID: "preview-\(index)",
                title: "示例任务 \(index + 1)", projectName: "预览项目", cwd: nil,
                state: state, startedAt: now.addingTimeInterval(-125), updatedAt: now
            )
        }
    }

    static func claude(_ configuration: IslandLengthConfiguration) -> [ClaudeCodeTaskSnapshot] {
        let now = Date()
        return statuses(.claude, in: configuration).enumerated().map { index, status in
            ClaudeCodeTaskSnapshot(
                id: "preview-claude-\(index)", title: "示例任务 \(index + 1)",
                projectName: "预览项目", cwd: "", processID: 0,
                state: ClaudeCodeTaskSnapshot.State(rawValue: status.rawValue) ?? .interrupted,
                startedAt: now.addingTimeInterval(-125), updatedAt: now
            )
        }
    }

    static func deepSeek(_ configuration: IslandLengthConfiguration) -> [DeepSeekHarnessTaskSnapshot] {
        let now = Date()
        return statuses(.deepSeek, in: configuration).enumerated().map { index, status in
            DeepSeekHarnessTaskSnapshot(
                id: "preview-deepseek-\(index)", title: "示例任务 \(index + 1)",
                projectName: "预览项目", cwd: "",
                state: DeepSeekHarnessTaskSnapshot.State(rawValue: status.rawValue) ?? .interrupted,
                startedAt: now.addingTimeInterval(-125), updatedAt: now
            )
        }
    }
}
