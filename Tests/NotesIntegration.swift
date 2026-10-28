import Foundation

@main
struct NotesIntegration {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 3 {
            let store = NotesStore(fileURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            if CommandLine.arguments[1] == "--persistence-write" {
                guard store.save(IslandMemo(text: "跨进程保留的正文🙂", tasks: [MemoTask(text: "已完成事项", isCompleted: true), MemoTask(text: "未完成事项")], isPinned: true)) else { fatalError("Persistence fixture write failed") }
                print("PASS: wrote temporary cross-process persistence fixture")
                return
            }
            if CommandLine.arguments[1] == "--persistence-read" {
                guard store.memos.count == 1, let memo = store.memos.first,
                      memo.text == "跨进程保留的正文🙂", memo.isPinned,
                      memo.tasks.count == 2, memo.tasks[0].isCompleted, !memo.tasks[1].isCompleted else { fatalError("Cross-process persistence did not restore full memo") }
                print("PASS: a fresh process restored text, pin and completed/unfinished tasks")
                return
            }
        }
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicIsland.NotesTests.\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memos.json")
        let store = NotesStore(fileURL: file)
        check(store.memos.isEmpty && store.quickMemos.isEmpty && store.unlockMemos.isEmpty, "Empty state has no summary")
        check(!store.save(IslandMemo()), "Blank drafts must not be persisted")
        var memo = IslandMemo(text: "普通文字不会因勾选消失\n第二行正文", tasks: [MemoTask(text: "测试待办"), MemoTask(text: "另一件事")])
        check(store.save(memo), "Create mixed memo")
        memo.text += "\n编辑后的正文"
        check(store.save(memo) && store.memos.count == 1, "Editing preserves identity")
        store.toggleTask(memoID: memo.id, taskID: memo.tasks[0].id)
        check(store.memos[0].tasks[0].isCompleted && store.unfinishedCount == 1, "Check off exactly one task")
        check(store.memos[0].text == memo.text && store.memos[0].tasks.count == 2, "Checking retains all ordinary text and task records")
        store.toggleTask(memoID: memo.id, taskID: memo.tasks[0].id)
        check(!store.memos[0].tasks[0].isCompleted && store.unfinishedCount == 2, "Undo completion")
        store.togglePin(memo.id)
        check(store.memos[0].isPinned, "Pin memo")
        var plain = IslandMemo(text: "仅有文字的备忘录")
        check(store.save(plain), "Create ordinary memo without tasks")
        check(store.quickMemos.count == 1 && store.sortedMemos[0].id == memo.id, "Quick list prioritizes pinned and unfinished")
        store.togglePin(plain.id)
        check(store.unlockMemos.count == 2, "Unlock summary is capped at two memos")
        store.togglePin(plain.id)
        check(!store.memos.first(where: { $0.id == plain.id })!.isPinned, "Unpin works")
        for task in memo.tasks { store.toggleTask(memoID: memo.id, taskID: task.id) }
        store.togglePin(memo.id)
        check(store.quickMemos.isEmpty && store.memos.count == 2, "Completed items leave quick list but remain in all memos")
        check(store.memos.first(where: { $0.id == memo.id })?.text == memo.text, "Text remains after completing every task")
        let editorOriginal = store.memos.first(where: { $0.id == memo.id })!
        var editorDraft = editorOriginal
        editorDraft.text += "\n窗口中修改"
        store.toggleTask(memoID: memo.id, taskID: memo.tasks[0].id)
        store.togglePin(memo.id)
        check(store.saveEdits(editorDraft, original: editorOriginal), "Save an editor draft alongside quick-card changes")
        check(store.memos.first(where: { $0.id == memo.id })!.isPinned &&
              !store.memos.first(where: { $0.id == memo.id })!.tasks[0].isCompleted,
              "Saving body edits preserves newer completion and pin changes")
        let restored = NotesStore(fileURL: file)
        check(restored.memos == store.memos, "Relaunch restores IDs, text, pin and task state")
        plain.text = String(repeating: "长文🙂\n", count: 2000)
        plain.isPinned = true
        check(store.save(plain), "Save long Unicode text")
        check(store.unlockMemos[0].summary().count <= 65 && !store.unlockMemos[0].summary().contains("\n"), "Summary is a bounded single line")
        check(NotesStore(fileURL: file).memos.first(where: { $0.id == plain.id })?.text == plain.text, "Truncation never changes full stored text")
        check(store.delete(memo.id) && store.memos.count == 1, "Delete removes only requested record")
        let invalid = directory.appendingPathComponent("corrupt.json")
        let original = Data("preserve damaged user data".utf8)
        try original.write(to: invalid)
        let corrupt = NotesStore(fileURL: invalid)
        check(corrupt.errorMessage != nil && !corrupt.save(plain), "Read failure is visible and blocks overwriting")
        let retained = try Data(contentsOf: invalid)
        check(retained == original, "Corrupt original remains untouched")
        let impossible = directory.appendingPathComponent("parent-file")
        try Data().write(to: impossible)
        let unwritable = NotesStore(fileURL: impossible.appendingPathComponent("notes.json"))
        check(!unwritable.save(plain) && unwritable.errorMessage != nil && unwritable.memos.isEmpty, "Failed writes never report success or replace memory state")

        // A card session lasts until the expanded dashboard is removed on collapse.
        let cardStore = NotesStore(fileURL: directory.appendingPathComponent("card.json"))
        let cardMemo = IslandMemo(text: "勾选后留在原位", tasks: [
            MemoTask(text: "第一项"), MemoTask(text: "最后一项"),
            MemoTask(text: "以前已完成", isCompleted: true)
        ])
        check(cardStore.save(cardMemo), "Save card completion fixture")
        var cardSession = NotesCardSession()
        cardSession.toggleTask(memoID: cardMemo.id, taskID: cardMemo.tasks[0].id, in: cardStore)
        var currentCardMemo = cardStore.memos[0]
        check(currentCardMemo.tasks[0].isCompleted && cardStore.unfinishedCount == 1,
              "Completion updates the saved state and unfinished count immediately")
        check(NotesStore(fileURL: directory.appendingPathComponent("card.json")).memos[0].tasks[0].isCompleted,
              "Completion is persisted before the card is collapsed")
        check(cardSession.visibleTasks(in: currentCardMemo).map(\.id) == Array(cardMemo.tasks.prefix(2)).map(\.id),
              "Completed task stays in its original position beside open tasks")
        check(cardSession.completedTasks(in: currentCardMemo).map(\.id) == [cardMemo.tasks[2].id],
              "Only older completions appear in the disclosure, with no duplicated task")
        cardSession.toggleTask(memoID: cardMemo.id, taskID: cardMemo.tasks[1].id, in: cardStore)
        currentCardMemo = cardStore.memos[0]
        check(cardStore.quickMemos.isEmpty && cardSession.memos(in: cardStore, showsAll: false).map(\.id) == [cardMemo.id],
              "Finishing the final task retains its unpinned memo in this card session")
        check(cardSession.visibleTasks(in: currentCardMemo).count == 2 && cardStore.unfinishedCount == 0,
              "All newly completed rows remain visible with their committed completion state")
        check(cardSession.memos(in: cardStore, showsAll: true).map(\.id) == [cardMemo.id] &&
              cardSession.memos(in: cardStore, showsAll: false).map(\.id) == [cardMemo.id],
              "Switching between All and Quick does not discard retained completions")
        let reopenedSession = NotesCardSession()
        check(reopenedSession.memos(in: cardStore, showsAll: false).isEmpty &&
              reopenedSession.visibleTasks(in: currentCardMemo).isEmpty &&
              reopenedSession.completedTasks(in: currentCardMemo).count == 3,
              "Reopening removes completed rows from Quick and moves them into the completed disclosure")
        check(reopenedSession.memos(in: cardStore, showsAll: true).first?.text == cardMemo.text,
              "Completed memo and full body remain accessible in All")
        cardStore.togglePin(cardMemo.id)
        check(reopenedSession.memos(in: cardStore, showsAll: false).count == 1 &&
              reopenedSession.visibleTasks(in: cardStore.memos[0]).isEmpty,
              "Pinned memo remains after reopening with its completed tasks folded away")
        cardSession.toggleTask(memoID: cardMemo.id, taskID: cardMemo.tasks[0].id, in: cardStore)
        check(!cardStore.memos[0].tasks[0].isCompleted && cardStore.unfinishedCount == 1 &&
              cardSession.visibleTasks(in: cardStore.memos[0]).count == 2,
              "A retained completion can be undone without its row disappearing")
        check(cardStore.delete(cardMemo.id) && cardSession.memos(in: cardStore, showsAll: false).isEmpty,
              "Retained task IDs cannot resurrect a deleted memo")

        let failureParent = directory.appendingPathComponent("card-failure", isDirectory: true)
        let failingCardStore = NotesStore(fileURL: failureParent.appendingPathComponent("notes.json"))
        check(failingCardStore.save(cardMemo), "Save fixture before simulating a write failure")
        try FileManager.default.removeItem(at: failureParent)
        try Data().write(to: failureParent)
        var failingSession = NotesCardSession()
        failingSession.toggleTask(memoID: cardMemo.id, taskID: cardMemo.tasks[0].id, in: failingCardStore)
        check(failingCardStore.errorMessage != nil && !failingCardStore.memos[0].tasks[0].isCompleted &&
              failingSession.completedTasks(in: failingCardStore.memos[0]).count == 1,
              "Failed completion leaves the task unchecked and reports the save error")
        let beforeFailedDeletion = failingCardStore.memos
        check(!failingCardStore.deleteTask(memoID: cardMemo.id, taskID: cardMemo.tasks[0].id) &&
              failingCardStore.memos == beforeFailedDeletion && failingCardStore.errorMessage != nil,
              "Failed task deletion leaves every task in memory")
        check(!failingCardStore.delete(cardMemo.id) && failingCardStore.memos == beforeFailedDeletion,
              "Failed memo deletion leaves the memo intact")

        let deletionFile = directory.appendingPathComponent("deletion.json")
        let deletionStore = NotesStore(fileURL: deletionFile)
        let deletionMemo = IslandMemo(text: "删除待办时保留正文\n第二行", tasks: [
            MemoTask(text: "删除这一项"), MemoTask(text: "保留这一项"),
            MemoTask(text: "删除已完成项", isCompleted: true)
        ], isPinned: true)
        let otherMemo = IslandMemo(text: "另一条备忘录", tasks: [MemoTask(text: "不受影响")])
        check(deletionStore.save(deletionMemo) && deletionStore.save(otherMemo), "Save deletion fixtures")
        check(deletionStore.deleteTask(memoID: deletionMemo.id, taskID: deletionMemo.tasks[0].id),
              "Delete an open task directly")
        var afterDeletion = deletionStore.memos.first { $0.id == deletionMemo.id }!
        check(afterDeletion.text == deletionMemo.text && afterDeletion.isPinned &&
              afterDeletion.tasks.map(\.id) == Array(deletionMemo.tasks.dropFirst()).map(\.id) &&
              deletionStore.unfinishedCount == 2 &&
              deletionStore.memos.first { $0.id == otherMemo.id }?.text == otherMemo.text &&
              deletionStore.memos.first { $0.id == otherMemo.id }?.tasks == otherMemo.tasks,
              "Task deletion preserves body, pin, sibling order and other memos, and updates count")
        check(deletionStore.deleteTask(memoID: deletionMemo.id, taskID: deletionMemo.tasks[2].id),
              "Completed tasks can also be deleted")
        var staleDraft = deletionMemo
        staleDraft.text += "\n窗口中的修改"
        check(deletionStore.saveEdits(staleDraft, original: deletionMemo) &&
              deletionStore.memos.first { $0.id == deletionMemo.id }!.tasks.map(\.id) == [deletionMemo.tasks[1].id],
              "Saving an older editor draft cannot resurrect deleted tasks")
        check(deletionStore.deleteTask(memoID: deletionMemo.id, taskID: deletionMemo.tasks[1].id),
              "Delete the last task from a text memo")
        afterDeletion = deletionStore.memos.first { $0.id == deletionMemo.id }!
        check(afterDeletion.tasks.isEmpty && afterDeletion.text == staleDraft.text && afterDeletion.isPinned,
              "Deleting the final task preserves a memo with body text")
        let taskOnlyMemo = IslandMemo(tasks: [MemoTask(text: "唯一一项")])
        check(deletionStore.save(taskOnlyMemo) &&
              deletionStore.deleteTask(memoID: taskOnlyMemo.id, taskID: taskOnlyMemo.tasks[0].id) &&
              !deletionStore.memos.contains { $0.id == taskOnlyMemo.id },
              "Deleting the only task from a task-only memo removes the empty memo")
        let beforeMissingDeletion = deletionStore.memos
        check(!deletionStore.deleteTask(memoID: deletionMemo.id, taskID: UUID()) &&
              !deletionStore.deleteTask(memoID: UUID(), taskID: deletionMemo.tasks[0].id) &&
              deletionStore.memos == beforeMissingDeletion,
              "Missing task and memo IDs do not change other content")
        check(NotesStore(fileURL: deletionFile).memos == deletionStore.memos,
              "Task deletions remain deleted after reloading the file")
        check(deletionStore.delete(deletionMemo.id) &&
              !deletionStore.saveEdits(staleDraft, original: deletionMemo) &&
              deletionStore.memos.map(\.id) == [otherMemo.id],
              "Deleting a whole memo preserves other memos and blocks resurrection by an open editor")
        check(NotesStore(fileURL: deletionFile).memos.map(\.id) == [otherMemo.id],
              "Whole-memo deletion persists after reloading")

        let suite = "DynamicIsland.NotesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IslandModel(playsAlertSound: false, timeToolDefaults: defaults, notes: store)
        let now = Date()
        model.setSessionLocked()
        model.presentUnlockGreeting(at: now)
        check(!model.isSessionUnlocked && model.activeUnlockGreeting == nil, "A locked session rejects greeting previews")
        model.handleSessionUnlock(at: now)
        let greeting = model.activeUnlockGreeting?.id
        check(model.isSessionUnlocked && model.isExpanded && greeting != nil, "Authenticated unlock shows greeting")
        model.handleSessionUnlock(at: now.addingTimeInterval(1))
        check(model.activeUnlockGreeting?.id == greeting, "Duplicate event does not re-present greeting")
        model.setSessionLocked()
        check(model.activeUnlockGreeting == nil && !model.isExpanded, "Lock immediately clears greeting and expansion")
        model.handleSessionUnlock(at: now.addingTimeInterval(3), showsGreeting: false)
        check(model.isSessionUnlocked && model.activeUnlockGreeting == nil, "Disabled greetings still update session privacy")
        model.startTimer()
        model.refreshTimeTools(at: now.addingTimeInterval(3600))
        model.handleSessionUnlock(at: now.addingTimeInterval(6))
        check(model.isTimerFinished && model.activeUnlockGreeting == nil, "Timer completion retains priority")
        model.setSessionLocked()
        model.dismissTimerFinishedAlert()
        check(model.activeUnlockGreeting == nil, "Lock clears queued private greeting")

        var configuration = IslandLengthConfiguration(mode: .expandedTimerSetup, computer: true)
        let base = WindowManager.defaultSize(for: configuration)
        configuration.showsNotes = true
        let withNotes = WindowManager.defaultSize(for: configuration)
        check(withNotes.width <= 1_000 && withNotes.height == base.height + 26 &&
              IslandExpandedLayout(configuration: configuration).groups.flatMap(\.columns).contains(.notes),
              "Notes remain available while overflowing modules reserve a separate footer below their content")
        let hidden = IslandDisplaySettingsSnapshot(hiddenFeatures: [.notes]).filtering(configuration)
        check(!hidden.showsNotes && WindowManager.defaultSize(for: hidden) == base, "Notes setting removes only its own card")
        let exclusive = IslandDisplaySettingsSnapshot().forRecording(isActive: true, showsStatus: true, coexists: false)
        check(!exclusive.filtering(configuration).showsNotes, "Exclusive recording view keeps its priority")
        configuration.mode = .expandedGreeting
        check(WindowManager.defaultSize(for: configuration).height == WindowManager.greetingExpandedSize.height + 100, "Greeting has room for bounded summary")
        print("PASS: \(assertions) notes, persistence, privacy and layout assertions (temporary data only)")
    }
}
