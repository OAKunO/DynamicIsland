import SwiftUI
import AppKit

@main
struct NotesUIRender {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/DynamicIslandNotesUI")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = NotesStore()
        let note = IslandMemo(text: "今天的小计划\n把想法记下来，再慢慢完成。这里是一段很长的备忘录正文，用来确认在卡片里会自然截断，打开后依然可以阅读全文。", tasks: [MemoTask(text: "整理一下桌面"), MemoTask(text: "写下明天要做的第一件事"), MemoTask(text: "喝一杯水", isCompleted: true)], isPinned: true)
        store.save(note)
        store.save(IslandMemo(text: "周末想看的电影", isPinned: true))
        let configuration = IslandLengthConfiguration(mode: .expandedTimerSetup, showsNotes: true)
        let model = IslandModel(previewConfiguration: configuration, playsAlertSound: false, notes: store)
        let expandedSize = WindowManager.defaultSize(for: configuration)
        try capture(ContentView(model: model, previewConfiguration: configuration), size: expandedSize, name: "expanded", output: output)
        try capture(NotesCard(store: NotesStore(), model: model), size: CGSize(width: WindowManager.notesColumnWidth, height: expandedSize.height), name: "empty", output: output)
        let greeting = IslandLengthConfiguration(mode: .expandedGreeting, showsNotes: true)
        let greetingModel = IslandModel(previewConfiguration: greeting, playsAlertSound: false, notes: store)
        try capture(ContentView(model: greetingModel, previewConfiguration: greeting), size: CGSize(width: 424, height: 284), name: "greeting", output: output)
        try capture(MemoEditor(store: store, model: model, draft: note, original: note, close: {}), size: CGSize(width: 520, height: 560), name: "editor", output: output)
        let completionStore = NotesStore()
        let completionMemo = IslandMemo(text: "完成后先留在这里", tasks: [
            MemoTask(text: "整理一下桌面"), MemoTask(text: "喝一杯水", isCompleted: true)
        ])
        completionStore.save(completionMemo)
        var cardSession = NotesCardSession()
        cardSession.toggleTask(memoID: completionMemo.id, taskID: completionMemo.tasks[0].id, in: completionStore)
        let cardSize = CGSize(width: WindowManager.notesColumnWidth, height: expandedSize.height)
        try capture(NotesCard(store: completionStore, model: model, session: cardSession), size: cardSize,
                    name: "completion-retained", output: output)
        try capture(NotesCard(store: completionStore, model: model), size: cardSize,
                    name: "completion-reopened", output: output)
        model.setSessionLocked()
        try capture(ContentView(model: model, previewConfiguration: configuration), size: expandedSize, name: "locked", output: output)
        print("PASS: rendered expanded notes, empty state, greeting summary and simulated locked UI using memory-only fixtures")
    }

    @MainActor static func capture<V: View>(_ view: V, size: CGSize, name: String, output: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).background(Color.black))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try data.write(to: output.appendingPathComponent("\(name).png"))
        window.close()
    }
}
