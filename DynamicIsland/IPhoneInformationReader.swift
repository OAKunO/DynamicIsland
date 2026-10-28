import Foundation
import CoreFoundation
import Darwin

nonisolated struct PhoneInformation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case loading, available, needsTrust, locked, unavailable, unsupported
    }
    enum PowerState: Equatable, Sendable {
        case charging, fullyCharged, connected, battery, unknown
    }

    var state: State
    var name: String?
    var model: String?
    var productType: String?
    var systemVersion: String?
    var batteryLevel: Int?
    var isCharging: Bool?
    var isExternalPowerConnected: Bool?
    var isFullyCharged: Bool?
    var totalStorageBytes: UInt64?
    // Lockdown statistics use a different accounting basis from iPhone Storage.
    // Neither of these fields is presented as the Settings app's free space.
    var reportedAvailableStorageBytes: UInt64?
    var fileSystemFreeBytes: UInt64?
    var serialNumber: String?
    var udid: String?

    var powerState: PowerState {
        if isCharging == true { return .charging }
        if isExternalPowerConnected == true {
            return isFullyCharged == true ? .fullyCharged : .connected
        }
        if isExternalPowerConnected == false { return .battery }
        return .unknown
    }

    var usesExternalPower: Bool {
        powerState == .charging || powerState == .fullyCharged || powerState == .connected
    }

    var powerStatusText: String {
        switch powerState {
        case .charging: "正在充电"
        case .fullyCharged: "已充满 · 接电"
        case .connected: "已连接电源"
        case .battery: "使用电池"
        case .unknown: "充电状态未知"
        }
    }

    mutating func updateTelemetry(battery: [String: Any], storage: [String: Any]) {
        let level = (battery["BatteryCurrentCapacity"] as? NSNumber)?.intValue
        batteryLevel = level.flatMap { (0...100).contains($0) ? $0 : nil }
        isCharging = (battery["BatteryIsCharging"] as? NSNumber)?.boolValue
        isExternalPowerConnected = (battery["ExternalConnected"] as? NSNumber)?.boolValue
        isFullyCharged = (battery["FullyCharged"] as? NSNumber)?.boolValue
        func bytes(_ key: String) -> UInt64? {
            guard let number = storage[key] as? NSNumber, number.doubleValue >= 0 else { return nil }
            return number.uint64Value
        }
        totalStorageBytes = bytes("TotalDiskCapacity")
        reportedAvailableStorageBytes = bytes("TotalDataAvailable")
        fileSystemFreeBytes = bytes("AmountDataAvailable")
    }

    var statusMessage: String {
        switch state {
        case .loading: "正在读取手机信息"
        case .available: "USB 已连接"
        case .needsTrust: "请在 iPhone 上信任此电脑"
        case .locked: "解锁 iPhone 后重试"
        case .unavailable: "暂时无法读取详情"
        case .unsupported: "已连接，暂不支持读取详情"
        }
    }

    static let preview = Self(state: .available, name: "我的 iPhone", model: "iPhone 16 Pro",
        productType: "iPhone17,1", systemVersion: "27.0.1", batteryLevel: 100,
        isCharging: false, isExternalPowerConnected: true, isFullyCharged: true,
        totalStorageBytes: 128_000_000_000, reportedAvailableStorageBytes: 83_400_000_000,
        fileSystemFreeBytes: 12_000_000_000, serialNumber: "示例序列号", udid: "示例设备标识")
}

/// Uses the system's existing pairing. Never pairs, mounts developer images,
/// installs software, or starts device services. All calls run off the UI thread.
nonisolated enum IPhoneInformationReader {
    static func normalizedIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func read(identifier: String) -> PhoneInformation {
        guard let api = MobileDeviceAPI.shared else { return .init(state: .unavailable) }
        let context = DeviceNotificationContext(api: api, identifier: identifier)
        var subscription: UnsafeMutableRawPointer?
        guard api.subscribe(deviceNotification, 0, 0,
                            Unmanaged.passUnretained(context).toOpaque(), &subscription) == 0,
              let subscription else { return .init(state: .unavailable) }
        defer {
            _ = api.unsubscribe(subscription)
            withExtendedLifetime(context) {}
        }

        let deadline = Date().addingTimeInterval(3)
        while context.device == nil && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.1, true)
        }
        guard let device = context.device else { return .init(state: .unavailable) }
        guard api.connect(device) == 0 else { return .init(state: .unavailable) }
        defer { _ = api.disconnect(device) }
        guard api.isPaired(device) != 0 else { return .init(state: .needsTrust) }
        guard api.startSession(device) == 0 else { return .init(state: .locked) }
        defer { _ = api.stopSession(device) }

        func value(_ key: String?, domain: String? = nil) -> Any? {
            api.copyValue(device, domain.map { $0 as CFString }, key.map { $0 as CFString })?.takeRetainedValue()
        }
        let productType = value("ProductType") as? String
        var information = PhoneInformation(
            state: .available,
            name: value("DeviceName") as? String,
            model: value("MarketingName") as? String ?? productType.flatMap { modelNames[$0] },
            productType: productType,
            systemVersion: value("ProductVersion") as? String,
            serialNumber: value("SerialNumber") as? String,
            udid: identifier
        )
        // Read each domain as one snapshot so charging and full flags agree.
        information.updateTelemetry(
            battery: value(nil, domain: "com.apple.mobile.battery") as? [String: Any] ?? [:],
            storage: value(nil, domain: "com.apple.disk_usage") as? [String: Any] ?? [:]
        )
        return information
    }

    private static let modelNames = [
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e"
    ]
}

private nonisolated struct MobileDeviceNotification {
    var device: UnsafeMutableRawPointer?
    var message: UInt32
}

private nonisolated final class DeviceNotificationContext {
    let api: MobileDeviceAPI
    let identifier: String
    var device: UnsafeMutableRawPointer?

    init(api: MobileDeviceAPI, identifier: String) {
        self.api = api
        self.identifier = IPhoneInformationReader.normalizedIdentifier(identifier)
    }

    deinit {
        if let device { api.releaseDevice(device) }
    }
}

private nonisolated func deviceNotification(_ notice: UnsafeRawPointer?, _ opaque: UnsafeMutableRawPointer?) {
    guard let notice, let opaque else { return }
    let context = Unmanaged<DeviceNotificationContext>.fromOpaque(opaque).takeUnretainedValue()
    let notification = notice.load(as: MobileDeviceNotification.self)
    guard notification.message == 1, context.device == nil, let device = notification.device,
          let identifier = context.api.copyIdentifier(device)?.takeRetainedValue() as String?,
          IPhoneInformationReader.normalizedIdentifier(identifier) == context.identifier else { return }
    context.api.retainDevice(device)
    context.device = device
}

/// Resolve optional private symbols at runtime so USB detection keeps working
/// on systems where this framework or its information APIs are unavailable.
private nonisolated final class MobileDeviceAPI: @unchecked Sendable {
    typealias DeviceCall = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias DeviceLifetime = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias CopyValue = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    typealias CopyIdentifier = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
    typealias Callback = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias Subscribe = @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    typealias Unsubscribe = @convention(c) (UnsafeMutableRawPointer) -> Int32

    static let shared = MobileDeviceAPI()
    private let handle: UnsafeMutableRawPointer
    let connect: DeviceCall
    let disconnect: DeviceCall
    let isPaired: DeviceCall
    let startSession: DeviceCall
    let stopSession: DeviceCall
    let retainDevice: DeviceLifetime
    let releaseDevice: DeviceLifetime
    let copyValue: CopyValue
    let copyIdentifier: CopyIdentifier
    let subscribe: Subscribe
    let unsubscribe: Unsubscribe

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let connect = symbol("AMDeviceConnect", as: DeviceCall.self),
              let disconnect = symbol("AMDeviceDisconnect", as: DeviceCall.self),
              let isPaired = symbol("AMDeviceIsPaired", as: DeviceCall.self),
              let startSession = symbol("AMDeviceStartSession", as: DeviceCall.self),
              let stopSession = symbol("AMDeviceStopSession", as: DeviceCall.self),
              let retainDevice = symbol("AMDeviceRetain", as: DeviceLifetime.self),
              let releaseDevice = symbol("AMDeviceRelease", as: DeviceLifetime.self),
              let copyValue = symbol("AMDeviceCopyValue", as: CopyValue.self),
              let copyIdentifier = symbol("AMDeviceCopyDeviceIdentifier", as: CopyIdentifier.self),
              let subscribe = symbol("AMDeviceNotificationSubscribe", as: Subscribe.self),
              let unsubscribe = symbol("AMDeviceNotificationUnsubscribe", as: Unsubscribe.self) else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.connect = connect
        self.disconnect = disconnect
        self.isPaired = isPaired
        self.startSession = startSession
        self.stopSession = stopSession
        self.retainDevice = retainDevice
        self.releaseDevice = releaseDevice
        self.copyValue = copyValue
        self.copyIdentifier = copyIdentifier
        self.subscribe = subscribe
        self.unsubscribe = unsubscribe
    }
}
