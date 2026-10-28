import AppKit
import SwiftUI

/// 百分比放在实心电池内部，整块图标可插入紧凑岛任一侧的内容队列。
struct CompactBatteryView: View {
    let status: BatteryStatusMonitor.Status
    @State private var isPulseDimmed = false

    private var color: Color {
        status.isLow ? .red : Color(red: 101 / 255, green: 220 / 255, blue: 122 / 255)
    }

    var body: some View {
        Group {
            if status.isLow && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                scaledBattery
                    .opacity(isPulseDimmed ? 0.3 : 1)
                    .onAppear {
                        isPulseDimmed = false
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            isPulseDimmed = true
                        }
                    }
                    .onDisappear {
                        isPulseDimmed = false
                    }
            } else {
                scaledBattery
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.isLow
            ? "电量不足，剩余 \(status.percentage)%"
            : "正在充电，电量 \(status.percentage)%")
    }

    private var scaledBattery: some View {
        battery
            .fixedSize()
            .scaleEffect(0.75)
            .frame(width: status.isCharging ? 29.25 : 21.75, height: 10.5)
    }

    private var battery: some View {
        HStack(spacing: 1) {
            if status.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(color)
                    .frame(width: 7, height: 14)
                    .padding(.trailing, 2)
            }

            batteryBody

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 2, height: 6)
        }
        .frame(height: 14)
    }

    private var batteryBody: some View {
        let filledWidth = 26 * CGFloat(status.percentage) / 100

        return ZStack {
            Rectangle()
                .fill(color)
                .frame(width: filledWidth, height: 14)
                .frame(width: 26, height: 14, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))

            percentageLabel
                .foregroundStyle(.white)
                .frame(width: 26, height: 14)

            // 绿色填充上的深色字呈镂空效果；空白区域保留白字。
            percentageLabel
                .foregroundStyle(.black)
                .frame(width: 26, height: 14)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: filledWidth, height: 14)
                }
        }
        .frame(width: 26, height: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .strokeBorder(.white, lineWidth: 1)
        }
    }

    private var percentageLabel: some View {
        Text("\(status.percentage)%")
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}
