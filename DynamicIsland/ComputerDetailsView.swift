import SwiftUI
import Combine

/// Mirrors the connected iPhone card, using the existing local battery monitor.
struct ComputerDetailsView: View {
    @ObservedObject var computer: ComputerInformationMonitor
    @ObservedObject var battery: BatteryStatusMonitor
    @State private var showsDetails = false
    @State private var now = Date()
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var information: ComputerInformationMonitor.Information { computer.information }
    private var powerText: String {
        guard let status = battery.status else {
            return information.isLaptop ? "电池信息暂不可用" : "外接电源 · 无内置电池"
        }
        if status.isCharging { return "正在充电" }
        if status.isDischarging { return "使用电池" }
        return status.percentage == 100 ? "已充满 · 外接电源" : "外接电源 · 未充电"
    }
    private var batteryColor: Color {
        guard let status = battery.status else { return .white }
        if status.isLow { return .red }
        return status.isDischarging ? .white : Color(red: 0.40, green: 0.86, blue: 0.48)
    }
    private var powerSymbol: String {
        guard let status = battery.status else { return information.isLaptop ? "battery.0percent" : "powerplug.fill" }
        if status.isCharging { return "bolt.fill" }
        if !status.isDischarging { return "powerplug.fill" }
        return status.percentage <= 25 ? "battery.25percent" : status.percentage <= 50 ? "battery.50percent"
            : status.percentage <= 75 ? "battery.75percent" : "battery.100percent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: information.isLaptop ? "laptopcomputer" : "desktopcomputer")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(information.name).font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).help(information.name)
                    Text("当前电脑").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            if showsDetails { secondaryDetails } else { summary }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 4, height: 4)
                Text("本机信息").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                Button {
                    withAnimation(IslandMotion.control) { showsDetails.toggle() }
                } label: {
                    Text(showsDetails ? "返回" : "详情")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, 4).padding(.horizontal, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsDetails ? "返回电脑概览" : "查看电脑详情")
            }
        }
        .padding(.horizontal, 14).padding(.top, 42).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .onAppear { now = Date(); computer.refreshStorage() }
        .onReceive(refreshTimer) { date in now = date; computer.refreshStorage() }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(battery.status.map { "\($0.percentage)%" } ?? (information.isLaptop ? "—" : "供电中"))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                    Spacer(minLength: 0)
                    Image(systemName: powerSymbol).font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(batteryColor)
                Text(powerText).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                if let status = battery.status {
                    meter(Double(status.percentage) / 100, color: batteryColor)
                }
            }
            HStack {
                Text("系统").foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 4)
                Text("macOS \(information.systemVersion)").lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 11, weight: .medium))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("可用存储").foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 4)
                    Text(information.availableStorageBytes.map(Self.storage) ?? "—")
                }
                .font(.system(size: 11, weight: .medium))
                Text(information.totalStorageBytes.map { "共 \(Self.storage($0))" } ?? "容量暂不可用")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var secondaryDetails: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 9) {
                detail("电源状态", powerText)
                if let status = battery.status {
                    if status.isCharging, let date = status.estimatedFullDate {
                        detail("预计充满", Self.remaining(until: date, now: now))
                    } else if status.isDischarging, let date = status.estimatedEmptyDate {
                        detail("预计可用", Self.remaining(until: date, now: now))
                    }
                }
                detail("型号标识", information.model)
                detail("芯片 / 处理器", information.chip)
                detail("内存", String(format: "%.0f GB", Double(information.memoryBytes) / 1_073_741_824))
                detail("系统", "macOS \(information.systemVersion)")
                detail("存储容量", information.totalStorageBytes.map(Self.storage))
                detail("可用存储", information.availableStorageBytes.map(Self.storage))
                Text("可用空间包含系统可清理的空间。")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                detail("运行时间", Self.duration(ProcessInfo.processInfo.systemUptime))
            }
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .scrollIndicators(.hidden).frame(maxHeight: .infinity)
    }

    private func detail(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            Text(value ?? "暂不可用").font(.system(size: 10, weight: .medium, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func meter(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.1)).overlay(alignment: .leading) {
                Capsule().fill(color).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4).accessibilityHidden(true)
    }

    private nonisolated static func storage(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
    private nonisolated static func remaining(until date: Date, now: Date) -> String {
        date > now ? duration(date.timeIntervalSince(now)) : "正在重新估算"
    }
    private nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
}
