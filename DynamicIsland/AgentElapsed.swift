import Foundation
import SwiftUI

/// 所有 AI Agent 正计时共用的文本格式化。
/// 抽出来是为了让显示层可以按秒自行重算，而不必等待各 Monitor 的轮询结果。
enum AgentElapsedFormatter {
    static func text(from startedAt: Date, to endpoint: Date) -> String {
        let elapsed = max(0, Int(endpoint.timeIntervalSince(startedAt)))
        return elapsed >= 3600
            ? String(format: "%d:%02d:%02d", elapsed / 3600, elapsed % 3600 / 60, elapsed % 60)
            : String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

/// Compact agent clocks share the same animation and accessibility wording.
struct AgentElapsedLabel: View {
    let startedAt: Date
    let updatedAt: Date
    let isWorking: Bool
    let stateLabel: String

    var body: some View {
        AgentElapsedClock(startedAt: startedAt, updatedAt: updatedAt,
                          isWorking: isWorking, flashesWhenIdle: true)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let duration = AgentElapsedFormatter.text(from: startedAt, to: isWorking ? Date() : updatedAt)
        return isWorking ? "已运行 \(duration)" : "运行时长 \(duration)，\(stateLabel)"
    }
}

/// AI Agent 工作时的正计时数字。
///
/// 视觉效果与灵动岛倒计时完全一致：都使用 `numericText` 内容过渡，
/// 数字变化时旧值翻出、新值翻入。区别只在方向——倒计时递减用
/// `countsDown: true`，正计时递增用 `countsDown: false`，数字因此向上翻页。
///
/// 计时由 `TimelineView` 每秒推进，而不是等待 Monitor 轮询，这样
/// Codex / Claude / DeepSeek 都能保持和倒计时一样的每秒节奏，也不会
/// 因为某个 Monitor 轮询较慢而一次跳过两个数字。
struct AgentElapsedClock: View {
    let startedAt: Date
    let updatedAt: Date
    let isWorking: Bool
    /// 非工作状态显示的文案；nil 表示继续显示已冻结的耗时。
    var idleText: String? = nil
    var color: Color = .white.opacity(0.56)
    /// 非工作状态是否继续呼吸闪烁（紧凑岛里的时长提示使用）。
    var flashesWhenIdle: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: isWorking ? 1 : 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 4.2
            let flash = flashesWhenIdle && !isWorking ? 0.42 + (sin(phase) + 1) * 0.29 : 1
            let text = resolvedText(now: timeline.date)

            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .opacity(flash)
                .contentTransition(.numericText(countsDown: false))
                .animation(IslandMotion.control, value: text)
        }
        .fixedSize()
    }

    private func resolvedText(now: Date) -> String {
        if isWorking {
            return AgentElapsedFormatter.text(from: startedAt, to: now)
        }
        return idleText ?? AgentElapsedFormatter.text(from: startedAt, to: updatedAt)
    }
}
