import Foundation

@main
struct PhoneInformationIntegration {
    static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        let storage: [String: Any] = [
            "TotalDiskCapacity": 128_000_000_000 as UInt64,
            "TotalDataAvailable": 83_377_254_400 as UInt64,
            "AmountDataAvailable": 11_983_843_328 as UInt64
        ]
        var phone = PhoneInformation(state: .available)
        phone.updateTelemetry(battery: ["BatteryCurrentCapacity": 100,
            "BatteryIsCharging": false, "ExternalConnected": true, "FullyCharged": true], storage: storage)
        check(phone.powerState == .fullyCharged && phone.usesExternalPower,
              "A full phone connected to power must retain its powered appearance even after charging stops")
        check(phone.powerStatusText == "已充满 · 接电", "Full and plugged in must have a distinct label")
        check(phone.isCharging == false && phone.isExternalPowerConnected == true,
              "Charging and external power must remain independent raw observations")
        check(phone.totalStorageBytes == 128_000_000_000, "Storage capacity is still available")
        check(phone.reportedAvailableStorageBytes == 83_377_254_400 && phone.fileSystemFreeBytes == 11_983_843_328,
              "Different USB storage metrics must remain distinct instead of impersonating iPhone Settings")

        phone.updateTelemetry(battery: ["BatteryCurrentCapacity": 80,
            "BatteryIsCharging": true, "ExternalConnected": true, "FullyCharged": false], storage: storage)
        check(phone.powerState == .charging && phone.powerStatusText == "正在充电" && phone.usesExternalPower,
              "Active charging is distinct from full or paused external power")
        for level in [80, 100] {
            phone.updateTelemetry(battery: ["BatteryCurrentCapacity": level,
                "BatteryIsCharging": false, "ExternalConnected": true, "FullyCharged": false], storage: storage)
            check(phone.powerState == .connected && phone.usesExternalPower,
                  "Paused charging and rounded 100 percent must not imply the cable is unplugged or the battery is fully charged")
        }
        phone.updateTelemetry(battery: ["BatteryCurrentCapacity": 12,
            "BatteryIsCharging": false, "ExternalConnected": false, "FullyCharged": false], storage: storage)
        check(phone.powerState == .battery && !phone.usesExternalPower && phone.powerStatusText == "使用电池",
              "A phone disconnected from power must retain battery operation")
        phone.updateTelemetry(battery: ["BatteryCurrentCapacity": 100, "BatteryIsCharging": false], storage: [:])
        check(phone.powerState == .unknown && !phone.usesExternalPower,
              "A false charging flag alone cannot establish external power or cable state")
        check(phone.totalStorageBytes == nil && phone.reportedAvailableStorageBytes == nil && phone.fileSystemFreeBytes == nil,
              "Missing telemetry must clear older statistics rather than display stale storage")
        phone.updateTelemetry(battery: ["BatteryCurrentCapacity": 101], storage: ["TotalDiskCapacity": -1])
        check(phone.batteryLevel == nil && phone.totalStorageBytes == nil, "Invalid capacity readings must not become visible")
        check(IPhoneInformationReader.normalizedIdentifier("00008140-00122D691162801C") == "0000814000122d691162801c",
              "USB and MobileDevice identifiers must normalize consistently")

        if CommandLine.arguments.count > 1 {
            let live = IPhoneInformationReader.read(identifier: CommandLine.arguments[1])
            check(live.state == .available && live.batteryLevel != nil && live.totalStorageBytes != nil,
                  "Native reader must still fetch the connected phone")
            print("LIVE: \(live.name ?? "iPhone"), \(live.batteryLevel ?? -1)%, \(live.powerStatusText), USB available \(live.reportedAvailableStorageBytes ?? 0), filesystem free \(live.fileSystemFreeBytes ?? 0)")
        }
        print("PASS: \(assertions) phone power-state and storage-accounting checks")
    }
}
