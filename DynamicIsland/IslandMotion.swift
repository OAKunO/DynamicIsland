import SwiftUI
import AppKit

enum IslandMotion {
    static var container: Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .easeInOut(duration: 0.12)
        }
        return .spring(response: 0.57, dampingFraction: 0.70, blendDuration: 0.12)
    }

    static var content: Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .easeInOut(duration: 0.10)
        }
        return .spring(response: 0.32, dampingFraction: 0.90, blendDuration: 0.08)
    }

    static var control: Animation {
        .spring(response: 0.22, dampingFraction: 0.82, blendDuration: 0.05)
    }

    static var providerPage: Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .easeInOut(duration: 0.12)
        }
        return .timingCurve(0.22, 0.80, 0.20, 1, duration: 0.46)
    }

    static var alarmDeletion: Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .easeOut(duration: 0.12)
        }
        return .timingCurve(0.22, 0.80, 0.25, 1, duration: 0.34)
    }
}

private struct CompactProviderPageEffect: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        let distance = min(abs(progress), 1)
        content
            .opacity(1 - distance)
            .offset(x: progress * 26)
            .scaleEffect(1 - distance * 0.025)
            .rotation3DEffect(
                .degrees(Double(progress) * 7),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.32
            )
    }
}

extension AnyTransition {
    static var alarmRowRemoval: AnyTransition {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity,
            removal: .opacity
                .combined(with: .offset(x: 20))
                .combined(with: .scale(scale: 0.96, anchor: .trailing))
        )
    }

    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.975, anchor: .center))
                .combined(with: .offset(y: -2)),
            removal: .opacity
                .combined(with: .scale(scale: 0.99, anchor: .center))
        )
    }

    /// 旧内容向左退场、新内容从右侧接入，形成类似数字翻页的连续横向过渡。
    static var compactProviderPage: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: CompactProviderPageEffect(progress: 1),
                identity: CompactProviderPageEffect(progress: 0)
            ),
            removal: .modifier(
                active: CompactProviderPageEffect(progress: -1),
                identity: CompactProviderPageEffect(progress: 0)
            )
        )
    }
}
