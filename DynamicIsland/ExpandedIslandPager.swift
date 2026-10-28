import SwiftUI
import AppKit

/// Inactive pages stay mounted, preserving note checkmarks, drafts and device details.
struct ExpandedIslandGroup<Content: View>: View {
    let group: IslandExpandedLayout.Group
    let width: CGFloat
    @ObservedObject var model: IslandModel
    @ViewBuilder var content: (IslandExpandedColumn, CGFloat) -> Content
    @State private var selection: IslandExpandedColumn?

    private var current: IslandExpandedColumn {
        selection.flatMap { group.columns.contains($0) ? $0 : nil } ?? group.columns[0]
    }
    private var currentIndex: Int { group.columns.firstIndex(of: current) ?? 0 }
    private var isPaged: Bool { group.columns.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(group.columns) { column in
                    let active = column == current
                    content(column, WindowManager.expandedSize.height)
                        .frame(width: width)
                        .opacity(active ? 1 : 0)
                        .offset(x: active ? 0 : ((group.columns.firstIndex(of: column) ?? 0) < currentIndex ? -18 : 18))
                        .allowsHitTesting(active)
                        .accessibilityHidden(!active)
                        .zIndex(active ? 1 : 0)
                }
            }
            .frame(height: WindowManager.expandedSize.height)
            .clipped()
            if isPaged { pageControls }
        }
        .frame(width: width, height: WindowManager.expandedSize.height + (isPaged ? IslandExpandedLayout.navigationHeight : 0))
        .background {
            if isPaged { IslandPageSwipeReader { move(by: $0) } }
        }
        .animation(IslandMotion.content, value: current)
    }

    private var pageControls: some View {
        HStack(spacing: 3) {
            Button { move(by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 18, height: 20).contentShape(Rectangle())
            }.disabled(currentIndex == 0).accessibilityLabel("上一个模块")
            ForEach(group.columns) { column in
                Button { select(column) } label: {
                    Text(column.title).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).frame(height: 20)
                        .foregroundStyle(column == current ? .white : .gray)
                        .background(column == current ? Color.white.opacity(0.12) : .clear, in: Capsule())
                        .contentShape(Rectangle())
                }.accessibilityLabel("切换到\(column.title)")
                    .accessibilityAddTraits(column == current ? .isSelected : [])
            }
            Button { move(by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 18, height: 20).contentShape(Rectangle())
            }.disabled(currentIndex == group.columns.count - 1).accessibilityLabel("下一个模块")
        }
        .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(.gray)
        .padding(.horizontal, 10).padding(.bottom, 6)
        .frame(height: IslandExpandedLayout.navigationHeight)
        .help("在这一栏左右滑动，或点击名称切换模块")
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            if abs(value.translation.width) > 40 && abs(value.translation.width) > abs(value.translation.height) * 1.3 {
                move(by: value.translation.width < 0 ? 1 : -1)
            }
        })
    }

    private func move(by direction: Int) {
        let index = min(max(currentIndex + direction, 0), group.columns.count - 1)
        select(group.columns[index])
    }

    private func select(_ column: IslandExpandedColumn) {
        guard column != current else { return }
        WindowManager.window?.makeFirstResponder(nil)
        if current == .time {
            model.isTimeToolPopoverPresented = false
            model.isPomodoroSettingsPresented = false
        }
        if current == .recording { model.isRecordingSettingsPresented = false }
        selection = column
    }
}

/// Listen only within this group. Vertical scrolling continues to native scroll views.
private struct IslandPageSwipeReader: NSViewRepresentable {
    let turnPage: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView { SwipeView(turnPage: turnPage) }
    func updateNSView(_ view: SwipeView, context: Context) { view.turnPage = turnPage }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stop() }

    final class SwipeView: NSView {
        var turnPage: (Int) -> Void
        private var monitor: Any?
        private var swipe = IslandPageSwipe()

        init(turnPage: @escaping (Int) -> Void) {
            self.turnPage = turnPage
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                let scale = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
                let x = Double(event.scrollingDeltaX) * scale
                let y = Double(event.scrollingDeltaY) * scale
                if let direction = self.swipe.consume(deltaX: x, deltaY: y,
                    startsGesture: event.phase.contains(.began), isMomentum: !event.momentumPhase.isEmpty,
                    timestamp: event.timestamp) {
                    self.turnPage(direction)
                }
                return abs(x) > abs(y) * 1.3 ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            swipe = IslandPageSwipe()
        }
    }
}
