import AppKit
import Combine
import Darwin
import IOKit

/// Hardware is read once; storage is refreshed while the computer card is visible.
final class ComputerInformationMonitor: ObservableObject {
    struct Information: Equatable {
        let name: String
        let model: String
        let chip: String?
        let memoryBytes: UInt64
        let systemVersion: String
        let isLaptop: Bool
        var totalStorageBytes: Int64?
        var availableStorageBytes: Int64?
    }

    @Published private(set) var information: Information
    private let isPreview: Bool

    init(preview: Bool = false) {
        isPreview = preview
        if preview {
            information = Information(name: "我的 MacBook Pro", model: "MacBook Pro",
                chip: "Apple M4 Pro", memoryBytes: 24 * 1_073_741_824,
                systemVersion: "26.5", isLaptop: true,
                totalStorageBytes: 1_000_000_000_000, availableStorageBytes: 420_000_000_000)
        } else {
            let model = Self.systemString("hw.model") ?? "Mac"
            let version = ProcessInfo.processInfo.operatingSystemVersion
            information = Information(name: Host.current().localizedName ?? "我的 Mac",
                model: model, chip: Self.systemString("machdep.cpu.brand_string"),
                memoryBytes: ProcessInfo.processInfo.physicalMemory,
                systemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                isLaptop: model.hasPrefix("MacBook") || Self.hasPortableChassis())
            refreshStorage()
        }
    }

    func refreshStorage() {
        guard !isPreview else { return }
        // The home volume contains the user's files, including on an APFS Data volume.
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        var next = information
        next.totalStorageBytes = values?.volumeTotalCapacity.map(Int64.init)
        next.availableStorageBytes = values?.volumeAvailableCapacityForImportantUsage
        if next != information { information = next }
    }

    private static func hasPortableChassis() -> Bool {
        // Recent Apple silicon model identifiers no longer contain “MacBook”.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }

    private static func systemString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
