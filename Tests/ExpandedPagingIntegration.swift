import Foundation

@main
struct ExpandedPagingIntegration {
    @MainActor static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        let all = IslandLengthConfiguration(mode: .expandedTimerSetup, music: true,
            expandedTaskCount: 3, phone: true, showsNotes: true, computer: true)
        let allLayout = IslandExpandedLayout(configuration: all)
        check(allLayout.width <= 1_000 && allLayout.groups.count == 3, "Seven modules fit in three columns")
        check(allLayout.height == 282, "Paged workspaces reserve 256 points for content plus a separate 26-point footer")
        check(allLayout.groups.contains { Set($0.columns) == Set([.computer, .phone, .recording]) },
              "Narrow device and recording cards share a column")
        check(allLayout.groups.contains { Set($0.columns) == Set([.work, .music, .time]) },
              "Similarly sized work, music and time cards share a column")
        check(allLayout.groups.contains { $0.columns == [.notes] }, "Notes stay independently visible when room allows")
        let simple = IslandLengthConfiguration(mode: .expandedTimerSetup, showsRecordingTools: false, showsNotes: true)
        let simpleLayout = IslandExpandedLayout(configuration: simple)
        check(!simpleLayout.isPaged && simpleLayout.width == 645, "Small dashboards retain independent columns")
        check(simpleLayout.height == 256, "Dashboards without paging do not grow taller")
        for mask in 0..<128 {
            let configuration = IslandLengthConfiguration(mode: .expandedTimerSetup,
                music: mask & 1 != 0, expandedTaskCount: mask & 2 != 0 ? 3 : 0,
                showsTimeTools: mask & 4 != 0, showsRecordingTools: mask & 8 != 0,
                phone: mask & 16 != 0, showsNotes: mask & 32 != 0, computer: mask & 64 != 0)
            var expected: Set<IslandExpandedColumn> = []
            if mask & 1 != 0 { expected.insert(.music) }
            if mask & 2 != 0 { expected.insert(.work) }
            if mask & 4 != 0 { expected.insert(.time) }
            if mask & 8 != 0 { expected.insert(.recording) }
            if mask & 16 != 0 { expected.insert(.phone) }
            if mask & 32 != 0 { expected.insert(.notes) }
            if mask & 64 != 0 { expected.insert(.computer) }
            if expected.isEmpty { expected = [.time] }
            for budget: CGFloat in [360, 480, 650, 850, 1_000, 2_000] {
                let layout = IslandExpandedLayout(configuration: configuration, maximumWidth: budget)
                let pages = layout.groups.flatMap(\.columns)
                check(Set(pages) == expected && pages.count == expected.count, "Every enabled module appears exactly once")
                check(layout.width <= budget, "Every combination stays within the available screen budget")
                check(layout.height == (layout.isPaged ? 282 : 256), "Footer space follows paging even on a smaller screen")
                check(layout.groups.allSatisfy { !$0.columns.isEmpty },
                      "Every page group is nonempty")
                for group in layout.groups {
                    check(group.columns.allSatisfy { $0.width <= group.width }, "No page is squeezed below its natural width")
                }
                let naturalWidth = expected.reduce(0) { $0 + $1.width } + CGFloat(expected.count - 1)
                check((naturalWidth <= budget) == !layout.isPaged, "Paging starts only when independent columns overflow")
                check(layout == IslandExpandedLayout(configuration: configuration, maximumWidth: budget),
                      "Grouping is deterministic across redraws")
            }
        }
        for screen: CGFloat in [800, 1_024, 1_280, 1_440, 1_920, 2_560] {
            let limit = WindowManager.expandedWidthLimit(screenWidth: screen)
            check(limit <= 1_000 && limit < screen && limit <= screen * 0.85, "The island leaves room around itself on every screen")
            check(IslandExpandedLayout(configuration: all, maximumWidth: limit).width <= limit,
                  "The full dashboard also fits smaller screens")
        }
        var swipe = IslandPageSwipe()
        check(swipe.consume(deltaX: -20, deltaY: 1, startsGesture: true, isMomentum: false, timestamp: 1) == nil,
              "Small horizontal movement does not turn a page")
        check(swipe.consume(deltaX: -30, deltaY: 1, startsGesture: false, isMomentum: false, timestamp: 1.05) == 1,
              "A left swipe advances to the next module")
        check(swipe.consume(deltaX: -100, deltaY: 0, startsGesture: false, isMomentum: false, timestamp: 1.1) == nil,
              "One gesture turns at most one page")
        check(swipe.consume(deltaX: -100, deltaY: 0, startsGesture: false, isMomentum: true, timestamp: 1.7) == nil,
              "Momentum never turns another page, even after a pause")
        check(swipe.consume(deltaX: 50, deltaY: 0, startsGesture: true, isMomentum: false, timestamp: 2) == -1,
              "A new right swipe returns to the previous module")
        check(swipe.consume(deltaX: 20, deltaY: 100, startsGesture: true, isMomentum: false, timestamp: 3) == nil,
              "Vertical scrolling leaves page selection alone")
        check(swipe.consume(deltaX: 35, deltaY: 35, startsGesture: false, isMomentum: false, timestamp: 3.05) == nil,
              "Diagonal scrolling does not accidentally change pages")
        check(swipe.consume(deltaX: -50, deltaY: 0, startsGesture: false, isMomentum: false, timestamp: 4) == 1,
              "Horizontal wheel gestures work without touch phases")
        let suite = "DynamicIsland.PagingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IslandLengthSettings(defaults: defaults)
        let state = IslandLengthState(configuration: all)
        settings.setWidth(10_000, for: state)
        check(settings.width(for: state) <= Int(WindowManager.currentExpandedWidthLimit),
              "Saved custom widths cannot expand the dashboard across the screen")
        var withoutNotes = all
        withoutNotes.showsNotes = false
        check(withoutNotes.key != all.key, "Notes visibility keeps independent width preferences")
        check(WindowManager.defaultSize(for: .init(mode: .expandedTimerFinished, music: true, phone: true)) == WindowManager.expandedSize,
              "Completion alerts retain their own geometry")
        print("PASS: \(assertions) adaptive paging, screen-fit and swipe assertions")
    }
}
