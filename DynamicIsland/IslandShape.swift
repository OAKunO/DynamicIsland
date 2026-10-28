import SwiftUI

struct IslandShape: Shape {

    func path(in rect: CGRect) -> Path {

        var path = Path()

        // 底部圆角半径
        let radius: CGFloat = 12
        let radiusup: CGFloat = 4

        let left = rect.minX + radiusup
        let right = rect.maxX - radiusup
        let top = rect.minY
        let bottom = rect.maxY

        // 左上角
        path.move(
            to: CGPoint(
                x: left - radiusup,
                y: top
            )
        )

        // 画到右上角（顶边保持平直）
        path.addLine(
            to: CGPoint(
                x: right + radiusup,
                y: top
            )
        )

        //右上内凹圆弧
        path.addArc(
            center: CGPoint(
                x: right + radiusup,
                y: top + radiusup
            ),
            radius: radiusup,
            startAngle: .degrees(270),
            endAngle: .degrees(180),
            clockwise: true
        )

        // 沿右边向下，画到距底边 radius 的位置
        path.addLine(
            to: CGPoint(
                x: right,
                y: bottom - radius
            )
        )

        // 右下角圆弧：圆心距右下角向内 radius，从 0°（右）画到 90°（下）
        path.addArc(
            center: CGPoint(
                x: right - radius,
                y: bottom - radius
            ),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // 沿底边向左，画到距左边 radius 的位置
        path.addLine(
            to: CGPoint(
                x: left + radius,
                y: bottom
            )
        )

        // 左下角圆弧：圆心距左下角向内 radius，从 90°（下）画到 180°（左）
        path.addArc(
            center: CGPoint(
                x: left + radius,
                y: bottom - radius
            ),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        //左边竖直线
        path.addLine(
            to: CGPoint(
                x: left,
                y: top + radiusup
            )
        )

        path.addArc(
            center: CGPoint(
                x: left - radiusup,
                y: top + radiusup
            ),
            radius: radiusup,
            startAngle: .degrees(0),
            endAngle: .degrees(270),
            clockwise: true
        )

        // 沿左边回到起点（左上角），闭合路径
        path.closeSubpath()

        return path
    }
}
