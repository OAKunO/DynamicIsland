import SwiftUI
import AppKit

@main
struct ExpandedPagingUIRender {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let all = IslandLengthConfiguration(mode: .expandedTimerSetup,
            agents: [.init(provider: .codex, statuses: [.working])], music: true,
            timer: .runningMinutes, battery: .charging, usb: true, expandedTaskCount: 1,
            phone: true, showsNotes: true, computer: true)
        let store = NotesStore()
        let memo = IslandMemo(text: "分页后也能保留待办状态", tasks: [MemoTask(text: "切换后仍显示划线")], isPinned: true)
        store.save(memo)
        let model = IslandModel(previewConfiguration: all, playsAlertSound: false, notes: store)
        let allHost = NSHostingView(rootView: ContentView(model: model, previewConfiguration: all)
            .environment(\.colorScheme, .dark).background(Color.black))
        let allWindow = makeWindow(host: allHost, size: WindowManager.defaultSize(for: all))
        allWindow.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        settle()
        try snapshot(allHost, name: "all-modules", output: output)
        click(allWindow, x: 153, y: 16) // Recording in the narrow group.
        click(allWindow, x: 497, y: 16) // Time in the wide group.
        try snapshot(allHost, name: "time-and-recording", output: output)
        click(allWindow, x: 103, y: 16) // Phone.
        click(allWindow, x: 387, y: 16) // Music.
        try snapshot(allHost, name: "music-and-phone", output: output)
        allWindow.close()

        var threeTasks = all
        threeTasks.agents = [.init(provider: .codex, statuses: [.working, .working, .completed])]
        threeTasks.expandedTaskCount = 3
        let threeTasksModel = IslandModel(previewConfiguration: threeTasks, playsAlertSound: false, notes: store)
        try capture(ContentView(model: threeTasksModel, previewConfiguration: threeTasks),
                    size: WindowManager.defaultSize(for: threeTasks), name: "workspace-three-tasks", output: output)

        // Reproduce the reported collision with the timer's predicted end time.
        var setup = all
        setup.timer = .off
        let setupModel = IslandModel(previewConfiguration: setup, playsAlertSound: false, notes: store)
        let setupHost = NSHostingView(rootView: ContentView(model: setupModel, previewConfiguration: setup)
            .environment(\.colorScheme, .dark).background(Color.black))
        let setupWindow = makeWindow(host: setupHost, size: WindowManager.defaultSize(for: setup))
        setupWindow.makeKeyAndOrderFront(nil)
        settle()
        click(setupWindow, x: 497, y: 16)
        try snapshot(setupHost, name: "timer-setup-footer", output: output)
        setupWindow.close()

        let timeAndNotes = IslandLengthConfiguration(mode: .expandedTimerSetup, showsNotes: true, computer: true)
        let secondModel = IslandModel(previewConfiguration: timeAndNotes, playsAlertSound: false, notes: store)
        try capture(ContentView(model: secondModel, previewConfiguration: timeAndNotes),
                    size: WindowManager.defaultSize(for: timeAndNotes), name: "grouped-tools", output: output)

        let pageGroup = IslandExpandedLayout.Group(columns: [.time, .notes])
        var contentViews: [IslandExpandedColumn: NSView] = [:]
        let pageView = ExpandedIslandGroup(group: pageGroup, width: 344, model: model) { column, height in
            Group {
                if column == .notes { NotesCard(store: store, model: model) }
                else { Text("计时页面").foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(height: height)
                .background(PagingContentProbe { contentViews[column] = $0 })
        }
        let host = NSHostingView(rootView: pageView.environment(\.colorScheme, .dark).background(Color.black))
        let window = makeWindow(host: host, size: CGSize(width: 344, height: 282))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        settle()
        guard contentViews.count == 2 else { fatalError("Page content probes are missing") }
        for view in contentViews.values {
            let frame = view.convert(view.bounds, to: host)
            let footerStart = host.isFlipped ? frame.maxY : host.bounds.height - frame.minY
            guard abs(frame.height - 256) < 0.5, footerStart <= 256.5 else {
                fatalError("Page content overlaps its footer or lost its original height")
            }
        }
        click(window, x: 243, y: 16) // Notes tab in the production footer.
        try snapshot(host, name: "notes-open", output: output)
        click(window, x: 37, y: 181) // Completion control in the first memo row.
        guard store.unfinishedCount == 0 else { fatalError("Task was not completed through its button") }
        try snapshot(host, name: "notes-completed", output: output)
        click(window, x: 101, y: 16) // Time tab.
        click(window, x: 243, y: 16) // Back to Notes.
        click(window, x: 37, y: 181) // Retained completed row must still accept undo.
        guard store.unfinishedCount == 1 else { fatalError("Paging discarded the note card's retained completion") }
        click(window, x: 37, y: 181)
        try snapshot(host, name: "notes-after-switching", output: output)
        click(window, x: 304, y: 206) // Whole-memo trash button.
        guard store.memos.count == 1 else { fatalError("Whole memo deletion did not wait for confirmation") }
        try snapshot(host, name: "notes-delete-confirmation", output: output)
        click(window, x: 296, y: 175) // Inline confirmation.
        guard store.memos.isEmpty else { fatalError("Inline confirmation did not delete the memo") }
        print("PASS: separate footer geometry, timer setup rendering, page switching, completion retention and confirmed deletion (memory-only fixtures)")
    }

    @MainActor static func click(_ window: NSWindow, x: CGFloat, y: CGFloat) {
        let host = window.contentView!
        let location = host.convert(NSPoint(x: x, y: host.isFlipped ? host.bounds.height - y : y), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                fatalError("Could not construct local mouse event")
            }
            NSApp.postEvent(event, atStart: false)
        }
        settle()
    }

    @MainActor static func settle() {
        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor static func makeWindow(host: NSView, size: CGSize) -> NSWindow {
        let window = PagingTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor static func capture<V: View>(_ view: V, size: CGSize, name: String, output: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).background(Color.black))
        let window = makeWindow(host: host, size: size)
        settle()
        try snapshot(host, name: name, output: output)
        window.close()
    }

    @MainActor static func snapshot(_ host: NSView, name: String, output: URL) throws {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try data.write(to: output.appendingPathComponent("\(name).png"))
    }
}

private final class PagingTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct PagingContentProbe: NSViewRepresentable {
    let record: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        record(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { record(view) }
}
