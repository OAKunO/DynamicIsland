import AppKit
import ScreenCaptureKit
import SwiftUI

enum RecordingTarget {
    case display(SCDisplay, region: CGRect?)
    case window(SCWindow)
}

@MainActor
final class RecordingTargetSelector: NSObject, NSWindowDelegate {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<RecordingTarget?, Never>?

    func select(source: RecordingSource, content: SCShareableContent) async -> RecordingTarget? {
        if source == .screen, content.displays.count == 1, let display = content.displays.first {
            return .display(display, region: nil)
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if source == .region { presentRegionSelection(displays: content.displays) }
            else { presentList(source: source, content: content) }
        }
    }

    func cancel() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ target: RecordingTarget?) {
        guard let continuation else { return }
        self.continuation = nil
        for window in windows {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        continuation.resume(returning: target)
    }

    private func presentList(source: RecordingSource, content: SCShareableContent) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = source == .screen ? "选择录制屏幕" : "选择录制窗口"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let choices: [RecordingTargetChoice]
        if source == .screen {
            choices = content.displays.map { display in
                let screen = NSScreen.screens.first { $0.recordingDisplayID == display.displayID }
                return .init(id: display.displayID,
                             title: screen?.localizedName ?? "屏幕 \(display.displayID)",
                             detail: "\(display.width) × \(display.height)",
                             target: .display(display, region: nil))
            }
        } else {
            choices = content.windows.filter {
                $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1
                    && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
                    && !($0.title ?? "").isEmpty
            }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
                .map { .init(id: $0.windowID, title: $0.title ?? "窗口",
                             detail: $0.owningApplication?.applicationName ?? "",
                             target: .window($0)) }
        }
        panel.contentView = NSHostingView(rootView: RecordingTargetList(choices: choices) { [weak self] target in
            self?.finish(target)
        })
        windows = [panel]
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func presentRegionSelection(displays: [SCDisplay]) {
        for screen in NSScreen.screens {
            guard let display = displays.first(where: { $0.displayID == screen.recordingDisplayID }) else { continue }
            let panel = RegionSelectionPanel(contentRect: screen.frame, styleMask: [.borderless],
                                             backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size)) { [weak self] rect in
                guard let rect else { self?.finish(nil); return }
                // AppKit starts at the bottom-left; ScreenCaptureKit starts at the top-left.
                let source = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY,
                                    width: rect.width, height: rect.height)
                self?.finish(.display(display, region: source))
            }
            panel.contentView = view
            windows.append(panel)
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
        }
        guard let first = windows.first else { finish(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        first.makeKey()
    }
}

extension NSScreen {
    var recordingDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private struct RecordingTargetChoice: Identifiable {
    let id: UInt32
    let title: String
    let detail: String
    let target: RecordingTarget
}

private struct RecordingTargetList: View {
    let choices: [RecordingTargetChoice]
    let finish: (RecordingTarget?) -> Void
    @State private var selection: UInt32?

    var body: some View {
        VStack(spacing: 16) {
            if choices.isEmpty {
                Text("没有可录制的窗口，请先打开目标窗口。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(choices, selection: $selection) { choice in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(choice.title).lineLimit(1)
                        Text(choice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .tag(choice.id)
                }
                .onAppear { selection = choices.first?.id }
            }
            HStack {
                Spacer()
                Button("取消") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("开始录制") { finish(choices.first { $0.id == selection }?.target) }
                    .keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }
        .padding(20)
    }
}

private final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class RegionSelectionView: NSView {
    private var origin: CGPoint?
    private var selection: CGRect = .zero
    private let finish: (CGRect?) -> Void
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: NSRect, finish: @escaping (CGRect?) -> Void) {
        self.finish = finish
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        origin = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                           width: abs(point.x - origin.x), height: abs(point.y - origin.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if selection.width >= 16 && selection.height >= 16 { finish(selection) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.42).setFill()
        let dim = NSBezierPath(rect: bounds)
        if !selection.isEmpty { dim.appendRect(selection) }
        dim.windingRule = .evenOdd
        dim.fill()
        if !selection.isEmpty {
            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
        }
        let instruction = "拖动选择录屏区域 · Esc 取消" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .medium),
                                                        .foregroundColor: NSColor.white]
        let size = instruction.size(withAttributes: attributes)
        instruction.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 90),
                         withAttributes: attributes)
    }
}
