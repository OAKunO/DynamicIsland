import AppKit
import Combine
import Foundation

@MainActor
final class RecordingSettings: ObservableObject {
    static let shared = RecordingSettings()
    @Published var configuration: RecordingConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(configuration.validated) {
                defaults.set(data, forKey: configurationKey)
            }
        }
    }
    @Published private(set) var directory: URL
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    private let configurationKey = "island.recording.configuration.v1"
    private let bookmarkKey = "island.recording.directoryBookmark.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: configurationKey)
            .flatMap { try? JSONDecoder().decode(RecordingConfiguration.self, from: $0) }?.validated ?? .init()
        let fallback = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        var stale = false
        if let data = defaults.data(forKey: bookmarkKey),
           let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            directory = url
            if stale { try? persistDirectory(url) }
        } else { directory = fallback }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择录屏保存位置"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.setDirectory(url)
            } catch { self.errorMessage = "无法保存文件夹选择：\(error.localizedDescription)" }
        }
    }

    func setDirectory(_ url: URL) throws {
        try persistDirectory(url)
        directory = url
    }

    private func persistDirectory(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
    }
}
