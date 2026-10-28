import Foundation
import Combine

struct MemoTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var isCompleted = false
}

struct IslandMemo: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var tasks: [MemoTask] = []
    var isPinned = false
    var updatedAt = Date()

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tasks.isEmpty }
    var title: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? tasks.first?.text ?? "新备忘录"
    }
    var hasOpenTasks: Bool { tasks.contains { !$0.isCompleted } }
    var bodyPreview: String { text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n") }
    func summary(limit: Int = 64) -> String {
        let content = (tasks.first { !$0.isCompleted }?.text ?? title)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return content.count > limit ? String(content.prefix(limit)) + "…" : content
    }
}

/// Presentation state for one expanded notes card; never persisted with the memos.
struct NotesCardSession {
    private var retainedTaskIDs: Set<UUID> = []

    mutating func toggleTask(memoID: UUID, taskID: UUID, in store: NotesStore) {
        store.toggleTask(memoID: memoID, taskID: taskID)
        // Read the committed value so a failed save cannot show a false completion.
        if store.memos.first(where: { $0.id == memoID })?.tasks.first(where: { $0.id == taskID })?.isCompleted == true {
            retainedTaskIDs.insert(taskID)
        } else {
            retainedTaskIDs.remove(taskID)
        }
    }

    func memos(in store: NotesStore, showsAll: Bool) -> [IslandMemo] {
        store.sortedMemos.filter { memo in
            showsAll || memo.isPinned || memo.hasOpenTasks ||
                memo.tasks.contains { retainedTaskIDs.contains($0.id) }
        }
    }

    func visibleTasks(in memo: IslandMemo) -> [MemoTask] {
        memo.tasks.filter { !$0.isCompleted || retainedTaskIDs.contains($0.id) }
    }

    func completedTasks(in memo: IslandMemo) -> [MemoTask] {
        memo.tasks.filter { $0.isCompleted && !retainedTaskIDs.contains($0.id) }
    }
}

/// One local document. A failed read never silently replaces existing content.
final class NotesStore: ObservableObject {
    private struct Document: Codable { var version = 1; var memos: [IslandMemo] }
    @Published private(set) var memos: [IslandMemo] = []
    @Published private(set) var errorMessage: String?
    private let fileURL: URL?
    private var canWrite = true

    static var localURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicIsland", isDirectory: true)
            .appendingPathComponent("memos-v1.json")
    }

    // nil is deliberately memory-only for previews and integration tests.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            memos = document.memos
        } catch {
            canWrite = false
            errorMessage = "备忘录读取失败，原文件已保留。请检查本地文件后重新打开应用。"
        }
    }

    var sortedMemos: [IslandMemo] {
        memos.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }
    var quickMemos: [IslandMemo] { sortedMemos.filter { $0.isPinned || $0.hasOpenTasks } }
    var unfinishedCount: Int { memos.flatMap(\.tasks).filter { !$0.isCompleted }.count }
    var unlockMemos: [IslandMemo] { Array(quickMemos.prefix(2)) }

    @discardableResult
    func save(_ memo: IslandMemo) -> Bool {
        guard !memo.isEmpty else { return false }
        var next = memos
        var memo = memo
        memo.updatedAt = Date()
        if let index = next.firstIndex(where: { $0.id == memo.id }) { next[index] = memo }
        else { next.append(memo) }
        return commit(next)
    }

    func toggleTask(memoID: UUID, taskID: UUID) {
        guard var memo = memos.first(where: { $0.id == memoID }),
              let index = memo.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        memo.tasks[index].isCompleted.toggle()
        save(memo)
    }

    @discardableResult
    func deleteTask(memoID: UUID, taskID: UUID) -> Bool {
        guard var memo = memos.first(where: { $0.id == memoID }),
              memo.tasks.contains(where: { $0.id == taskID }) else { return false }
        memo.tasks.removeAll { $0.id == taskID }
        // Removing the sole task from a task-only memo leaves nothing to display.
        return memo.isEmpty ? delete(memoID) : save(memo)
    }

    /// Keep quick-card changes made while an editor draft was open.
    @discardableResult
    func saveEdits(_ draft: IslandMemo, original: IslandMemo?) -> Bool {
        guard let original else { return save(draft) }
        guard var current = memos.first(where: { $0.id == draft.id }) else {
            errorMessage = "这条备忘录已被删除，当前草稿仍保留在编辑窗口中。"
            return false
        }
        if draft.text != original.text { current.text = draft.text }
        if draft.isPinned != original.isPinned { current.isPinned = draft.isPinned }
        current.tasks.removeAll { task in original.tasks.contains { $0.id == task.id } && !draft.tasks.contains { $0.id == task.id } }
        for task in draft.tasks {
            if let before = original.tasks.first(where: { $0.id == task.id }) {
                if let index = current.tasks.firstIndex(where: { $0.id == task.id }) {
                    if task.text != before.text { current.tasks[index].text = task.text }
                    if task.isCompleted != before.isCompleted { current.tasks[index].isCompleted = task.isCompleted }
                }
            } else { current.tasks.append(task) }
        }
        return save(current)
    }

    func togglePin(_ id: UUID) {
        guard var memo = memos.first(where: { $0.id == id }) else { return }
        memo.isPinned.toggle()
        save(memo)
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool { commit(memos.filter { $0.id != id }) }

    private func commit(_ next: [IslandMemo]) -> Bool {
        guard canWrite else { return false }
        do {
            if let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(Document(memos: next))
                try data.write(to: fileURL, options: .atomic)
            }
            memos = next
            errorMessage = nil
            return true
        } catch {
            errorMessage = "备忘录保存失败，请检查本地存储空间与文件权限。"
            return false
        }
    }
}
