import Foundation

/// AI occupies both sides separately and is deliberately absent from this list.
nonisolated enum CompactActivity: String, CaseIterable, Identifiable, Sendable {
    case audio, timer, pomodoro, alarm, battery, usb, recording
    var id: Self { self }
}

nonisolated enum CompactSide: Sendable {
    case left, right
}

nonisolated struct CompactActivityLayout: Equatable, Sendable {
    let orderedActivities: [CompactActivity]
    let left: [CompactActivity]
    let right: [CompactActivity]
    let dual: CompactActivity?

    init(visible: [CompactActivity], previousOrder: [CompactActivity] = []) {
        var ordered = previousOrder.filter { visible.contains($0) }
        for activity in visible where !ordered.contains(activity) {
            ordered.append(activity)
        }
        orderedActivities = ordered
        dual = ordered.count.isMultiple(of: 2) ? nil : ordered.last
        let singles = dual == nil ? ordered : Array(ordered.dropLast())
        left = singles.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        right = singles.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? nil : $0.element }
    }

    func activities(on side: CompactSide) -> [CompactActivity] {
        let outward = (side == .left ? left : right) + (dual.map { [$0] } ?? [])
        // Arrays render from left to right: reverse the left lane so both lanes
        // grow away from the AI/notch, with the newest dual tool at both edges.
        return side == .left ? Array(outward.reversed()) : outward
    }
}
