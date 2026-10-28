import Combine
import Foundation
import AppKit

nonisolated struct IslandLengthSettingsSnapshot: Sendable {
    let overrides: [String: Int]
    let legacyOverrides: [String: Int]
    let restoredKeys: Set<String>

    func width(for state: IslandLengthState) -> Int {
        if restoredKeys.contains(state.key) { return state.defaultWidth }
        if let width = overrides[state.key] { return width }
        return state.defaultWidth
    }

    func isModified(_ state: IslandLengthState) -> Bool {
        width(for: state) != state.defaultWidth
    }
}

/// The notch-aware defaults supersede the old per-combination calibration.
/// Version-two data stays intact as a recoverable backup; only expanded custom
/// widths carry forward. Future explicit edits use the new namespace.
final class IslandLengthSettings: ObservableObject {
    static let shared = IslandLengthSettings()

    @Published private(set) var currentState = IslandLengthState(configuration: IslandLengthConfiguration())
    @Published private(set) var overrides: [String: Int]
    @Published private(set) var restoredKeys: Set<String>
    @Published private(set) var revision = 0
    @Published private(set) var geometryRevision = 0
    @Published private(set) var windowGeometryRevision = 0
    @Published private(set) var previewState: IslandLengthState?
    @Published private(set) var previewDraftWidth: Int?

    var displayedState: IslandLengthState { previewState ?? currentState }
    var displayedWidth: Int { previewDraftWidth ?? width(for: displayedState) }

    func togglePreview(for state: IslandLengthState) {
        if previewState?.key == state.key {
            endPreview()
        } else {
            previewDraftWidth = nil
            previewState = state
            WindowManager.refreshVisibility()
        }
    }

    func endPreview() {
        previewDraftWidth = nil
        previewState = nil
        WindowManager.refreshVisibility()
    }

    /// Unsaved input changes only the preview, until Return or focus loss saves it.
    func updatePreviewWidth(_ width: Int?, for state: IslandLengthState) {
        guard previewState?.key == state.key else { return }
        previewDraftWidth = width.map { clamp($0, for: state) }
    }

    private let defaults: UserDefaults
    private let legacyOverrides: [String: Int]
    private let defaultsKey = "island.lengthOverrides.v3"
    private let restoredKey = "island.lengthDefaults.v3"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: defaultsKey) == nil {
            let previous = defaults.dictionary(forKey: "island.lengthOverrides.v2") as? [String: Int] ?? [:]
            let expanded = previous.filter { !$0.key.hasPrefix("v2.compact.") && !$0.key.hasPrefix("v2.hovered.") }
            defaults.set(expanded, forKey: defaultsKey)
            let restored = defaults.stringArray(forKey: "island.lengthDefaults.v2") ?? []
            defaults.set(restored.filter { !$0.hasPrefix("v2.compact.") && !$0.hasPrefix("v2.hovered.") }, forKey: restoredKey)
        }
        overrides = defaults.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        legacyOverrides = [:]
        restoredKeys = Set(defaults.stringArray(forKey: restoredKey) ?? [])
    }

    func geometryDidChange() {
        // Invalidates live views and any in-flight background catalog page.
        geometryRevision += 1
    }

    func windowGeometryDidChange() {
        // Redraw the screen-anchored layout without reloading catalog pages.
        windowGeometryRevision += 1
    }

    func customWidth(for state: IslandLengthState) -> Int? {
        restoredKeys.contains(state.key) ? nil : overrides[state.key]
    }

    var currentWidth: Int { width(for: currentState) }
    var snapshot: IslandLengthSettingsSnapshot {
        IslandLengthSettingsSnapshot(overrides: overrides, legacyOverrides: legacyOverrides, restoredKeys: restoredKeys)
    }

    var allowedWidthRange: ClosedRange<Int> {
        allowedWidthRange(for: currentState)
    }

    func allowedWidthRange(for state: IslandLengthState) -> ClosedRange<Int> {
        if state.configuration.mode.isExpanded && state.configuration.mode != .expandedGreeting &&
            state.configuration.mode != .expandedTimerFinished {
            let limit = WindowManager.currentExpandedWidthLimit
            let minimum = Int(ceil(max(IslandExpandedLayout(configuration: state.configuration, maximumWidth: limit).width,
                                       WindowManager.notchGeometry.minimumExpandedWidth)))
            return minimum...max(minimum, Int(limit))
        }
        let screenLimit = Int((NSScreen.main?.frame.width ?? 1440) - 24)
        let minimum = state.configuration.minimumWidth
        return minimum...max(screenLimit, minimum)
    }

    func width(for state: IslandLengthState) -> Int {
        clamp(snapshot.width(for: state), for: state)
    }

    func defaultWidth(for state: IslandLengthState) -> Int {
        clamp(state.defaultWidth, for: state)
    }

    func isModified(_ state: IslandLengthState) -> Bool {
        snapshot.isModified(state)
    }

    func show(_ state: IslandLengthState) {
        guard currentState != state else { return }
        currentState = state
    }

    func adjustCurrentWidth(by amount: Int) {
        setWidth(currentWidth + amount, for: currentState)
    }

    /// Accept an explicit state so an edit cannot be saved to a different activity
    /// if automatic detection changes while the user is typing.
    func setWidth(_ width: Int, for state: IslandLengthState) {
        let next = clamp(width, for: state)
        if next == defaultWidth(for: state) {
            resetWidth(for: state)
            return
        }
        guard overrides[state.key] != next || restoredKeys.contains(state.key) else { return }
        overrides[state.key] = next
        restoredKeys.remove(state.key)
        persist()
    }

    func resetWidth(for state: IslandLengthState) {
        let alreadyRestored = restoredKeys.contains(state.key)
        guard overrides[state.key] != nil || (!alreadyRestored && snapshot.isModified(state)) else { return }
        overrides.removeValue(forKey: state.key)
        restoredKeys.insert(state.key)
        persist()
    }

    private func clamp(_ width: Int, for state: IslandLengthState) -> Int {
        let range = allowedWidthRange(for: state)
        return min(max(width, range.lowerBound), range.upperBound)
    }

    private func persist() {
        defaults.set(overrides, forKey: defaultsKey)
        defaults.set(Array(restoredKeys).sorted(), forKey: restoredKey)
        revision += 1
    }
}
