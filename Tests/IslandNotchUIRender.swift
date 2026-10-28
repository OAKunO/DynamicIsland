import AppKit
import SwiftUI

/// Only hidden, app-owned views are rendered. No screen or other app is captured.
@main
struct IslandNotchUIRender {
    struct Capture {
        let bitmap: NSBitmapImageRep
        let notchCenterX: CGFloat
        let frame: CGRect
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let agents = IslandAgentProvider.allCases.map {
            IslandAgentActivity(provider: $0, statuses: [.working, .waiting, .completed, .interrupted])
        }
        let fixtures: [(String, IslandLengthConfiguration)] = [
            ("idle", .init()), ("idle-hovered", .init(mode: .hovered)),
            ("music", .init(music: true)), ("usb", .init(usb: true)),
            ("minutes", .init(timer: .runningMinutes)), ("hours", .init(timer: .pausedHours)),
            ("codex", .init(agents: [.init(provider: .codex, statuses: [.working, .working])])),
            ("codex-usb", .init(agents: [.init(provider: .codex, statuses: [.working, .working])], usb: true)),
            ("waiting", .init(agents: [.init(provider: .claude, statuses: [.waiting])])),
            ("all-tools", .init(agents: agents, music: true, timer: .runningHours,
                battery: .charging, usb: true, pomodoro: .pausedMinutes, enabledAlarmCount: 12,
                recording: .runningHours)),
            ("dashboard", .init(mode: .expandedTimerSetup, agents: agents, music: true,
                expandedTaskCount: 3, phone: true, showsNotes: true, computer: true))
        ]
        var captures: [String: Capture] = [:]
        for (name, configuration) in fixtures {
            let capture = try render(configuration, name: name, output: output)
            try checkExclusion(capture, name: name)
            captures[name] = capture
            if name == "usb" {
                let wide = try render(configuration, name: "usb-wider-shell", output: output, extraWidth: 160)
                try checkExclusion(wide, name: "usb-wider-shell")
                try compareAnchoredRegion(capture, wide, left: -135, right: 165)
            }
        }
        let idle = captures["idle"]!.frame
        let hovered = captures["idle-hovered"]!.frame
        guard abs(hovered.minX - (idle.minX - 20)) < 0.51,
              abs(hovered.maxX - (idle.maxX + 20)) < 0.51,
              hovered.minY == idle.minY, hovered.height == idle.height else {
            throw Failure(message: "Idle hover must extend both outer edges equally at the same height")
        }
        // Adding an outside tool must preserve the already-visible AI contents.
        try compareAnchoredRegion(captures["codex"]!, captures["codex-usb"]!, left: -162, right: 153)
        print("PASS: twelve hidden-view renders; symmetric idle hover; exact content fit plus 14pt margins; asymmetric notch exclusion; stable existing contents across shell growth and added USB")
    }

    @MainActor static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    }

    @MainActor static func render(_ configuration: IslandLengthConfiguration, name: String,
                                   output: URL, extraWidth: CGFloat = 0) throws -> Capture {
        let model = IslandModel(previewConfiguration: configuration, playsAlertSound: false)
        let view = ContentView(model: model, previewConfiguration: configuration)
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true }
            .background(Color.black)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 205, height: 32),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        WindowManager.configure(window: window)
        window.contentView = host
        host.autoresizingMask = [.width, .height]
        host.layoutSubtreeIfNeeded()
        WindowManager.updateForState(configuration: configuration, window: window)
        settle()
        host.layoutSubtreeIfNeeded()
        settle()
        if !configuration.mode.isExpanded {
            guard let content = WindowManager.compactContent(for: configuration),
                  let center = WindowManager.windowNotchCenterX else {
                throw Failure(message: "Missing intrinsic measurement in \(name)")
            }
            let geometry = WindowManager.notchGeometry
            let natural = content.width(geometry: geometry)
            let expected = configuration.mode == .hovered && content.left + content.right == 0
                ? natural + 40 : natural
            guard abs(window.frame.width - expected) < 0.51 else {
                throw Failure(message: "Incorrect shell width in \(name): \(window.frame.width) vs \(expected)")
            }
            if content.left + content.right > 0 {
                let left = center - geometry.protectedWidth / 2 - content.left
                let right = window.frame.width - center - geometry.protectedWidth / 2 - content.right
                // AppKit can round a hidden window's origin by one Retina pixel.
                guard abs(left - 14) < 0.51 && abs(right - 14) < 0.51 else {
                    throw Failure(message: "Incorrect outer margins in \(name): \(left), \(right)")
                }
            }
            if extraWidth > 0 {
                let screen = window.screen!.frame
                let physicalCenter = window.frame.minX + center
                window.setFrame(content.frame(on: screen, geometry: geometry,
                    notchCenterX: physicalCenter, shellWidth: natural + extraWidth), display: false)
                settle()
                host.layoutSubtreeIfNeeded()
            }
            print("\(name): left=\(content.left) right=\(content.right) shell=\(window.frame.width)")
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure(message: "Could not cache \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(message: "Could not save \(name)")
        }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        return Capture(bitmap: bitmap, notchCenterX: WindowManager.windowNotchCenterX!, frame: window.frame)
    }

    static func rgb(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> [CGFloat] {
        let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }

    static func checkExclusion(_ capture: Capture, name: String) throws {
        let bitmap = capture.bitmap
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let middle = Int(capture.notchCenterX * scale)
        let half = Int(WindowManager.notchGeometry.protectedWidth * scale / 2)
        for x in (middle - half + 1)..<(middle + half - 1) {
            for y in 2..<min(Int(WindowManager.notchGeometry.height * scale) - 2, bitmap.pixelsHigh - 2) {
                if rgb(bitmap, x, y).contains(where: { $0 > 0.25 }) {
                    throw Failure(message: "Content entered the protected zone in \(name) at \(x),\(y)")
                }
            }
        }
    }

    static func compareAnchoredRegion(_ first: Capture, _ second: Capture,
                                      left: CGFloat, right: CGFloat) throws {
        let scale = CGFloat(first.bitmap.pixelsWide) / first.bitmap.size.width
        let firstCenter = Int((first.notchCenterX * scale).rounded())
        let secondCenter = Int((second.notchCenterX * scale).rounded())
        var foreground = 0
        var changed = 0
        var checked = 0
        for offset in Int(left * scale)..<Int(right * scale) {
            let x1 = firstCenter + offset, x2 = secondCenter + offset
            guard x1 >= 0, x1 < first.bitmap.pixelsWide, x2 >= 0, x2 < second.bitmap.pixelsWide else { continue }
            for y in 4..<min(first.bitmap.pixelsHigh - 4, second.bitmap.pixelsHigh - 4) {
                let a = rgb(first.bitmap, x1, y), b = rgb(second.bitmap, x2, y)
                if a.max()! > 0.3 { foreground += 1 }
                if zip(a, b).contains(where: { abs($0 - $1) > 0.06 }) { changed += 1 }
                checked += 1
            }
        }
        guard foreground > 50 && changed < max(1, checked / 100) else {
            throw Failure(message: "Existing screen-anchored content moved: \(changed)/\(checked) changed pixels")
        }
        let firstWorldAnchor = first.frame.minX + first.notchCenterX
        let secondWorldAnchor = second.frame.minX + second.notchCenterX
        guard abs(firstWorldAnchor - secondWorldAnchor) < 0.01 else {
            throw Failure(message: "The physical notch anchor moved")
        }
    }

    struct Failure: Error { let message: String }
}
