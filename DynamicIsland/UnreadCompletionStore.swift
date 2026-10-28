import Foundation

/// 完成提示独立于监测器短暂保留的终态快照，重启后仍可显示。
final class UnreadCompletionStore<Task: Codable & Identifiable> where Task.ID == String {
    private let key: String
    private let defaults: UserDefaults
    private(set) var tasks: [Task]

    init(provider: String, defaults: UserDefaults = .standard) {
        key = "UnreadAgentCompletions.\(provider)"
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([Task].self, from: data) {
            tasks = stored
        } else {
            tasks = []
        }
    }

    func record(_ task: Task) {
        tasks.removeAll { $0.id == task.id }
        tasks.append(task)
        persist()
    }

    func markViewed() {
        guard !tasks.isEmpty else { return }
        tasks.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        defaults.set(data, forKey: key)
    }
}
