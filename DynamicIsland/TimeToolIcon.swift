import SwiftUI

/// A monochrome tomato timer with the same visual weight as neighboring symbols.
struct TomatoClockIcon: View {
    var isPaused = false
    var color: Color = .white

    var body: some View {
        Canvas { context, size in
            let strokeColor: Color = isPaused ? .yellow : color
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            // The gently lobed tomato outline also serves as the clock face.
            var tomato = Path()
            tomato.move(to: CGPoint(x: 12, y: 7.3))
            tomato.addCurve(to: CGPoint(x: 2.5, y: 13.5), control1: CGPoint(x: 6.6, y: 4.1), control2: CGPoint(x: 2.5, y: 7.5))
            tomato.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 2.5, y: 19.1), control2: CGPoint(x: 6.8, y: 22))
            tomato.addCurve(to: CGPoint(x: 21.5, y: 13.5), control1: CGPoint(x: 17.2, y: 22), control2: CGPoint(x: 21.5, y: 19.1))
            tomato.addCurve(to: CGPoint(x: 12, y: 7.3), control1: CGPoint(x: 21.5, y: 7.5), control2: CGPoint(x: 17.4, y: 4.1))
            tomato.closeSubpath()
            context.stroke(tomato, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))

            // Three restrained strokes replace the previous star-shaped leaves.
            var crown = Path()
            crown.move(to: CGPoint(x: 6.7, y: 3.9))
            crown.addQuadCurve(to: CGPoint(x: 12, y: 7), control: CGPoint(x: 10.1, y: 4.5))
            crown.addQuadCurve(to: CGPoint(x: 17.3, y: 3.9), control: CGPoint(x: 13.9, y: 4.5))
            crown.move(to: CGPoint(x: 12, y: 7))
            crown.addQuadCurve(to: CGPoint(x: 12.7, y: 1.9), control: CGPoint(x: 11.6, y: 4.1))
            context.stroke(crown, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))

            var hands = Path()
            if isPaused {
                hands.move(to: CGPoint(x: 10.2, y: 11.7))
                hands.addLine(to: CGPoint(x: 10.2, y: 17))
                hands.move(to: CGPoint(x: 13.8, y: 11.7))
                hands.addLine(to: CGPoint(x: 13.8, y: 17))
            } else {
                hands.move(to: CGPoint(x: 12, y: 10.7))
                hands.addLine(to: CGPoint(x: 12, y: 14.5))
                hands.addLine(to: CGPoint(x: 15, y: 16.3))
            }
            context.stroke(hands, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel(isPaused ? "番茄钟已暂停" : "番茄钟")
    }
}

struct TimeToolIcon: View {
    let tool: IslandTimeTool
    var isPaused = false
    var size: CGFloat = 14

    var body: some View {
        Group {
            if tool == .pomodoro {
                TomatoClockIcon(isPaused: isPaused)
            } else {
                Image(systemName: isPaused ? "pause.fill" : tool.symbol)
            }
        }
        .frame(width: size, height: size)
    }
}
