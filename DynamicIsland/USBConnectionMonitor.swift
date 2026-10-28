import AppKit
import Combine
import IOKit

/// Tracks USB devices that macOS has actually enumerated. A power-only connection
/// cannot be identified through the USB device registry.
final class USBConnectionMonitor: ObservableObject {
    struct Device: Equatable {
        let registryID: UInt64
        let name: String
        let type: String
        var serialNumber: String? = nil
        var linkSpeedMbps: Int? = nil
        var isPhone = false
    }

    @Published private(set) var device: Device?
    @Published private(set) var phone: Device?
    @Published private(set) var phoneInformation = PhoneInformation(state: .loading)

    private var knownDevices: [UInt64: Device] = [:]
    private var selectedID: UInt64?
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let informationQueue = DispatchQueue(label: "DynamicIsland.phone-information", qos: .utility)
    private var isReadingPhoneInformation = false
    private var lastInformationAttempt: Date?

    init(previewConfiguration: IslandLengthConfiguration? = nil) {
        if let configuration = previewConfiguration {
            device = configuration.usb ? Device(registryID: 0, name: "示例 USB 设备", type: "USB 设备") : nil
            if configuration.phone {
                phone = Device(registryID: 1, name: "iPhone", type: "iPhone", linkSpeedMbps: 480, isPhone: true)
                phoneInformation = .preview
            }
            return
        }
        refresh()

        // USB registry updates can precede product-name publication. A short poll
        // also handles disconnects, sleep/wake and devices already present at launch.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func refresh() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOUSBHostDevice"),
            &iterator
        ) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var devices: [UInt64: Device] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var registryID: UInt64 = 0
            var rawProperties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
                  IORegistryEntryCreateCFProperties(
                    service, &rawProperties, kCFAllocatorDefault, 0
                  ) == KERN_SUCCESS,
                  let properties = rawProperties?.takeRetainedValue() as? [String: Any],
                  properties["Built-In"] as? Bool != true else { continue }

            let name = (properties["USB Product Name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let vendorName = (properties["USB Vendor Name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let vendorID = (properties["idVendor"] as? NSNumber)?.intValue
            let deviceClass = (properties["bDeviceClass"] as? NSNumber)?.intValue
            guard deviceClass != 9, !name.localizedCaseInsensitiveContains("hub") else {
                continue
            }
            devices[registryID] = Device(
                registryID: registryID,
                name: name.isEmpty ? "USB 设备" : name,
                type: Self.deviceType(
                    name: name,
                    vendorName: vendorName,
                    vendorID: vendorID,
                    deviceClass: deviceClass,
                    interfaceClasses: Self.interfaceClasses(for: service)
                ),
                serialNumber: properties["USB Serial Number"] as? String,
                linkSpeedMbps: (properties["UsbLinkSpeed"] as? NSNumber).map { $0.intValue / 1_000_000 },
                isPhone: name.localizedCaseInsensitiveContains("iphone") || Self.isPhone(name: name.lowercased(), vendorName: vendorName)
            )
        }

        let added = devices.keys.filter { knownDevices[$0] == nil }.sorted()
        if let newest = added.last {
            selectedID = newest
        } else if let selectedID, devices[selectedID] == nil {
            self.selectedID = devices.keys.sorted().first
        } else if selectedID == nil {
            selectedID = devices.keys.sorted().first
        }
        knownDevices = devices
        let nextDevice = selectedID.flatMap { devices[$0] }
        if device != nextDevice { device = nextDevice }

        // A newly attached keyboard or drive must not hide a connected phone.
        let phones = devices.values.filter(\.isPhone).sorted { $0.registryID < $1.registryID }
        let nextPhone = nextDevice?.isPhone == true ? nextDevice
            : phones.first(where: { $0.registryID == phone?.registryID }) ?? phones.first
        if phone != nextPhone {
            phone = nextPhone
            phoneInformation = .init(state: .loading)
            lastInformationAttempt = nil
        }
        refreshPhoneInformation()
    }

    private func refreshPhoneInformation() {
        guard let phone else { return }
        guard phone.type == "iPhone", let identifier = phone.serialNumber, !identifier.isEmpty else {
            phoneInformation = .init(state: .unsupported)
            return
        }
        guard !isReadingPhoneInformation,
              lastInformationAttempt.map({ Date().timeIntervalSince($0) >= 20 }) ?? true else { return }
        isReadingPhoneInformation = true
        lastInformationAttempt = Date()
        let registryID = phone.registryID
        informationQueue.async { [weak self] in
            let information = autoreleasepool { IPhoneInformationReader.read(identifier: identifier) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReadingPhoneInformation = false
                // Discard responses from a phone unplugged or replaced during a read.
                guard self.phone?.registryID == registryID,
                      self.phone?.serialNumber == identifier else {
                    self.refreshPhoneInformation()
                    return
                }
                self.phoneInformation = information
            }
        }
    }

    private static func interfaceClasses(for device: io_service_t) -> Set<Int> {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var classes: Set<Int> = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let value = IORegistryEntryCreateCFProperty(
                entry, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber {
                classes.insert(value.intValue)
            }
        }
        return classes
    }

    private static func deviceType(
        name: String,
        vendorName: String,
        vendorID: Int?,
        deviceClass: Int?,
        interfaceClasses: Set<Int>
    ) -> String {
        let lower = name.lowercased()
        if ["airpods", "earbuds", "earphones", "headphones", "headset", "耳机"]
            .contains(where: lower.contains) { return "耳机" }
        if lower.contains("iphone") { return "iPhone" }
        if ["ipad", "tablet", "平板", "galaxy tab", "matepad", "redmi pad",
            "xiaomi pad", "oneplus pad", "pixel tablet"]
            .contains(where: lower.contains) ||
            lower.range(of: #"\bsm-[tx][a-z0-9]+\b"#, options: .regularExpression) != nil {
            return "平板"
        }
        if lower.contains("ipod") { return "音乐播放器" }
        if ["keyboard", "键盘"].contains(where: lower.contains) { return "键盘" }
        if ["mouse", "trackpad", "鼠标", "触控板"].contains(where: lower.contains) {
            return "指针设备"
        }
        if ["storage", "flash drive", "external disk", "ssd", "硬盘", "u盘"]
            .contains(where: lower.contains) { return "存储设备" }
        if ["camera", "webcam", "摄像头"].contains(where: lower.contains) { return "摄像头" }
        if ["speaker", "microphone", "audio", "sound", "dac", "麦克风", "音箱"]
            .contains(where: lower.contains) { return "音频设备" }
        if interfaceClasses.contains(1) { return "音频设备" }
        if interfaceClasses.contains(8) { return "存储设备" }
        if interfaceClasses.contains(14) { return "摄像头" }
        if interfaceClasses.contains(3) { return "输入设备" }
        if isPhone(name: lower, vendorName: vendorName) {
            return phoneBrand(name: name, vendorName: vendorName, vendorID: vendorID) ?? "手机"
        }
        switch deviceClass {
        case 1: return "音频设备"
        case 3: return "输入设备"
        case 8: return "存储设备"
        case 14: return "摄像头"
        case 224: return "无线设备"
        default: return "USB 设备"
        }
    }

    private static func isPhone(name: String, vendorName: String) -> Bool {
        if ["android", "手机", "pixel ", "pixel_", "galaxy s", "galaxy a",
            "galaxy z", "galaxy note", "galaxy m", "galaxy f", "oneplus",
            "redmi", "poco", "xiaomi ", "oppo", "vivo ", "iqoo", "realme",
            "huawei p", "huawei mate ", "honor magic", "motorola", "moto g",
            "moto edge", "nothing phone", "xperia"]
            .contains(where: name.contains) { return true }
        if name.range(of: #"(?<![a-z])phone(?![a-z])|\bsm-[safmng][a-z0-9]+\b"#,
                      options: .regularExpression) != nil { return true }
        // Some Android devices report only MTP/ADB as their product name.
        let genericAndroidName = ["mtp", "adb", "usb device"].contains(name)
        return genericAndroidName &&
            phoneBrand(name: "", vendorName: vendorName, vendorID: nil) != nil
    }

    private static func phoneBrand(
        name: String,
        vendorName: String,
        vendorID: Int?
    ) -> String? {
        let identity = "\(name) \(vendorName)".lowercased()
        let brands: [(keywords: [String], label: String)] = [
            (["redmi", "红米"], "Redmi"),
            (["poco"], "POCO"),
            (["iqoo"], "iQOO"),
            (["pixel", "google"], "Google"),
            (["samsung", "三星", "galaxy"], "三星"),
            (["xiaomi", "小米"], "小米"),
            (["oneplus", "一加"], "一加"),
            (["oppo"], "OPPO"),
            (["vivo"], "vivo"),
            (["realme"], "realme"),
            (["huawei", "华为"], "华为"),
            (["honor", "荣耀"], "荣耀"),
            (["motorola", "moto "], "摩托罗拉"),
            (["nothing"], "Nothing"),
            (["sony", "xperia"], "索尼"),
            (["nubia", "努比亚"], "努比亚"),
            (["zte", "中兴"], "中兴")
        ]
        if let match = brands.first(where: { brand in
            brand.keywords.contains(where: identity.contains)
        }) {
            return match.label
        }
        if name.lowercased().range(
            of: #"\bsm-[safmng][a-z0-9]+\b"#, options: .regularExpression
        ) != nil {
            return "三星"
        }
        switch vendorID {
        case 0x04e8: return "三星"
        case 0x18d1: return "Google"
        case 0x2717: return "小米"
        case 0x2a70: return "一加"
        case 0x22d9: return "OPPO"
        case 0x12d1: return "华为"
        case 0x22b8: return "摩托罗拉"
        default: return nil
        }
    }
}
