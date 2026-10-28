import Foundation

struct CodexTaskSnapshot: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case working = "inProgress", completed, failed, interrupted

        var label: String {
            switch self {
            case .working: "正在工作"
            case .completed: "已完成"
            case .failed: "运行失败"
            case .interrupted: "已中断"
            }
        }
        var symbolName: String {
            switch self {
            case .working: "sparkles"
            case .completed: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .interrupted: "stop.circle.fill"
            }
        }
        var priority: Int {
            switch self {
            case .failed: 0
            case .working: 1
            case .completed: 2
            case .interrupted: 3
            }
        }
    }

    let id: String
    let rootThreadID: String
    let title: String
    let projectName: String
    let cwd: String?
    let state: State
    let startedAt: Date
    let updatedAt: Date
}
