import AppKit
import SwiftUI

/// App-owned hidden panels and synthetic displays; no screen capture or live monitors.
@main
struct MultiDisplayIntegration {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
        let builtIn = IslandDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   geometry: .init(width: 185, height: 32))
        let external = IslandDisplay(id: 2, frame: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                                    geometry: .init(width: 0, height: 0))
        let fixture = IslandLengthConfiguration(timer: .runningMinutes)
        let model = IslandModel(previewConfiguration: fixture, playsAlertSound: false)
        let sources = IslandActivitySources(previewConfiguration: fixture)
        let suite = "DynamicIsland.MultiDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let displaySettings = IslandDisplaySettings(defaults: defaults)
        let controller = IslandDisplayController(model: model, sources: sources, displaySettings: displaySettings)
        defer { controller.stop() }
        controller.reconcile(displays: [builtIn, external], showWindows: false)
        settle()
        check(controller.panels.count == 2 && WindowManager.windows.count == 2,
              "Each connected display receives exactly one panel")
        check(controller.model === model && controller.sources === sources,
              "Every display uses the same model and activity monitors")
        let first = controller.panels[1]!
        let second = controller.panels[2]!
        let firstInteraction = WindowManager.layout(for: first)!.interaction
        let secondInteraction = WindowManager.layout(for: second)!.interaction
        check(WindowManager.layout(for: first)!.metrics.geometry == builtIn.geometry &&
              WindowManager.layout(for: second)!.metrics.geometry == external.islandGeometry,
              "The external screen reserves a visual center without claiming a physical notch")
        check(first.frame.maxY == builtIn.frame.maxY && second.frame.maxY == external.frame.maxY,
              "Panels attach to their own display's top edge, including negative origins")
        check(abs(first.frame.width - second.frame.width) < 0.51 && external.islandGeometry.protectedWidth == 205,
              "External compact contents include the same 205-point black center")
        let compactBitmap = capture(second)
        try save(compactBitmap, named: "external-compact")
        let metrics = WindowManager.layout(for: second)!.metrics
        let scale = CGFloat(compactBitmap.pixelsWide) / compactBitmap.size.width
        let center = metrics.notchCenterX!
        var blackCenter = true
        for x in Int((center - 100) * scale)..<Int((center + 100) * scale) {
            for y in 2..<compactBitmap.pixelsHigh - 2 {
                let color = compactBitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.10 { blackCenter = false }
            }
        }
        check(blackCenter, "The external center contains only black pixels, with no text or icons")
        for (panel, display) in [(first, builtIn), (second, external)] {
            let metrics = WindowManager.layout(for: panel)!.metrics
            check(abs(panel.frame.minX + metrics.notchCenterX! - display.notchCenterX) < 0.01,
                  "Each compact view is anchored to its assigned physical center")
        }
        controller.reconcile(displays: [builtIn, external, external], showWindows: false)
        check(controller.panels.count == 2 && controller.panels[1] === first && controller.panels[2] === second,
              "Repeated notifications preserve panel identity without duplicates")

        secondInteraction.isExpanded = true
        settle()
        check(first.frame.height == 32 && second.frame.height >= 256,
              "Opening the external island leaves the main island compact")
        try save(capture(second), named: "external-expanded")
        sources.audioPlayback.isExpanded = true
        sources.codexStatus.isExpanded = true
        settle()
        check(first.frame.height == 32,
              "Shared music and agent presentation flags cannot expand another screen")
        sources.audioPlayback.isExpanded = false
        sources.codexStatus.isExpanded = false
        firstInteraction.isExpanded = true
        secondInteraction.collapse()
        settle()
        check(first.frame.height >= 256 && second.frame.height == 32,
              "Closing the external island preserves the expanded main island")
        firstInteraction.isPomodoroSettingsPresented = true
        secondInteraction.isRecordingSettingsPresented = true
        secondInteraction.collapse()
        check(firstInteraction.isPomodoroSettingsPresented && !secondInteraction.isRecordingSettingsPresented,
              "Panel settings and collapse cleanup stay local")
        firstInteraction.isHovered = false
        secondInteraction.isHovered = true
        check(!firstInteraction.isHovered, "Hover feedback is independent on each screen")
        secondInteraction.isExpanded = true
        settle()
        let portrait = IslandDisplay(id: 2, frame: CGRect(x: 1512, y: 982, width: 800, height: 1280),
                                    geometry: .init(width: 0, height: 0))
        controller.reconcile(displays: [builtIn, portrait], showWindows: false)
        settle()
        check(controller.panels[2] === second && second.frame.maxY == portrait.frame.maxY &&
              second.frame.midX == portrait.frame.midX,
              "Rearrangement and rotation reposition the existing panel on its own display")
        check(second.frame.width <= WindowManager.expandedWidthLimit(screenWidth: portrait.frame.width),
              "Expanded contents fit a narrower secondary display")
        check(WindowManager.layout(for: second)!.metrics.screenWidth == 800 &&
              WindowManager.layout(for: first)!.metrics.screenWidth == 1512,
              "Width budgets remain independent after a scale or arrangement change")

        let frameBeforeUnplug = first.frame
        controller.reconcile(displays: [builtIn], showWindows: false)
        settle()
        check(controller.panels.count == 1 && WindowManager.windows.count == 1 &&
              WindowManager.layout(for: second) == nil,
              "Unplugging removes the orphaned panel and its observers")
        check(first.frame == frameBeforeUnplug && firstInteraction.isExpanded,
              "Unplugging preserves the other panel and its presentation state")
        controller.reconcile(displays: [builtIn, external], showWindows: false)
        settle()
        check(controller.panels.count == 2 && controller.panels[1] === first && controller.panels[2] !== second,
              "Reconnecting creates only the missing panel")
        check(controller.panels[2]!.frame.height == 32 && first.frame.height >= 256,
              "A reconnected display starts compact without copying another panel's expansion")
        let reconnectedInteraction = WindowManager.layout(for: controller.panels[2]!)!.interaction
        let timerBeforePause = model.timeRemaining
        model.togglePause()
        settle()
        check(model.isTimerPaused && model.timeRemaining == timerBeforePause &&
              controller.model === model && firstInteraction.isExpanded,
              "Shared timer changes preserve each display's independent presentation")
        reconnectedInteraction.isExpanded = true
        settle()
        model.setSessionLocked()
        settle()
        check(!controller.model.isSessionUnlocked && !firstInteraction.isExpanded && !reconnectedInteraction.isExpanded,
              "Session locking hides content and clears all panel interaction states")
        controller.reconcile(displays: [], showWindows: false)
        check(WindowManager.windows.isEmpty && controller.panels.isEmpty,
              "Transient empty display lists safely remove all panels")
        controller.reconcile(displays: [external], showWindows: false)
        settle()
        check(controller.panels.count == 1 && WindowManager.notchGeometry == external.islandGeometry,
              "A returning desktop replaces stale primary geometry")
        controller.stop()
        check(WindowManager.windows.isEmpty, "Shutdown releases every panel")

        model.handleSessionUnlock(showsGreeting: false)
        controller.reconcile(displays: [builtIn, external], showWindows: false)
        settle()
        let retainedPrimary = controller.panels[1]!
        let retainedInteraction = WindowManager.layout(for: retainedPrimary)!.interaction
        retainedInteraction.isExpanded = true
        settle()
        let timerState = model.isTimerPaused
        displaySettings.setEnabled(false, for: .secondaryDisplays)
        settle()
        check(controller.panels.count == 1 && controller.panels[1] === retainedPrimary,
              "Disabling secondary islands immediately removes only the secondary panel")
        check(retainedInteraction.isExpanded && model.isTimerPaused == timerState,
              "The switch preserves the primary panel's presentation and running tool data")
        controller.reconcile(displays: [builtIn, external], showWindows: false)
        check(controller.panels.count == 1,
              "Screen changes cannot recreate secondary islands while the preference is disabled")
        controller.reconcile(displays: [external, builtIn], showWindows: false)
        check(controller.panels.count == 1 && controller.panels[2] != nil,
              "Primary-only mode follows a system primary-screen change")
        controller.reconcile(displays: [builtIn, external], showWindows: false)
        let primaryBeforeEnable = controller.panels[1]!
        displaySettings.setEnabled(true, for: .secondaryDisplays)
        settle()
        check(controller.panels.count == 2 && controller.panels[1] === primaryBeforeEnable &&
              controller.panels[2]!.frame.height == 32,
              "Re-enabling adds the secondary island without replacing the primary")
        displaySettings.setEnabled(false, for: .secondaryDisplays)
        settle()
        let restoredSettings = IslandDisplaySettings(defaults: defaults)
        check(!restoredSettings.snapshot.isEnabled(.secondaryDisplays), "The disabled preference survives relaunch")
        controller.stop()
        let relaunched = IslandDisplayController(model: model, sources: sources, displaySettings: restoredSettings)
        relaunched.reconcile(displays: [builtIn, external], showWindows: false)
        settle()
        check(relaunched.panels.count == 1 && relaunched.panels[1] != nil,
              "A relaunched controller respects the saved primary-only preference")
        relaunched.stop()
        let settingsPanel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 760),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        settingsPanel.isReleasedWhenClosed = false
        settingsPanel.contentView = NSHostingView(rootView: IslandSettingsView(
            lengthSettings: IslandLengthSettings(defaults: defaults), displaySettings: displaySettings, initialPage: .functions))
        try save(capture(settingsPanel), named: "secondary-display-settings")
        settingsPanel.close()

        let ownerA = UUID(), ownerB = UUID()
        sources.setMusicPageVisible(true, owner: ownerA)
        sources.setMusicPageVisible(true, owner: ownerB)
        check(sources.audioPlayback.isExpanded, "Music visibility is shared across displays")
        sources.setMusicPageVisible(false, owner: ownerA)
        check(sources.audioPlayback.isExpanded, "Removing one music page preserves the remaining page")
        sources.setMusicPageVisible(false, owner: ownerB)
        check(!sources.audioPlayback.isExpanded, "The final music page releases shared lyrics state")
        print("PASS: \(assertions) multi-display lifecycle, shared-state and per-screen geometry assertions")
    }

    @MainActor static func capture(_ panel: NSPanel) -> NSBitmapImageRep {
        RunLoop.main.run(until: Date().addingTimeInterval(0.75))
        let host = panel.contentView!
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, named name: String) throws {
        guard CommandLine.arguments.count > 1 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
