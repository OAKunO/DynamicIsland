import SwiftUI
import AppKit

struct NotesCard: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var model: IslandModel
    @State private var showsAll = false
    @State private var expandedCompleted: Set<UUID> = []
    @State private var memoPendingDeletion: IslandMemo?
    // The dashboard removes this card on collapse, starting a fresh session next time.
    @State private var session: NotesCardSession

    init(store: NotesStore, model: IslandModel, session: NotesCardSession = NotesCardSession()) {
        self.store = store
        self.model = model
        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("备忘录", systemImage: "note.text").font(.system(size: 13, weight: .semibold))
                Text("\(store.unfinishedCount) 项待办").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(showsAll ? "置顶与待办" : "全部 \(store.memos.count)") { showsAll.toggle() }
                Button { NotesWindow.show(store: store, model: model) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建备忘录")
            }
            .buttonStyle(.plain)
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            let memos = session.memos(in: store, showsAll: showsAll)
            if memos.isEmpty {
                VStack(spacing: 7) {
                    Text(store.memos.isEmpty ? "记下一点想法，或添加一件待办" : "暂无置顶备忘录与未完成待办")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(store.memos.isEmpty ? "新建备忘录" : "查看全部备忘录") {
                        if store.memos.isEmpty { NotesWindow.show(store: store, model: model) }
                        else { showsAll = true }
                    }.buttonStyle(.plain).foregroundStyle(.yellow)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(memos) { memo in memoRow(memo) }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 14)
        .background(Color.white.opacity(0.035))
    }

    private func memoRow(_ memo: IslandMemo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Button { NotesWindow.show(store: store, model: model, memo: memo) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(memo.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !memo.bodyPreview.isEmpty {
                            Text(memo.bodyPreview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("打开完整备忘录：\(memo.title)")
                Button { store.togglePin(memo.id) } label: {
                    Image(systemName: memo.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(memo.isPinned ? .yellow : .gray)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(memo.isPinned ? "取消置顶" : "置顶")
                Button(role: .destructive) { memoPendingDeletion = memo } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.gray)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("删除整条备忘录及其中的待办")
                    .accessibilityLabel("删除备忘录：\(memo.title)")
            }
            // Keep confirmation inside the island so its hover timer cannot dismiss a popover.
            if memoPendingDeletion?.id == memo.id {
                HStack(spacing: 8) {
                    Text("删除整条备忘录？").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("取消") { memoPendingDeletion = nil }
                    Button("删除", role: .destructive) {
                        if store.delete(memo.id) {
                            memoPendingDeletion = nil
                            expandedCompleted.remove(memo.id)
                        }
                    }.foregroundStyle(.red).accessibilityLabel("确认删除备忘录及其中的待办：\(memo.title)")
                }.font(.system(size: 10)).buttonStyle(.plain)
                    .padding(8).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(session.visibleTasks(in: memo)) { task in taskRow(task, memo: memo) }
            let completed = session.completedTasks(in: memo)
            if !completed.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedCompleted.contains(memo.id) },
                    set: { if $0 { expandedCompleted.insert(memo.id) } else { expandedCompleted.remove(memo.id) } }
                )) {
                    ForEach(completed) { task in taskRow(task, memo: memo) }
                } label: {
                    Text("已完成 \(completed.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                }.tint(.gray)
            }
        }
        .padding(10).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private func taskRow(_ task: MemoTask, memo: IslandMemo) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Button { session.toggleTask(memoID: memo.id, taskID: task.id, in: store) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? .gray : .yellow)
            }.buttonStyle(.plain).accessibilityLabel(task.isCompleted ? "撤销完成：\(task.text)" : "完成：\(task.text)")
            Button { NotesWindow.show(store: store, model: model, memo: memo) } label: {
                Text(task.text).font(.system(size: 11)).lineLimit(2)
                    .strikethrough(task.isCompleted).foregroundStyle(task.isCompleted ? .gray : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button(role: .destructive) { store.deleteTask(memoID: memo.id, taskID: task.id) } label: {
                Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.gray)
                    .frame(width: 20, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).help("删除这项待办")
                .accessibilityLabel("删除待办：\(task.text)")
        }
    }
}

struct UnlockNotesSummary: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var model: IslandModel

    var body: some View {
        if !store.unlockMemos.isEmpty && model.isSessionUnlocked {
            VStack(alignment: .leading, spacing: 7) {
                Text("备忘录 · \(store.unfinishedCount) 项待办").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(store.unlockMemos) { memo in
                    Button {
                        NotesWindow.show(store: store, model: model, memo: memo)
                        model.dismissUnlockGreeting()
                    } label: {
                        Label(memo.summary(), systemImage: memo.isPinned ? "pin.fill" : "circle")
                            .font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
            .padding(12).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Separate editor keeps typing independent of the island's hover/collapse timer.
enum NotesWindow {
    private static var windows: [UUID: NSWindow] = [:]
    private static let newMemoWindowID = UUID()

    static func show(store: NotesStore, model: IslandModel, memo: IslandMemo? = nil) {
        guard model.isSessionUnlocked else { return }
        let id = memo?.id ?? newMemoWindowID
        if let window = windows[id] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "备忘录"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 400)
        window.contentView = NSHostingView(rootView: MemoEditor(store: store, model: model, draft: memo ?? IslandMemo(), original: memo) {
            windows.removeValue(forKey: id)
            window.close()
        })
        windows[id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hideForLock() {
        // Retain unsaved drafts in memory; they can be reopened after unlocking.
        for window in windows.values { window.orderOut(nil) }
    }
}

struct MemoEditor: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var model: IslandModel
    @State var draft: IslandMemo
    var original: IslandMemo?
    let close: () -> Void
    @State private var confirmsDelete = false
    @State private var completedExpanded = false

    var body: some View {
        Group {
            if model.isSessionUnlocked {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("备忘录与待办", systemImage: "note.text").font(.headline)
                        Spacer()
                        Toggle("置顶", isOn: $draft.isPinned).toggleStyle(.checkbox)
                    }
                    TextEditor(text: $draft.text).font(.body).frame(minHeight: 150)
                        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("备忘录正文")
                    HStack {
                        Text("待办").font(.headline)
                        Spacer()
                        Button("添加待办", systemImage: "plus") { draft.tasks.append(MemoTask(text: "")) }
                    }
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach($draft.tasks) { $task in
                                if !task.isCompleted { editorTask($task) }
                            }
                            if draft.tasks.contains(where: \.isCompleted) {
                                DisclosureGroup("已完成", isExpanded: $completedExpanded) {
                                    ForEach($draft.tasks) { $task in
                                        if task.isCompleted { editorTask($task) }
                                    }
                                }
                            }
                        }
                    }.frame(minHeight: 80)
                    if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        if store.memos.contains(where: { $0.id == draft.id }) {
                            Button("删除备忘录", role: .destructive) { confirmsDelete = true }
                        }
                        Spacer()
                        Button("取消", action: close).keyboardShortcut(.cancelAction)
                        Button("保存") {
                            var saved = draft
                            saved.tasks = saved.tasks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            if store.saveEdits(saved, original: original) { close() }
                        }.keyboardShortcut("s", modifiers: .command).disabled(!hasContent)
                    }
                }.padding(20)
            } else {
                Text("解锁后查看备忘录").foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("删除这条备忘录及其中的待办？", isPresented: $confirmsDelete) {
            Button("删除备忘录", role: .destructive) { if store.delete(draft.id) { close() } }
            Button("取消", role: .cancel) {}
        }
    }

    private var hasContent: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            draft.tasks.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func editorTask(_ task: Binding<MemoTask>) -> some View {
        HStack {
            Toggle("完成", isOn: task.isCompleted).labelsHidden().toggleStyle(.checkbox)
                .accessibilityLabel(task.wrappedValue.isCompleted ? "撤销完成" : "标记完成")
            TextField("待办内容", text: task.text, axis: .vertical)
                .strikethrough(task.wrappedValue.isCompleted)
            Button(role: .destructive) { draft.tasks.removeAll { $0.id == task.wrappedValue.id } } label: {
                Image(systemName: "trash")
            }.buttonStyle(.plain).help("删除这项待办，保存后生效").accessibilityLabel("删除这项待办")
        }
    }
}
