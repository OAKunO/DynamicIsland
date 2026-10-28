import SwiftUI

/// A narrow, vertical device area; secondary details replace its content rather
/// than adding another column or extending the island.
struct PhoneDetailsView: View {
    let device: USBConnectionMonitor.Device
    let information: PhoneInformation
    @State private var showsDetails = false

    private var batteryColor: Color {
        if information.usesExternalPower { return Color(red: 0.40, green: 0.86, blue: 0.48) }
        if (information.batteryLevel ?? 100) <= 20 { return .red }
        return .white
    }

    private var powerSymbol: String {
        switch information.powerState {
        case .charging: return "bolt.fill"
        case .fullyCharged: return "battery.100percent"
        case .connected: return "powerplug.fill"
        case .battery, .unknown:
            let level = information.batteryLevel ?? 100
            return level <= 25 ? "battery.25percent" : level <= 50 ? "battery.50percent"
                : level <= 75 ? "battery.75percent" : "battery.100percent"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(information.name ?? device.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .help(information.name ?? device.name)
                    Text(information.model ?? device.type)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if showsDetails {
                secondaryDetails
            } else if information.state == .available {
                summary
            } else {
                VStack(spacing: 9) {
                    if information.state == .loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: information.state == .needsTrust ? "lock.shield" : "cable.connector")
                            .font(.system(size: 22, weight: .light))
                    }
                    Text(information.statusMessage)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 4, height: 4)
                Text(device.linkSpeedMbps.map { "USB · \($0) Mbps" } ?? "USB 已连接")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    withAnimation(IslandMotion.control) { showsDetails.toggle() }
                } label: {
                    Text(showsDetails ? "返回" : "详情")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsDetails ? "返回手机概览" : "查看手机详情")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 42)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(information.batteryLevel.map { "\($0)%" } ?? "—")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    Image(systemName: powerSymbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(batteryColor)
                HStack(spacing: 5) {
                    Text(information.batteryLevel == nil ? "电量暂不可用" : information.powerStatusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 0)
                }
                meter(information.batteryLevel.map { Double($0) / 100 }, color: batteryColor)
            }

            HStack {
                Text("系统").foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 4)
                Text(information.systemVersion.map { "iOS \($0)" } ?? "—")
            }
            .font(.system(size: 11, weight: .medium))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("存储容量").foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 4)
                    Text(information.totalStorageBytes.map(Self.gigabytes) ?? "—")
                }
                .font(.system(size: 11, weight: .medium))
                Text("可用空间以手机为准")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var secondaryDetails: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 9) {
                detail("连接状态", information.statusMessage)
                detail("电源状态", information.powerStatusText)
                detail("USB 报告可用", information.reportedAvailableStorageBytes.map(Self.gigabytes))
                detail("文件系统空闲", information.fileSystemFreeBytes.map(Self.gigabytes))
                Text("USB 存储统计与 iPhone 设置口径不同，剩余空间请以手机为准。")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                detail("型号标识", information.productType)
                detail("序列号", information.serialNumber)
                detail("设备标识", information.udid ?? device.serialNumber)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    private func detail(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            Text(value ?? "暂不可用")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func meter(_ fraction: Double?, color: Color) -> some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.1))
                .overlay(alignment: .leading) {
                    if let fraction {
                        Capsule().fill(color)
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private nonisolated static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_000_000_000
        return value == value.rounded() ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }
}
