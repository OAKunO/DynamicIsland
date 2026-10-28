import AppKit
import Foundation

@main
struct IslandLengthSettingsIntegration {
    @MainActor static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        func activity(_ provider: IslandAgentProvider, _ statuses: IslandAgentStatus...) -> IslandAgentActivity {
            IslandAgentActivity(provider: provider, statuses: statuses)
        }
        func state(_ configuration: IslandLengthConfiguration) -> IslandLengthState {
            IslandLengthState(configuration: configuration)
        }
        let emptySaved = IslandLengthSettingsSnapshot(overrides: [:], legacyOverrides: [:], restoredKeys: [])
        for provider in IslandAgentProvider.allCases {
            let variants = IslandAgentActivity.variants(for: provider)
            check(variants.count == 80, "Each source must enumerate every supported status/count combination")
            check(Set(variants.map(\.id)).count == 80, "Agent profiles must have unique IDs")
            check(variants.allSatisfy { $0.taskCount > 0 }, "Inactive sources must not appear as active profiles")
            check(variants.allSatisfy { provider == .codex ? $0.waiting == 0 : $0.failed == 0 }, "Unsupported states must not be generated")
        }
        let mixed = activity(.codex, .working, .completed)
        let mixedMultiple = activity(.codex, .working, .working, .completed)
        let many = activity(.codex, .working, .working, .working, .working)
        check(many.working == 2, "Arbitrary task counts must normalize to two-or-more")
        check(mixed.id != mixedMultiple.id, "One and multiple working tasks with results must stay distinct")
        let geometry = WindowManager.notchGeometry
        check(geometry.protectedWidth == 205, "A 185-point notch reserves ten points on each side")
        check(IslandNotchGeometry(width: 220, height: 38).protectedWidth == 240,
              "Scaled display modes use their reported points rather than physical pixels")
        check(IslandNotchGeometry(width: 0, height: 0).protectedWidth == 0,
              "Unobscured screens do not acquire a fictional notch")
        check(WindowManager.defaultSize(for: .init()).width == 205, "Idle covers the protected notch")
        let idleSize = WindowManager.defaultSize(for: .init())
        let hoveredSize = WindowManager.defaultSize(for: .init(mode: .hovered))
        check(hoveredSize.width == idleSize.width + 40 && hoveredSize.height == idleSize.height,
              "Idle hover extends twenty points on each side without changing height")
        for configuration in [IslandLengthConfiguration(music: true), .init(timer: .runningMinutes),
                              .init(battery: .charging), .init(usb: true)] {
            var hovered = configuration
            hovered.mode = .hovered
            check(WindowManager.defaultSize(for: hovered) == WindowManager.defaultSize(for: configuration),
                  "Active content retains its intrinsic size while hovered")
        }
        check(WindowManager.defaultSize(for: .init(battery: .charging)).width == 315, "Battery content stays beside the safety zone")
        check(WindowManager.defaultSize(for: .init(usb: true)).width == 353, "USB uses its widest supported device label")
        check(WindowManager.defaultSize(for: .init(battery: .charging, usb: true)).width == 397, "Two tools reserve single-side widths")
        check(WindowManager.defaultSize(for: .init(music: true)).width == 281, "Music hugs the protected edges")
        check(WindowManager.defaultSize(for: .init(timer: .runningMinutes)).width == 309, "Minute clocks fit outside the notch")
        check(WindowManager.defaultSize(for: .init(timer: .runningHours)).width == 353, "Hour clocks reserve longer labels")
        check(WindowManager.defaultSize(for: .init(timer: .alarm)).width == 265, "An alarm reserves its icon and count")
        check(WindowManager.defaultSize(for: .init(music: true, timer: .alarm)).width == 335,
              "Music and alarm share the same component budgets as their actual layout")
        check(WindowManager.defaultSize(for: .init(agents: [activity(.codex, .working)], timer: .alarm)).width >
              WindowManager.defaultSize(for: .init(agents: [activity(.codex, .working)])).width,
              "An alarm extends an AI island outward")
        check(state(.init(timer: .alarm)).key != state(.init(timer: .runningMinutes)).key &&
              state(.init(timer: .alarm)).legacyKey == nil,
              "Alarm geometry remains separate from countdown preferences")
        let timerPanel = WindowManager.defaultSize(for: .init(mode: .expandedTimerSetup))
        let workPanel = WindowManager.defaultSize(for: .init(mode: .expandedTimerSetup,
            agents: [activity(.codex, .working)], expandedTaskCount: 5))
        let combinedPanel = WindowManager.defaultSize(for: .init(mode: .expandedTimerSetup,
            agents: [activity(.codex, .working)], music: true, expandedTaskCount: 5))
        check(timerPanel.width == WindowManager.expandedSize.width + WindowManager.recordingColumnWidth + 1 && timerPanel.height == 256,
              "Time and recording occupy separate horizontal columns without growing the height")
        check(workPanel.width == timerPanel.width + WindowManager.workColumnWidth + 1 && workPanel.height == timerPanel.height,
              "Work adds a middle column without growing the height")
        check(combinedPanel.width == workPanel.width && combinedPanel.height == timerPanel.height + 26,
              "Paged columns add a separate footer below the full-height cards")
        let computerPanel = WindowManager.defaultSize(for: .init(mode: .expandedTimerSetup, computer: true))
        check(computerPanel.width == timerPanel.width + 181 && computerPanel.height == timerPanel.height,
              "Computer details extend the dashboard without changing its height")
        check(state(.init(mode: .expandedTimerSetup, computer: true)).key != state(.init(mode: .expandedTimerSetup)).key,
              "Computer layouts retain a separate saved width")
        check(state(.init(computer: true)).key == state(.init()).key,
              "Computer details must not change compact layout preferences")
        let phonePanel = WindowManager.defaultSize(for: .init(mode: .expandedTimerSetup, usb: true, phone: true))
        check(phonePanel.width == timerPanel.width + 181 && phonePanel.height == timerPanel.height,
              "Phone details add only a 180-point column and one divider, without growing the height")
        check(WindowManager.defaultSize(for: .init(mode: .expandedTimerSetup, usb: true)) == timerPanel,
              "Other USB devices must not reserve a phone column")
        check(WindowManager.defaultSize(for: .init(mode: .expandedTimerSetup,
            showsTimeTools: false, showsRecordingTools: false, phone: true)).width == geometry.minimumExpandedWidth,
              "A phone alone keeps the settings button outside the protected region")
        check(state(.init(mode: .expandedTimerSetup, phone: true)).key != state(.init(mode: .expandedTimerSetup)).key,
              "Connected phones must not reuse an unrelated saved dashboard width")
        check(state(.init(usb: true, phone: true)).key == state(.init(usb: true)).key,
              "Phone details must preserve existing compact USB width preferences")
        for mode in [IslandLengthMode.expandedGreeting, .expandedTimerFinished] {
            check(WindowManager.defaultSize(for: .init(mode: mode, phone: true)) == WindowManager.defaultSize(for: .init(mode: mode)),
                  "Phone details must not resize priority alerts")
        }
        let screen = CGRect(x: 1440, y: 0, width: 2560, height: 900)
        for workspace in [timerPanel, workPanel, combinedPanel, CGSize(width: 1100, height: 256)] {
            let frame = WindowManager.islandFrame(for: workspace, on: screen)
            check(frame.midX == screen.midX && frame.maxY == screen.maxY && frame.size == workspace,
                  "Every workspace remains centered at its configured size")
        }
        for left in [0.0, 7.5, 18, 63.5, 150, 260] {
            for right in [0.0, 24, 52.5, 79, 170, 280] {
                let content = IslandCompactContentSize(left: left, right: right)
                let frame = content.frame(on: screen, geometry: geometry)
                let localNotch = content.notchCenterX(geometry: geometry, shellWidth: frame.width)
                check(frame.minX + localNotch == screen.midX,
                      "An asymmetric compact shell retains the physical notch anchor")
                if left + right > 0 {
                    check(frame.width == 205 + 28 + left + right,
                          "Compact width is the sum of both actual lanes, safety zone and 14-point margins")
                    check(localNotch - 102.5 - left == 14 && frame.width - localNotch - 102.5 - right == 14,
                          "Each outer edge independently hugs its actual content with fourteen points")
                }
            }
        }
        let firstContent = IslandCompactContentSize(left: 18, right: 80)
        let swappedContent = IslandCompactContentSize(left: 80, right: 18)
        let firstFrame = firstContent.frame(on: screen, geometry: geometry)
        let swappedFrame = swappedContent.frame(on: screen, geometry: geometry)
        check(firstFrame.width == swappedFrame.width && firstFrame.minX - swappedFrame.minX == 62,
              "The frame still updates when left/right widths swap without changing total length")
        let grownContent = IslandCompactContentSize(left: 68, right: 80)
        let grownFrame = grownContent.frame(on: screen, geometry: geometry)
        check(firstFrame.maxX == grownFrame.maxX && firstFrame.minX - grownFrame.minX == 50,
              "Growing only the left lane leaves the existing right edge fixed")
        let shiftedExclusion = geometry.exclusionRect(in: CGRect(origin: .zero, size: firstFrame.size),
            centerX: firstContent.notchCenterX(geometry: geometry, shellWidth: firstFrame.width))
        check(firstFrame.minX + shiftedExclusion.midX == screen.midX,
              "The content mask follows the physical notch rather than the asymmetric window center")
        check(WindowManager.defaultSize(for: .init(mode: .expandedTimerSetup, expandedTaskCount: 100)) == workPanel,
              "Large task lists scroll within the same work column")
        for mode in [IslandLengthMode.expandedTimerRunning, .expandedTimerPaused] {
            check(WindowManager.defaultSize(for: .init(mode: mode)) == timerPanel,
                  "Starting or pausing a timer must not resize the time column")
        }
        check(IslandLengthConfiguration(mode: .expandedTimerSetup, music: true).minimumWidth == Int(timerPanel.width + WindowManager.musicColumnWidth + 1),
              "Saved widths must leave room for all horizontal columns")
        check(WindowManager.defaultSize(for: .init(mode: .expandedTimerFinished,
            agents: [activity(.codex, .working)], music: true)).height == timerPanel.height,
              "Priority alerts replace the dashboard at a readable height")
        check(WindowManager.defaultSize(for: .init(agents: [mixed])).width == WindowManager.defaultSize(for: .init(agents: [activity(.codex, .working)])).width, "Mixed results with one active Codex task must preserve width")
        check(WindowManager.defaultSize(for: .init(agents: [mixedMultiple])).width == WindowManager.defaultSize(for: .init(agents: [activity(.codex, .working)])).width, "A lone working Codex keeps its single-task width alongside results")
        for provider in IslandAgentProvider.allCases {
            let single = activity(provider, .working)
            let singleSize = WindowManager.defaultSize(for: .init(agents: [single]))
            check(singleSize.width > geometry.protectedWidth,
                  "Every provider must fit outside the real notch and safety margins")
            for variant in IslandAgentActivity.variants(for: provider) where variant.isWorking && variant.waiting == 0 {
                check(WindowManager.defaultSize(for: .init(agents: [variant])) == singleSize,
                      "Other waiting or finished tasks must not resize a lone working provider")
            }
            for count in [2, 3, 12] {
                let multiple = IslandAgentActivity(provider: provider,
                    statuses: Array(repeating: .working, count: count))
                for mode in [IslandLengthMode.compact, .hovered] {
                    check(WindowManager.defaultSize(for: .init(mode: mode, agents: [multiple])) == singleSize,
                          "Standalone working width must not grow with the task count")
                }
                let tools = [
                    IslandLengthConfiguration(agents: [multiple], music: true),
                    .init(agents: [multiple], timer: .runningMinutes),
                    .init(agents: [multiple], timer: .alarm),
                    .init(agents: [multiple], battery: .charging),
                    .init(agents: [multiple], usb: true),
                    .init(agents: [multiple], pomodoro: .runningMinutes),
                    .init(agents: [multiple], enabledAlarmCount: 1)
                ]
                for configuration in tools {
                    var withSingle = configuration
                    withSingle.agents = [single]
                    check(WindowManager.defaultSize(for: configuration).width ==
                          WindowManager.defaultSize(for: withSingle).width,
                          "Task counts must not arbitrarily add fifty points beside other tools")
                }
            }
        }
        let paired = IslandLengthConfiguration(agents: [activity(.codex, .working), activity(.deepSeek, .working)],
                                              timer: .runningHours, battery: .charging, usb: true)
        check(WindowManager.defaultSize(for: paired).width >= geometry.protectedWidth + 28,
              "Concurrent AI and tools retain the entire protected center")

        func checkLayout(_ visible: [CompactActivity]) {
            let layout = CompactActivityLayout(visible: visible)
            let configuration = IslandLengthConfiguration(agents: [mixed], music: visible.contains(.audio),
                timer: visible.contains(.timer) ? .runningHours : .off,
                battery: visible.contains(.battery) ? .charging : .normal, usb: visible.contains(.usb),
                pomodoro: visible.contains(.pomodoro) ? .pausedMinutes : .off,
                enabledAlarmCount: visible.contains(.alarm) ? 123 : 0,
                recording: visible.contains(.recording) ? .runningHours : .off)
            let width = WindowManager.defaultSize(for: configuration).width
            let available = (width - geometry.protectedWidth) / 2 - IslandCompactMetrics.outerPadding
            for side in [CompactSide.left, .right] {
                let tools = layout.activities(on: side)
                let actual = tools.reduce(IslandCompactMetrics.agentWidth(for: configuration)) {
                    $0 + IslandCompactMetrics.toolWidth($1, configuration: configuration, dual: $1 == layout.dual)
                } + CGFloat(tools.count) * IslandCompactMetrics.dividerWidth
                check(actual <= available, "Every tool arrival order fits its reserved lane outside the notch")
            }
            check(layout.left.count == layout.right.count, "Single-side tools must be evenly distributed")
            check(layout.dual == (visible.count.isMultiple(of: 2) ? nil : visible.last),
                  "Only the newest tool spans both sides for odd counts")
            let singles = layout.left + layout.right
            check(Set(singles + (layout.dual.map { [$0] } ?? [])) == Set(visible),
                  "Every active tool must appear without losing any")
            check(singles.count + (layout.dual == nil ? 0 : 1) == visible.count,
                  "No tool may be duplicated as both single and dual")
            let leftPositions = layout.activities(on: .left).map { visible.firstIndex(of: $0)! }
            let rightPositions = layout.activities(on: .right).map { visible.firstIndex(of: $0)! }
            check(leftPositions == leftPositions.sorted(by: >),
                  "Newer left-side content must appear farther left")
            check(rightPositions == rightPositions.sorted(),
                  "Newer right-side content must appear farther right")
            if let dual = layout.dual {
                check(layout.activities(on: .left).first == dual && layout.activities(on: .right).last == dual,
                      "A new dual-side tool must occupy the outermost position on both sides")
            }
        }
        func visitOrders(_ prefix: [CompactActivity], remaining: [CompactActivity]) {
            checkLayout(prefix)
            for activity in remaining {
                visitOrders(prefix + [activity], remaining: remaining.filter { $0 != activity })
            }
        }
        visitOrders([], remaining: CompactActivity.allCases)
        let oneTimer = CompactActivityLayout(visible: [.timer])
        check(oneTimer.activities(on: .left) == [.timer] && oneTimer.activities(on: .right) == [.timer],
              "A lone timer occupies both sides, including when AI is working")
        let newlyAdded = CompactActivityLayout(visible: [.audio, .timer, .battery], previousOrder: [.timer, .battery])
        check(newlyAdded.dual == .audio && newlyAdded.left == [.timer] && newlyAdded.right == [.battery],
              "Arrival order overrides the catalog order when music starts last")
        let removed = CompactActivityLayout(visible: [.audio, .battery], previousOrder: newlyAdded.orderedActivities)
        check(removed.dual == nil && removed.left == [.battery] && removed.right == [.audio],
              "Removing a tool restores an even split and preserves surviving arrival order")
        let restarted = CompactActivityLayout(visible: [.audio, .timer, .battery], previousOrder: removed.orderedActivities)
        check(restarted.dual == .timer, "A restarted tool becomes the newest dual-side tool")
        let alarmAdded = CompactActivityLayout(visible: [.timer, .pomodoro, .alarm], previousOrder: [.timer, .pomodoro])
        check(alarmAdded.activities(on: .left) == [.alarm, .timer] &&
              alarmAdded.activities(on: .right) == [.pomodoro, .alarm],
              "Adding an alarm after two clocks puts its icon at the far left and its count at the far right")
        check(newlyAdded.activities(on: .left) == [.audio, .timer] &&
              newlyAdded.activities(on: .right) == [.battery, .audio],
              "A tool starting last must expand both outer edges regardless of catalog order")
        var concurrent = IslandLengthConfiguration(agents: [activity(.codex, .working)], timer: .runningMinutes)
        concurrent.pomodoro = .pausedMinutes
        concurrent.enabledAlarmCount = 2
        check(concurrent.compactActivities == [.timer, .pomodoro, .alarm],
              "AI is excluded from parity and all active time tools count separately")
        check(concurrent.key != IslandLengthConfiguration(agents: concurrent.agents, timer: concurrent.timer).key,
              "Concurrent time tools have their own width preference and preview")
        check(WindowManager.legacyLengthKey(for: concurrent) == nil,
              "Concurrent tool states cannot inherit an unrelated legacy width")
        let failed = state(.init(agents: [activity(.codex, .failed)]))
        let completed = state(.init(agents: [activity(.codex, .completed)]))
        let interrupted = state(.init(agents: [activity(.codex, .interrupted)]))
        check(Set([failed.key, completed.key, interrupted.key]).count == 3, "Terminal states must save independently")
        check(failed.legacyKey == completed.legacyKey, "Old broad preferences must remain compatible")
        check(state(.init(timer: .runningMinutes)).key != state(.init(timer: .pausedMinutes)).key, "Running and paused timers must save independently")
        check(state(.init(battery: .charging)).key != state(.init(battery: .lowCharging)).key, "Low-battery charging must have its own key")
        check(state(paired).key == state(.init(agents: Array(paired.agents.reversed()), timer: .runningHours, battery: .charging, usb: true)).key,
              "Source ordering must not affect a preference key")
        for mode in IslandLengthMode.expandedModes {
            check(state(.init(mode: mode)).key == state(.init(mode: mode, battery: .low, usb: true)).key,
                  "Compact device indicators do not affect expanded column preferences")
            if mode != .expandedGreeting && mode != .expandedTimerFinished {
                check(state(.init(mode: mode)).key != state(.init(mode: mode, agents: [mixed], music: true)).key,
                      "Different visible column combinations need separate width preferences")
            }
        }
        let variants = IslandAgentProvider.allCases.map { IslandAgentActivity.variants(for: $0) }
        var allProfiles = 0
        for codex in variants[0] {
            for claude in variants[1] {
                for deepSeek in variants[2] {
                    let configuration = IslandLengthConfiguration(agents: [codex, claude, deepSeek])
                    let width = WindowManager.defaultSize(for: configuration).width
                    let available = (width - geometry.protectedWidth) / 2 - IslandCompactMetrics.outerPadding
                    check([codex, claude, deepSeek].allSatisfy {
                        IslandCompactMetrics.agentLanes($0, paired: true).maximum <= available
                    }, "Every three-source profile fits any rotating provider")
                    allProfiles += 1
                }
            }
        }
        check(allProfiles == 512_000, "All three-source profiles use the new default rule")
        for width in [205.0, 281, 600, 1500] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: 256)
            let excluded = geometry.exclusionRect(in: bounds)
            check(excluded.midX == bounds.midX && excluded.width == 205 && excluded.height == 32,
                  "All expanded and compact widths mask the same physical safety zone")
        }
        var query = IslandLengthCatalogQuery()
        let first = query.page(0, size: 40, saved: emptySaved)
        let second = query.page(1, size: 40, saved: emptySaved)
        check(first.total == 80 && first.states.count == 40 && second.states.count == 40, "Single-source catalog paging")
        check(Set((first.states + second.states).map(\.key)).count == 80, "Catalog pages must not overlap")
        query.agentFilters[.codex] = IslandAgentCatalogFilter(status: .all, count: .single)
        check(query.page(0, size: 40, saved: emptySaved).total == 4, "Single-task filter must include four Codex states")
        query.agentFilters = [:]
        query.search = "失败"
        check(query.page(0, size: 40, saved: emptySaved).total == 54, "Search must include failed-only and coexistence states")
        query.search = ""
        query.combination = .codexClaude
        check(query.page(0, size: 40, saved: emptySaved).total == 6400, "Every two-source combination must be accessible")
        query.combination = .allThree
        let last = query.page(12799, size: 40, saved: emptySaved)
        check(last.total == 512000 && last.states.count == 40, "Three-source catalog must page without materializing the complete catalog")
        query.category = .devices
        query.usb = true
        check(query.page(0, size: 40, saved: emptySaved).total == 1, "USB replaces hover; an impossible hovered USB state must not be generated")
        query.category = .expanded
        check(query.page(0, size: 40, saved: emptySaved).total == IslandLengthMode.expandedModes.count, "Every expanded page must be listed")
        check(query.page(0, size: 40, saved: emptySaved).states.allSatisfy { !$0.configuration.phone },
              "A generic compact USB filter must not create fictional phones in expanded previews")
        query.phone = true
        check(query.page(0, size: 40, saved: emptySaved).states.allSatisfy { $0.configuration.phone },
              "Expanded catalog previews explicitly include the connected phone area")
        query.computer = true
        check(query.page(0, size: 40, saved: emptySaved).states.allSatisfy { $0.configuration.computer && $0.configuration.phone },
              "Expanded previews can include the computer and phone together")

        let suiteName = "DynamicIsland.LengthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([completed.legacyKey!: 411], forKey: "island.compactLengthOverrides.v1")
        query = IslandLengthCatalogQuery()
        query.combination = .allThree
        let previousStates = (0..<18).flatMap { query.page($0, size: 40, saved: emptySaved).states }.prefix(692)
        var previous = Dictionary(uniqueKeysWithValues: previousStates.map { ($0.key, 700) })
        let expanded = state(.init(mode: .expandedMusic))
        previous[expanded.key] = expanded.defaultWidth + 30
        defaults.set(previous, forKey: "island.lengthOverrides.v2")
        defaults.set([completed.key, expanded.key], forKey: "island.lengthDefaults.v2")
        let settings = IslandLengthSettings(defaults: defaults)
        check(settings.overrides.count == 1 && settings.overrides[expanded.key] != nil,
              "All 692 obsolete compact calibrations are retired while expanded preferences survive")
        check(defaults.dictionary(forKey: "island.lengthOverrides.v2")?.count == 693,
              "Previous overrides remain intact as a recoverable backup")
        check(settings.width(for: completed) == completed.defaultWidth,
              "The new rule must not fall back to unsafe legacy widths")
        check(!settings.restoredKeys.contains(completed.key) && settings.restoredKeys.contains(expanded.key),
              "Compact reset markers are retired without discarding expanded resets")
        settings.show(completed)
        let capturedState = settings.currentState
        settings.show(failed)
        let custom = completed.defaultWidth + 40
        settings.setWidth(custom, for: capturedState)
        check(settings.width(for: completed) == custom && settings.width(for: failed) == failed.defaultWidth,
              "An in-progress edit must not change a newly detected state")
        settings.setWidth(failed.defaultWidth + 20, for: failed)
        settings.resetWidth(for: failed)
        check(settings.width(for: failed) == failed.defaultWidth, "Reset restores the new formula")
        check(settings.width(for: interrupted) == interrupted.defaultWidth,
              "Unedited terminal states use notch-aware defaults")
        let reloaded = IslandLengthSettings(defaults: defaults)
        check(reloaded.width(for: completed) == custom, "New explicit widths survive relaunch without repeating migration")
        check(reloaded.width(for: failed) == failed.defaultWidth, "Restored defaults persist")
        settings.setWidth(1, for: completed)
        check(settings.width(for: completed) == completed.defaultWidth,
              "The editor cannot make a lane too narrow for its content")
        settings.setWidth(1, for: expanded)
        check(settings.width(for: expanded) == expanded.defaultWidth, "Expanded workspaces preserve every column")
        settings.setWidth(custom, for: completed)
        query = IslandLengthCatalogQuery()
        query.modifiedOnly = true
        let modified = query.page(0, size: 40, saved: settings.snapshot)
        check(modified.states.map(\.key).contains(completed.key), "Modified filter exposes new exact states")
        check(!modified.states.map(\.key).contains(failed.key), "Restored states leave the modified filter")
        query.focusedConfiguration = paired
        query.modifiedOnly = false
        let located = query.page(0, size: 40, saved: settings.snapshot)
        check(located.total == 1 && located.states.first?.key == paired.key, "Locate-current preserves the exact combination")

        settings.show(failed)
        settings.togglePreview(for: completed)
        check(settings.displayedState == completed && settings.currentState == failed,
              "Preview does not change live detection")
        let draft = custom + 70
        settings.updatePreviewWidth(draft, for: completed)
        check(settings.displayedWidth == draft && settings.width(for: completed) == custom,
              "Draft preview is not persisted")
        settings.show(interrupted)
        check(settings.displayedState == completed && settings.displayedWidth == draft,
              "Live changes preserve the preview draft")
        settings.updatePreviewWidth(600, for: failed)
        check(settings.displayedWidth == draft, "Other rows cannot resize the preview")
        settings.updatePreviewWidth(nil, for: completed)
        check(settings.displayedWidth == custom, "Cancel restores the saved width")
        settings.setWidth(custom + 10, for: completed)
        check(settings.displayedWidth == custom + 10, "Saving updates preview geometry")
        settings.updatePreviewWidth(custom + 20, for: completed)
        settings.togglePreview(for: expanded)
        check(settings.previewDraftWidth == nil && settings.displayedState == expanded,
              "Switching previews clears the draft")
        settings.togglePreview(for: expanded)
        check(settings.previewState == nil && settings.displayedState == interrupted,
              "Exiting preview restores the latest live state")
        settings.togglePreview(for: completed)
        settings.endPreview()
        check(settings.previewState == nil && settings.previewDraftWidth == nil, "Closing clears preview state")
        check(IslandLengthSettings(defaults: defaults).previewState == nil, "Preview never persists")
        let revision = settings.geometryRevision
        settings.geometryDidChange()
        check(settings.geometryRevision == revision + 1, "Display changes invalidate live and catalog geometry")
        print("PASS: \(assertions) state catalog, geometry, migration and persistence checks")
    }
}
