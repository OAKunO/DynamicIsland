import AppKit
import SwiftUI
import QuartzCore

/// An ordinary window that stays available when the island itself collapses.
@MainActor
final class IslandSettingsWindow: NSObject, NSWindowDelegate {
    private static let shared = IslandSettingsWindow()
    private var window: NSWindow?
    private var themeOverlay: ThemeTransitionOverlay?

    static var themeTransitionDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.45
    }

    static func show(page: IslandSettingsPage = .home) {
        shared.present(page: page)
    }

    static func transitionTheme(to isLightTheme: Bool, updates: () -> Void) {
        shared.applyThemeTransition(to: isLightTheme, updates: updates)
    }

    func windowWillClose(_ notification: Notification) {
        themeOverlay?.removeFromSuperview()
        themeOverlay = nil
        IslandLengthSettings.shared.endPreview()
    }

    private func applyThemeTransition(to isLightTheme: Bool, updates: () -> Void) {
        // Capture before changing SwiftUI state or native control appearance.
        // AppKit owns the title bar and traffic lights. Snapshot only the page:
        // caching the native frame can paint its title over the window buttons.
        let surface = window?.contentView
        var snapshot: NSImage?
        if let surface, window?.isVisible == true,
           let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) {
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            let image = NSImage(size: surface.bounds.size)
            image.addRepresentation(bitmap)
            snapshot = image
        }
        themeOverlay?.removeFromSuperview()
        themeOverlay = nil
        if let surface, let snapshot {
            let overlay = ThemeTransitionOverlay(frame: surface.bounds)
            overlay.image = snapshot
            overlay.imageScaling = .scaleAxesIndependently
            overlay.autoresizingMask = [.width, .height]
            surface.wantsLayer = true
            surface.layer?.masksToBounds = true
            surface.addSubview(overlay, positioned: .above, relativeTo: nil)
            themeOverlay = overlay
        }

        window?.appearance = NSAppearance(named: isLightTheme ? .aqua : .darkAqua)
        updates()

        // Let SwiftUI apply the new palette underneath the previous frame.
        guard let overlay = themeOverlay else { return }
        DispatchQueue.main.async { [weak self, weak overlay] in
            guard let self, let overlay, self.themeOverlay === overlay else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.themeTransitionDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                overlay.animator().alphaValue = 0
            } completionHandler: { [weak self, weak overlay] in
                DispatchQueue.main.async { [weak self, weak overlay] in
                    overlay?.removeFromSuperview()
                    if self?.themeOverlay === overlay { self?.themeOverlay = nil }
                }
            }
        }
    }

    private final class ThemeTransitionOverlay: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private func present(page: IslandSettingsPage) {
        if window == nil {
            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            settingsWindow.delegate = self
            settingsWindow.title = "灵动岛设置"
            settingsWindow.titleVisibility = .hidden
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentMinSize = NSSize(width: 860, height: 680)
            settingsWindow.center()
            settingsWindow.setFrameAutosaveName("IslandSettingsWindow.v2")
            window = settingsWindow
        }

        IslandLengthSettings.shared.endPreview()
        themeOverlay?.removeFromSuperview()
        themeOverlay = nil
        window?.contentView = NSHostingView(
            rootView: IslandSettingsView(lengthSettings: .shared, initialPage: page)
        )
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsWindowAppearance: NSViewRepresentable {
    let isLightTheme: Bool

    func makeNSView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.isLightTheme = isLightTheme
        return view
    }

    func updateNSView(_ view: AppearanceView, context: Context) {
        view.isLightTheme = isLightTheme
    }

    final class AppearanceView: NSView {
        var isLightTheme = false {
            didSet { updateAppearance() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateAppearance()
        }

        private func updateAppearance() {
            let name: NSAppearance.Name = isLightTheme ? .aqua : .darkAqua
            guard window?.appearance?.name != name else { return }
            window?.appearance = NSAppearance(named: name)
        }
    }
}
