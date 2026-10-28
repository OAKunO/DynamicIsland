import AppKit
import Combine
import IOKit
import IOKit.ps

/// 读取内置电池；电源变化由 IOKit 通知驱动，唤醒后再主动同步一次。
final class BatteryStatusMonitor: ObservableObject {
    private struct Reading {
        let percentage: Int
        let isCharging: Bool
        let isDischarging: Bool
        let minutesUntilFull: Int?
        let minutesUntilEmpty: Int?
    }

    struct Status: Equatable {
        let percentage: Int
        let isCharging: Bool
        let isDischarging: Bool
        let estimatedFullDate: Date?
        let estimatedEmptyDate: Date?

        var isLow: Bool { percentage < 20 }
        var isVisible: Bool { isCharging || isLow }
    }

    @Published private(set) var status: Status?

    var isVisible: Bool { status?.isVisible == true }

    private var powerSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var reportedMinutesUntilFull: Int?
    private var estimatedFullDate: Date?
    private var reportedMinutesUntilEmpty: Int?
    private var estimatedEmptyDate: Date?

    init(previewConfiguration: IslandLengthConfiguration? = nil) {
        if let configuration = previewConfiguration {
            let charging = configuration.battery.isCharging
            status = Status(
                percentage: configuration.battery == .low || configuration.battery == .lowCharging ? 15 : 72,
                isCharging: charging, isDischarging: !charging,
                estimatedFullDate: charging ? Date().addingTimeInterval(2400) : nil,
                estimatedEmptyDate: charging ? nil : Date().addingTimeInterval(1800)
            )
            return
        }
        refresh()

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryStatusMonitor>.fromOpaque(context)
                .takeUnretainedValue()
                .refresh()
        }, context)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(resetEstimate: true)
        }

        // 系统有时不会为「计算中 → 有预计时间」再发通知，定时补读避免卡住。
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    deinit {
        refreshTimer?.invalidate()
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func refresh(resetEstimate: Bool = false) {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [AnyObject]

        let powerSourceReading = sources.compactMap { source -> Reading? in
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool != false,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { return nil }

            let percentage = min(100, max(0, Int((Double(capacity) / Double(maximum) * 100).rounded())))
            let charging = description[kIOPSIsChargingKey] as? Bool == true
            let reportedMinutes = description[kIOPSTimeToFullChargeKey] as? Int
            let minutesUntilFull = charging && (reportedMinutes ?? -1) >= 0
                ? reportedMinutes : nil
            let isUsingBattery = description[kIOPSPowerSourceStateKey] as? String ==
                kIOPSBatteryPowerValue
            let reportedEmptyMinutes = description[kIOPSTimeToEmptyKey] as? Int
            let minutesUntilEmpty = !charging && isUsingBattery &&
                (reportedEmptyMinutes ?? -1) >= 0 &&
                (reportedEmptyMinutes ?? 65_535) < 65_535
                ? reportedEmptyMinutes : nil
            return Reading(
                percentage: percentage,
                isCharging: charging,
                isDischarging: !charging && isUsingBattery,
                minutesUntilFull: minutesUntilFull,
                minutesUntilEmpty: minutesUntilEmpty
            )
        }.first

        let registryReading = Self.readRegistryBattery()
        let reading: Reading?
        if let powerSourceReading {
            reading = Reading(
                percentage: powerSourceReading.percentage,
                isCharging: powerSourceReading.isCharging,
                isDischarging: !powerSourceReading.isCharging &&
                    (powerSourceReading.isDischarging || registryReading?.isDischarging == true),
                minutesUntilFull: powerSourceReading.minutesUntilFull ??
                    (powerSourceReading.isCharging ? registryReading?.minutesUntilFull : nil),
                minutesUntilEmpty: powerSourceReading.minutesUntilEmpty ??
                    (!powerSourceReading.isCharging ? registryReading?.minutesUntilEmpty : nil)
            )
        } else {
            reading = registryReading
        }

        let minutesUntilFull = reading?.minutesUntilFull
        if reading?.isCharging == true {
            if let minutesUntilFull {
                if resetEstimate || minutesUntilFull != reportedMinutesUntilFull ||
                    status?.isCharging != true {
                    estimatedFullDate = Date().addingTimeInterval(
                        TimeInterval(minutesUntilFull * 60)
                    )
                    reportedMinutesUntilFull = minutesUntilFull
                }
            } else if status?.isCharging != true {
                estimatedFullDate = nil
                reportedMinutesUntilFull = nil
            }
        } else {
            estimatedFullDate = nil
            reportedMinutesUntilFull = nil
        }

        let minutesUntilEmpty = reading?.minutesUntilEmpty
        if reading?.isDischarging == true {
            if let minutesUntilEmpty {
                if resetEstimate || minutesUntilEmpty != reportedMinutesUntilEmpty ||
                    status?.isDischarging != true {
                    estimatedEmptyDate = Date().addingTimeInterval(
                        TimeInterval(minutesUntilEmpty * 60)
                    )
                    reportedMinutesUntilEmpty = minutesUntilEmpty
                }
            } else if status?.isDischarging != true {
                estimatedEmptyDate = nil
                reportedMinutesUntilEmpty = nil
            }
        } else {
            estimatedEmptyDate = nil
            reportedMinutesUntilEmpty = nil
        }

        let current = reading.map {
            Status(
                percentage: $0.percentage,
                isCharging: $0.isCharging,
                isDischarging: $0.isDischarging,
                estimatedFullDate: estimatedFullDate,
                estimatedEmptyDate: estimatedEmptyDate
            )
        }
        if status != current { status = current }
    }

    private static func readRegistryBattery() -> Reading? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any],
              let percentage = properties["CurrentCapacity"] as? Int else { return nil }

        let charging = properties["IsCharging"] as? Bool == true
        let reportedMinutes = properties["AvgTimeToFull"] as? Int
        let minutesUntilFull = charging && (reportedMinutes ?? -1) >= 0 &&
            (reportedMinutes ?? 65_535) < 65_535 ? reportedMinutes : nil
        let reportedEmptyMinutes = properties["AvgTimeToEmpty"] as? Int
        let isUsingBattery = properties["ExternalConnected"] as? Bool == false
        let minutesUntilEmpty = !charging && isUsingBattery &&
            (reportedEmptyMinutes ?? -1) >= 0 &&
            (reportedEmptyMinutes ?? 65_535) < 65_535 ? reportedEmptyMinutes : nil
        return Reading(
            percentage: min(100, max(0, percentage)),
            isCharging: charging,
            isDischarging: !charging && isUsingBattery,
            minutesUntilFull: minutesUntilFull,
            minutesUntilEmpty: minutesUntilEmpty
        )
    }
}
