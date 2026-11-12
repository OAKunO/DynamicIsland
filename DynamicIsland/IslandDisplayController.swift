import AppKit
import SwiftUI
import Combine

// Keep clicks nonactivating while allowing native text fields to accept focus.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Panels share content and monitors, with independent presentation per desktop.
final class IslandDisplayController {
    private(set) var panels: [CGDirectDisplayID: NSPanel] = [:]
    let model: IslandModel
    let sources: IslandActivitySources
    private let displaySettings: IslandDisplaySettings
    private var screenObserver: NSObjectProtocol?
    private var settingsObserver: AnyCancellable?
    private var connectedDisplays: [IslandDisplay] = []
    private var showsSecondaryDisplays: Bool
    private var shouldShowWindows = true

    init(model: IslandModel, sources: IslandActivitySources? = nil, displaySettings: IslandDisplaySettings = .shared) {
        self.model = model
        self.sources = sources ?? IslandActivitySources()
        self.displaySettings = displaySettings
        showsSecondaryDisplays = displaySettings.snapshot.isEnabled(.secondaryDisplays)
        settingsObserver = displaySettings.$snapshot.map { $0.isEnabled(.secondaryDisplays) }
            .removeDuplicates().dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                showsSecondaryDisplays = enabled
                if screenObserver != nil { refreshScreens() }
                else { reconcile(displays: connectedDisplays, showWindows: shouldShowWindows) }
            }
    }

    func start() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreens() }
        }
        refreshScreens()
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for panel in panels.values {
            WindowManager.unregister(window: panel)
            panel.close()
            panel.contentView = nil
        }
        panels.removeAll()
        connectedDisplays.removeAll()
    }

    private func refreshScreens() {
        reconcile(displays: NSScreen.screens.map(IslandDisplay.init(screen:)))
    }

    func reconcile(displays: [IslandDisplay], showWindows: Bool = true) {
        connectedDisplays = displays
        shouldShowWindows = showWindows
        // The first NSScreen is the system primary, independent of keyboard focus.
        let displays = showsSecondaryDisplays ? displays : Array(displays.prefix(1))
        let connectedIDs = Set(displays.map(\.id))
        for id in Array(panels.keys) where !connectedIDs.contains(id) {
            guard let panel = panels.removeValue(forKey: id) else { continue }
            WindowManager.unregister(window: panel)
            panel.close()
            panel.contentView = nil
        }
        // NSScreen exposes desktops, so hardware mirroring doesn't add another
        // overlay to the same desktop. Keying by display ID also makes repeats safe.
        for display in displays {
            if let panel = panels[display.id] {
                WindowManager.updateDisplay(display, for: panel)
                continue
            }
            let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.title = "DynamicIsland — \(display.id)"
            guard let layout = WindowManager.configure(window: panel, display: display) else { continue }
            panel.contentView = NSHostingView(rootView: ContentView(model: model, displaySettings: displaySettings,
                sources: sources, windowLayout: layout))
            panels[display.id] = panel
        }
        if showWindows { WindowManager.refreshVisibility() }
    }
}
