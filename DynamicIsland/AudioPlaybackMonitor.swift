import AppKit
import ApplicationServices
import Combine
import CoreAudio
import Darwin

/// 监听 macOS 当前正在播放媒体的进程，并解析播放来源 App 图标。
final class AudioPlaybackMonitor: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var sourceIcon: NSImage?
    @Published private(set) var artworkThemeColor: NSColor?
    @Published private(set) var sourceName: String?
    @Published var isExpanded = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var trackArtist = ""
    @Published private(set) var lyricsLines: [String] = []
    @Published private(set) var lyricTimestamps: [Double] = []
    @Published private(set) var activeLyricIndex: Int?
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var trackDuration: Double = 0
    @Published private(set) var lyricsAccessibilityPermissionNeeded = false

    private let mediaRemote = MediaRemoteAPI()
    private var pollingTimer: Timer?
    private var refreshGeneration = 0
    private var currentSourceBundleIdentifier: String?
    private var musicIsPlaying: Bool?
    private var mediaRemoteConfirmedBundleIdentifiers = Set<String>()
    private var mediaRemotePausedBundleIdentifiers = Set<String>()
    private var audioSilentBundleIdentifiers = Set<String>()
    private var audioActivityMonitor: ProcessAudioActivityMonitor?
    private var monitoredAudioProcessIdentifier: pid_t?
    private var confirmedAudibleProcessIdentifier: pid_t?
    private var audioActivityMonitorRetryAfter = Date.distantPast
    private var musicArtwork: NSImage?
    private var musicArtworkTrackIdentifier: String?
    private var trackAlbum = ""
    private var lyricsRequest: URLSessionDataTask?
    private var requestedLyricsSignature: String?
    private var isReadingAccessibilityLyrics = false
    private var lastAccessibilityLyricsRefreshDate = Date.distantPast
    private var ownsOpenMusicLyricsPanel = false
    private var hasPromptedForAccessibility = false
    private var isWaitingForAccessibilityPermission = false
    private var accessibilityPermissionRetryCount = 0
    private var lastArtworkRefreshDate = Date.distantPast
    private var isCheckingMusicTrack = false
    private var hasPendingMusicTrackCheck = false
    private var isLoadingMusicArtwork = false
    private var hasPendingMusicArtworkReload = false
    private var musicNotificationObservers: [NSObjectProtocol] = []

    /// Core Audio HAL 查询与 process tap / aggregate device 的生命周期都是同步
    /// IPC，设备重配置时可能长时间阻塞，因此统一放到专用串行队列，主线程永不
    /// 直接调用，避免整岛卡死。
    private let halQueue = DispatchQueue(
        label: "OAKunO.DynamicIsland.core-audio-hal",
        qos: .utility
    )
    private let tapLifecycleQueue = DispatchQueue(
        label: "OAKunO.DynamicIsland.audio-activity-lifecycle",
        qos: .userInitiated
    )

    /// 系统唤醒后 coreaudiod / mediaremoted / LaunchServices 都在重配置，
    /// 这段时间内做任何同步 IPC 都可能长时间阻塞，先暂停轮询再恢复。
    private var isSuspendedForWake = false
    private var wakeObservers: [NSObjectProtocol] = []
    private var resumeAfterWakeWorkItem: DispatchWorkItem?

    init(previewConfiguration: IslandLengthConfiguration? = nil) {
        if let configuration = previewConfiguration {
            isPlaying = configuration.music || configuration.mode == .expandedMusic
            isExpanded = configuration.mode == .expandedMusic
            sourceName = "Music"
            sourceIcon = NSImage(systemSymbolName: "music.note", accessibilityDescription: "音乐预览")
            trackTitle = "喜欢的音乐"
            trackArtist = "音乐预览"
            trackDuration = 240
            playbackPosition = 83
            artworkThemeColor = .systemMint
            return
        }
        startMonitoringMusicNotifications()
        startWakeMonitoring()
        refresh()

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
    }

    deinit {
        pollingTimer?.invalidate()
        resumeAfterWakeWorkItem?.cancel()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        wakeObservers.forEach(workspaceCenter.removeObserver)
        let center = DistributedNotificationCenter.default()
        musicNotificationObservers.forEach(center.removeObserver)
    }

    /// 歌词只属于能够明确识别的 Apple Music 播放活动。浏览器和其他输出源
    /// 即使触发了系统音频，也不能复用缓存中的曲目信息或歌词界面。
    var isMusicPlayback: Bool {
        isPlaying && currentSourceBundleIdentifier == "com.apple.Music"
    }

    /// 点击展开音乐卡片时才申请辅助功能权限，避免应用启动时主动打扰。
    /// 权限只用于读取 Music 已经显示的歌词文本，不会接触音频数据。
    func expandMusicCard() {
        isExpanded = true
        guard currentSourceBundleIdentifier == "com.apple.Music" else { return }
        loadMusicLyricsFromAccessibility(requestPermissionIfNeeded: true)
    }

    func collapseMusicCard() {
        isExpanded = false
        activeLyricIndex = nil
        guard ownsOpenMusicLyricsPanel else { return }
        ownsOpenMusicLyricsPanel = false
        DispatchQueue.global(qos: .utility).async {
            Self.closeMusicLyricsPanelIfVisible()
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refresh() {
        // 唤醒后的重配置窗口内不发起任何音频/媒体查询，等系统稳定再恢复。
        guard !isSuspendedForWake else { return }

        refreshGeneration += 1
        let generation = refreshGeneration

        // HAL 查询放到后台串行队列，结果再回主线程应用；主线程只处理状态。
        halQueue.async { [weak self] in
            let outputProcess = CoreAudioPlaybackDetector.activeOutputProcess()
            DispatchQueue.main.async {
                guard let self, generation == self.refreshGeneration else { return }
                self.applyOutputProcess(outputProcess, generation: generation)
            }
        }
    }

    private func startWakeMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers = [
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSystemWake()
            },
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSystemWake()
            }
        ]
    }

    /// 唤醒 / 解锁后先停轮询并拆掉休眠前留下的失效 tap，等待系统稳定再恢复。
    /// 唤醒瞬间 coreaudiod、mediaremoted、LaunchServices 都可能未就绪，任何同步
    /// 查询都可能阻塞；这是「每次休眠唤醒必卡死」的直接来源。
    private func handleSystemWake() {
        resumeAfterWakeWorkItem?.cancel()
        isSuspendedForWake = true
        refreshGeneration += 1

        let previousMonitor = audioActivityMonitor
        audioActivityMonitor = nil
        monitoredAudioProcessIdentifier = nil
        confirmedAudibleProcessIdentifier = nil
        tapLifecycleQueue.async { _ = previousMonitor }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isSuspendedForWake = false
            self.refresh()
        }
        resumeAfterWakeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func applyOutputProcess(_ outputProcess: AudioOutputProcess?, generation: Int) {
        if let outputProcess {
            let canonicalBundleIdentifier = canonicalBundleIdentifier(
                for: outputProcess.bundleIdentifier
            )
            if canonicalBundleIdentifier == "com.apple.Music", musicIsPlaying == false {
                clearPlaybackSource()
            } else if let canonicalBundleIdentifier,
                      mediaRemotePausedBundleIdentifiers.contains(canonicalBundleIdentifier) ||
                      audioSilentBundleIdentifiers.contains(canonicalBundleIdentifier) {
                // Chrome 等浏览器暂停后，HAL 输出进程可能仍保持 running。
                // 已由 MediaRemote 确认暂停的来源不再被这个残留状态重新点亮。
                clearPlaybackSource()
            } else {
                updatePlaybackSource(
                    processIdentifier: outputProcess.processIdentifier,
                    bundleIdentifier: outputProcess.bundleIdentifier
                )
            }
        } else {
            clearPlaybackSource()
        }

        refreshAccessibilityLyricsIfNeeded()
        queryMediaRemote(outputProcess: outputProcess, generation: generation)
    }

    /// MediaRemote 也是跨进程 XPC，唤醒后 mediaremoted 未就绪时调用本身可能阻塞，
    /// 因此发起调用放到后台队列，回调仍在主线程更新状态。
    private func queryMediaRemote(outputProcess: AudioOutputProcess?, generation: Int) {
        guard let mediaRemote else { return }

        halQueue.async { [weak self] in
            mediaRemote.getIsPlaying(.main) { [weak self] isPlaying in
                guard let self, generation == self.refreshGeneration else { return }
                guard isPlaying else {
                    if let bundleIdentifier = self.currentSourceBundleIdentifier,
                       self.mediaRemoteConfirmedBundleIdentifiers.contains(bundleIdentifier) {
                        self.mediaRemotePausedBundleIdentifiers.insert(bundleIdentifier)
                        self.clearPlaybackSource()
                    }
                    return
                }

                self.halQueue.async {
                    mediaRemote.getApplicationPID(.main) { processIdentifier in
                        guard generation == self.refreshGeneration else { return }
                        // Chrome 的 MediaRemote PID 通常是主进程，真正 PCM 输出却在 Helper。
                        // 有 HAL 结果时优先使用它，否则会监听错 PID 并把静音流误判为播放。
                        let resolvedProcessIdentifier = outputProcess?.processIdentifier ?? processIdentifier
                        let bundleIdentifier = outputProcess?.bundleIdentifier ?? self.bundleIdentifier(
                            for: resolvedProcessIdentifier
                        )
                        if let canonicalBundleIdentifier = self.canonicalBundleIdentifier(
                            for: bundleIdentifier
                        ), self.isSupportedPlaybackSource(canonicalBundleIdentifier) {
                            self.mediaRemoteConfirmedBundleIdentifiers.insert(canonicalBundleIdentifier)
                            self.mediaRemotePausedBundleIdentifiers.remove(canonicalBundleIdentifier)
                        }
                        self.updatePlaybackSource(
                            processIdentifier: resolvedProcessIdentifier,
                            bundleIdentifier: bundleIdentifier
                        )
                    }
                }
            }
        }
    }

    private func bundleIdentifier(for processIdentifier: pid_t) -> String? {
        guard processIdentifier > 0 else { return nil }
        return NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
    }

    private func updatePlaybackSource(
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) {
        let canonicalBundleIdentifier = canonicalBundleIdentifier(for: bundleIdentifier)
        // 音频岛采用白名单：只有 Apple Music 和 Chrome 可以触发波形。
        // 剪映、ToDesk 以及其他带音频流的应用都不会让灵动岛误展开。
        if !isSupportedPlaybackSource(canonicalBundleIdentifier) {
            if currentSourceBundleIdentifier == canonicalBundleIdentifier {
                clearPlaybackSource()
            }
            return
        }

        if canonicalBundleIdentifier == "com.google.Chrome" {
            monitorAudioActivityIfNeeded(
                processIdentifier: processIdentifier,
                bundleIdentifier: canonicalBundleIdentifier
            )
            // Chrome 暂停后 running-output 可以保持很久。等进程 Tap 真正
            // 读到可听 PCM 采样后再展示，通道存在本身不再算“正在播放”。
            guard confirmedAudibleProcessIdentifier == processIdentifier else {
                if currentSourceBundleIdentifier == canonicalBundleIdentifier {
                    clearPlaybackSource()
                }
                return
            }
        }

        guard processIdentifier > 0 else {
            isPlaying = true
            sourceIcon = nil
            sourceName = nil
            return
        }

        let application = resolvedApplication(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        isPlaying = true
        let wasShowingMusic = currentSourceBundleIdentifier == "com.apple.Music"
        currentSourceBundleIdentifier = canonicalBundleIdentifier
        if canonicalBundleIdentifier == "com.apple.Music" {
            if let artwork = musicArtwork {
                sourceIcon = artwork
                if artworkThemeColor == nil {
                    artworkThemeColor = Self.themeColor(from: artwork) ?? .systemPink
                }
            } else {
                let fallbackIcon = application?.icon ?? icon(for: bundleIdentifier)
                sourceIcon = fallbackIcon
                if let fallbackIcon {
                    // Music 在未授权读取系统“正在播放”封面时会先退回 App 图标。
                    // 图标取色失败也必须给波形一个单色，不能继续落回彩虹色。
                    artworkThemeColor = Self.themeColor(from: fallbackIcon) ?? .systemPink
                } else {
                    artworkThemeColor = .systemPink
                }
            }
            refreshMusicArtworkIfNeeded()
        } else {
            if wasShowingMusic {
                collapseMusicCard()
            }
            sourceIcon = application?.icon ?? icon(for: bundleIdentifier)
            artworkThemeColor = nil
            // HAL 在 Music 播放期间偶尔会短暂返回无 bundle id 的输出进程。
            // 这种瞬态不能清掉刚读到的歌名；只有明确切换到浏览器时才重置。
            if wasShowingMusic,
               let canonicalBundleIdentifier,
               isBrowser(canonicalBundleIdentifier),
               musicIsPlaying == false {
                trackTitle = ""
                trackArtist = ""
                trackAlbum = ""
                lyricsLines = []
                lyricTimestamps = []
                activeLyricIndex = nil
                playbackPosition = 0
                trackDuration = 0
                requestedLyricsSignature = nil
                lyricsRequest?.cancel()
            }
        }
        sourceName = application?.localizedName
        if canonicalBundleIdentifier != "com.google.Chrome" {
            monitorAudioActivityIfNeeded(
                processIdentifier: processIdentifier,
                bundleIdentifier: canonicalBundleIdentifier
            )
        }
    }

    private func monitorAudioActivityIfNeeded(
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) {
        guard let bundleIdentifier, isBrowser(bundleIdentifier) else { return }
        guard monitoredAudioProcessIdentifier != processIdentifier else { return }
        guard Date() >= audioActivityMonitorRetryAfter else { return }

        monitoredAudioProcessIdentifier = processIdentifier
        let previousMonitor = audioActivityMonitor
        audioActivityMonitor = nil
        confirmedAudibleProcessIdentifier = nil

        // Process Tap / Aggregate Device 的创建与销毁都是同步 HAL 调用，设备
        // 重配置时会阻塞，统一放到后台串行队列，避免卡住主线程。
        tapLifecycleQueue.async {
            _ = previousMonitor
        }
        let lifecycleQueue = tapLifecycleQueue
        lifecycleQueue.async { [weak self] in
            let createdMonitor = ProcessAudioActivityMonitor(
                processIdentifier: processIdentifier,
                activityChanged: { [weak self] hasAudibleSamples in
                    guard let self else { return }
                    if hasAudibleSamples {
                        self.confirmedAudibleProcessIdentifier = processIdentifier
                        self.audioSilentBundleIdentifiers.remove(bundleIdentifier)
                        self.mediaRemotePausedBundleIdentifiers.remove(bundleIdentifier)
                        self.refresh()
                    } else {
                        if self.confirmedAudibleProcessIdentifier == processIdentifier {
                            self.confirmedAudibleProcessIdentifier = nil
                        }
                        self.audioSilentBundleIdentifiers.insert(bundleIdentifier)
                        if self.currentSourceBundleIdentifier == bundleIdentifier {
                            self.clearPlaybackSource()
                        }
                    }
                }
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if let createdMonitor {
                        lifecycleQueue.async { _ = createdMonitor }
                    }
                    return
                }
                guard self.monitoredAudioProcessIdentifier == processIdentifier else {
                    if let createdMonitor {
                        lifecycleQueue.async { _ = createdMonitor }
                    }
                    return
                }
                guard let monitor = createdMonitor else {
                    self.monitoredAudioProcessIdentifier = nil
                    self.confirmedAudibleProcessIdentifier = nil
                    self.audioActivityMonitorRetryAfter = Date().addingTimeInterval(2)
                    return
                }
                self.audioActivityMonitor = monitor
            }
        }
    }

    private func isBrowser(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.google.Chrome" ||
            bundleIdentifier == "com.apple.Safari" ||
            bundleIdentifier == "com.microsoft.edgemac" ||
            bundleIdentifier == "org.mozilla.firefox"
    }

    private func isSupportedPlaybackSource(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.Music" || bundleIdentifier == "com.google.Chrome"
    }

    private func refreshMusicArtworkIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastArtworkRefreshDate) >= 0.8 else { return }
        lastArtworkRefreshDate = now
        // 系统正在播放数据是封面的主通道；此前这里只定义了读取方法却没有
        // 接入刷新流程，导致经常只显示 Music 图标，波形也拿不到封面主题色。
        refreshMusicNowPlayingInfo()
        if force {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                // 封面读取不再依赖曲目信息脚本成功，避免任一元数据字段
                // 暂时不可用时把整条更新链路一起阻断。
                self?.loadMusicArtworkFromMusicApp(force: true)
                self?.checkCurrentMusicTrack(forceArtworkReload: true)
            }
            return
        }
        if musicArtwork == nil {
            loadMusicArtworkFromMusicApp()
        }
        checkCurrentMusicTrack()
    }

    /// 系统“正在播放”数据作为封面和基本元数据的主通道；它不依赖
    /// Apple Events 自动化权限，AppleScript 只用于补充歌词。
    private func refreshMusicNowPlayingInfo() {
        guard let getNowPlayingInfo = mediaRemote?.getNowPlayingInfo else { return }
        // 与 getIsPlaying 同理：发起调用放到后台队列，回调仍在主线程。
        halQueue.async { [weak self] in
            getNowPlayingInfo(.main) { [weak self] rawInformation in
            guard let self,
                  self.currentSourceBundleIdentifier == "com.apple.Music" else { return }
            let information = rawInformation as NSDictionary

            let title = information["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = information["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let album = information["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
            let identifier = information["kMRMediaRemoteNowPlayingInfoUniqueIdentifier"] as? String
                ?? [title, artist, album].joined(separator: "|")

            if !title.isEmpty { self.trackTitle = title }
            if !artist.isEmpty { self.trackArtist = artist }
            if !album.isEmpty { self.trackAlbum = album }
            if let duration = information["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber {
                self.trackDuration = max(0, duration.doubleValue)
            }
            if let elapsed = information["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber {
                self.playbackPosition = max(0, elapsed.doubleValue)
            }
            if let artworkData = information["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
               let artwork = NSImage(data: artworkData) {
                self.applyMusicArtwork(artwork)
            }
            if self.lyricsLines.isEmpty {
                self.loadRemoteLyricsIfNeeded()
            }

            guard !identifier.replacingOccurrences(of: "|", with: "").isEmpty,
                  identifier != self.musicArtworkTrackIdentifier else { return }
            self.musicArtworkTrackIdentifier = identifier
            self.lyricsLines = []
            self.lyricTimestamps = []
            self.activeLyricIndex = nil
            self.loadMusicArtworkFromMusicApp(force: true)
            self.loadMusicLyricsFromMusicApp(for: identifier)
            }
        }
    }

    private func checkCurrentMusicTrack(forceArtworkReload: Bool = false) {
        guard !isCheckingMusicTrack else {
            if forceArtworkReload { hasPendingMusicTrackCheck = true }
            return
        }
        isCheckingMusicTrack = true
        let scriptSource = """
        tell application id "com.apple.Music"
            set currentTrack to current track
            set trackIdentifier to ""
            set titleText to ""
            set artistText to ""
            set albumText to ""
            set positionValue to 0
            set durationValue to 0
            try
                set trackIdentifier to persistent ID of currentTrack as text
            end try
            try
                set titleText to name of currentTrack as text
            end try
            try
                set artistText to artist of currentTrack as text
            end try
            try
                set albumText to album of currentTrack as text
            end try
            try
                set positionValue to player position
            end try
            try
                set durationValue to duration of currentTrack
            end try
            if trackIdentifier is "" then set trackIdentifier to titleText & "|" & artistText & "|" & albumText
            return {trackIdentifier, titleText, artistText, albumText, positionValue, durationValue}
        end tell
        """

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let descriptor = AppleScriptRunner.run(scriptSource)
            let trackIdentifier = descriptor?.atIndex(1)?.stringValue
            let title = descriptor?.atIndex(2)?.stringValue ?? ""
            let artist = descriptor?.atIndex(3)?.stringValue ?? ""
            let album = descriptor?.atIndex(4)?.stringValue ?? ""
            let position = descriptor?.atIndex(5)?.doubleValue ?? 0
            let duration = descriptor?.atIndex(6)?.doubleValue ?? 0

            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingMusicTrack = false
                guard self.currentSourceBundleIdentifier == "com.apple.Music",
                      let trackIdentifier,
                      !trackIdentifier.isEmpty else { return }

                // Music 切歌的极短窗口可能返回空字符串；不要用空值覆盖
                // 分布式通知已经送达的有效元数据。
                if !title.isEmpty { self.trackTitle = title }
                if !artist.isEmpty { self.trackArtist = artist }
                if !album.isEmpty { self.trackAlbum = album }
                self.playbackPosition = max(0, position)
                self.trackDuration = max(0, duration)
                if self.lyricsLines.isEmpty {
                    self.loadRemoteLyricsIfNeeded()
                }

                let trackChanged = trackIdentifier != self.musicArtworkTrackIdentifier
                if trackChanged {
                    self.musicArtworkTrackIdentifier = trackIdentifier
                    self.lyricsLines = []
                    self.lyricTimestamps = []
                    self.activeLyricIndex = nil
                    self.loadMusicArtworkFromMusicApp(force: true)
                    self.loadMusicLyricsFromMusicApp(for: trackIdentifier)
                } else if forceArtworkReload {
                    self.loadMusicArtworkFromMusicApp(force: true)
                    if self.lyricsLines.isEmpty {
                        self.loadMusicLyricsFromMusicApp(for: trackIdentifier)
                    }
                }

                if self.hasPendingMusicTrackCheck {
                    self.hasPendingMusicTrackCheck = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        self.checkCurrentMusicTrack(forceArtworkReload: true)
                    }
                }
            }
        }
    }

    private func loadMusicLyricsFromMusicApp(for expectedTrackIdentifier: String) {
        let scriptSource = """
        tell application id "com.apple.Music"
            try
                return lyrics of current track as text
            on error
                return ""
            end try
        end tell
        """
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lyrics = AppleScriptRunner.run(scriptSource)?.stringValue ?? ""
            let lines = lyrics
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            DispatchQueue.main.async {
                guard let self,
                      self.currentSourceBundleIdentifier == "com.apple.Music",
                      self.musicArtworkTrackIdentifier == expectedTrackIdentifier else { return }
                self.lyricsLines = lines
                self.lyricTimestamps = []
                self.activeLyricIndex = nil
                if lines.isEmpty {
                    self.loadRemoteLyricsIfNeeded()
                    self.loadMusicLyricsFromAccessibility(requestPermissionIfNeeded: false)
                }
            }
        }
    }

    // MARK: - Apple Music 歌词读取经验
    /*
     这段链路有几条容易在以后重构时踩回去的结论：
     1. AppleScript 的 `lyrics of current track` 对本地歌词有效，但多数 Apple
        Music 订阅曲目会返回空字符串；公开 MusicKit 接口也只给 `hasLyrics`，
        不提供歌词正文，所以二者不能作为订阅歌曲歌词的唯一来源。
     2. LRCLIB 只适合作为后备来源：它依赖曲库命中，缺少的新歌无法返回。
     3. Music 歌词面板会通过辅助功能树暴露每行文本，却不暴露“当前行”的
        selected/focused 状态。Music 会把正在唱的行自动滚到面板中央，因此
        当前行要用每行 AXPosition/AXSize 的中心点与面板中心点的距离判断。
     4. 展开卡片时若由本应用打开歌词面板，就保持它打开以持续取得滚动位置，
        收起时再关闭；若面板原本就是用户打开的，则绝不能替用户关闭。
     5. 这里只读取曲目元数据与界面文字，不录音、不保存音频。辅助功能客户端
        与 App Sandbox 不兼容，所以工程需保持 ENABLE_APP_SANDBOX=NO。
     6. macOS 的辅助功能授权与签名代码要求绑定。Sign to Run Locally 的临时
        签名每次构建可能改变 CDHash，因此开发完应只安装并签名一次；长期开发
        最好改用稳定的 Apple Development 签名，避免反复授权。
     */
    private func loadMusicLyricsFromAccessibility(requestPermissionIfNeeded: Bool) {
        guard currentSourceBundleIdentifier == "com.apple.Music",
              !isReadingAccessibilityLyrics else { return }

        guard AXIsProcessTrusted() else {
            lyricsAccessibilityPermissionNeeded = true
            guard requestPermissionIfNeeded else { return }

            if !hasPromptedForAccessibility {
                hasPromptedForAccessibility = true
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                let options = [promptKey: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            guard !isWaitingForAccessibilityPermission else { return }
            isWaitingForAccessibilityPermission = true
            accessibilityPermissionRetryCount = 0
            retryAccessibilityLyricsAfterPermissionChange()
            return
        }

        lyricsAccessibilityPermissionNeeded = false
        isReadingAccessibilityLyrics = true
        let expectedTrackIdentifier = musicArtworkTrackIdentifier
        let shouldKeepLyricsPanelOpen = isExpanded

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = Self.readMusicAccessibilitySnapshot(
                keepLyricsPanelOpen: shouldKeepLyricsPanelOpen
            )
            DispatchQueue.main.async {
                guard let self else {
                    if snapshot.openedLyricsPanel {
                        DispatchQueue.global(qos: .utility).async {
                            Self.closeMusicLyricsPanelIfVisible()
                        }
                    }
                    return
                }
                self.isReadingAccessibilityLyrics = false
                guard self.currentSourceBundleIdentifier == "com.apple.Music",
                      self.musicArtworkTrackIdentifier == expectedTrackIdentifier else {
                    if snapshot.openedLyricsPanel {
                        DispatchQueue.global(qos: .utility).async {
                            Self.closeMusicLyricsPanelIfVisible()
                        }
                    }
                    return
                }
                if snapshot.openedLyricsPanel {
                    if self.isExpanded {
                        self.ownsOpenMusicLyricsPanel = true
                    } else {
                        DispatchQueue.global(qos: .utility).async {
                            Self.closeMusicLyricsPanelIfVisible()
                        }
                    }
                }
                if !snapshot.title.isEmpty { self.trackTitle = snapshot.title }
                if !snapshot.artist.isEmpty { self.trackArtist = snapshot.artist }
                if !snapshot.album.isEmpty { self.trackAlbum = snapshot.album }
                if !snapshot.lyrics.isEmpty {
                    self.lyricsLines = snapshot.lyrics
                    self.lyricTimestamps = []
                    self.activeLyricIndex = snapshot.activeLyricIndex
                }
            }
        }
    }

    private func refreshAccessibilityLyricsIfNeeded() {
        let now = Date()
        guard isExpanded,
              currentSourceBundleIdentifier == "com.apple.Music",
              AXIsProcessTrusted(),
              !isReadingAccessibilityLyrics,
              now.timeIntervalSince(lastAccessibilityLyricsRefreshDate) >= 0.45 else { return }
        lastAccessibilityLyricsRefreshDate = now
        loadMusicLyricsFromAccessibility(requestPermissionIfNeeded: false)
    }

    private func retryAccessibilityLyricsAfterPermissionChange() {
        guard isExpanded,
              currentSourceBundleIdentifier == "com.apple.Music",
              accessibilityPermissionRetryCount < 30 else {
            isWaitingForAccessibilityPermission = false
            return
        }
        accessibilityPermissionRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.isWaitingForAccessibilityPermission = false
                self.lyricsAccessibilityPermissionNeeded = false
                self.loadMusicLyricsFromAccessibility(requestPermissionIfNeeded: false)
            } else {
                self.retryAccessibilityLyricsAfterPermissionChange()
            }
        }
    }

    nonisolated private static func readMusicAccessibilitySnapshot(
        keepLyricsPanelOpen: Bool
    )
        -> MusicAccessibilitySnapshot {
        guard let music = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.Music"
        }) else { return .empty }

        let application = AXUIElementCreateApplication(music.processIdentifier)
        guard let windows = accessibilityAttribute(
            application,
            key: kAXWindowsAttribute
        ) as? [AXUIElement] else { return .empty }

        let metadata = readNowPlayingMetadata(in: windows)

        var lyricGroup = findLyricsGroup(in: windows)
        var lyricsToggle: AXUIElement?
        var openedLyricsPanel = false

        if lyricGroup == nil {
            lyricsToggle = findElement(in: windows) { element in
                guard accessibilityText(element) == "歌词" else { return false }
                return accessibilityAttribute(element, key: kAXRoleAttribute) as? String
                    == kAXButtonRole
            }
            if let lyricsToggle,
               AXUIElementPerformAction(lyricsToggle, kAXPressAction as CFString) == .success {
                openedLyricsPanel = true
                usleep(450_000)
                lyricGroup = findLyricsGroup(in: windows)
            }
        }

        let lyricSnapshot = lyricGroup.map(readLyricSnapshot(in:)) ?? (
            lines: [],
            activeIndex: nil
        )
        if openedLyricsPanel, !keepLyricsPanelOpen, let lyricsToggle {
            _ = AXUIElementPerformAction(lyricsToggle, kAXPressAction as CFString)
        }
        return MusicAccessibilitySnapshot(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            lyrics: lyricSnapshot.lines,
            activeLyricIndex: lyricSnapshot.activeIndex,
            openedLyricsPanel: openedLyricsPanel && keepLyricsPanelOpen
        )
    }

    nonisolated private static func readNowPlayingMetadata(
        in roots: [AXUIElement]
    ) -> (title: String, artist: String, album: String) {
        guard let miniPlayer = findElement(in: roots, matching: { element in
            guard accessibilityText(element) == "迷你播放器" else { return false }
            return accessibilityAttribute(element, key: kAXRoleAttribute) as? String
                == kAXGroupRole
        }) else { return ("", "", "") }

        var textValues: [String] = []
        visitAccessibilityTree(miniPlayer) { element in
            guard accessibilityAttribute(element, key: kAXRoleAttribute) as? String
                    == kAXStaticTextRole else { return }
            let text = accessibilityText(element)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { textValues.append(text) }
        }

        let title = textValues.first ?? ""
        let detail = textValues.dropFirst().first ?? ""
        let pieces = detail.components(separatedBy: " — ")
        return (
            title,
            pieces.first ?? "",
            pieces.count > 1 ? pieces.dropFirst().joined(separator: " — ") : ""
        )
    }

    nonisolated private static func findLyricsGroup(
        in roots: [AXUIElement]
    ) -> AXUIElement? {
        findElement(in: roots) { element in
            guard accessibilityText(element) == "歌词" else { return false }
            return accessibilityAttribute(element, key: kAXRoleAttribute) as? String
                == kAXGroupRole
        }
    }

    nonisolated private static func readLyricSnapshot(
        in group: AXUIElement
    ) -> (lines: [String], activeIndex: Int?) {
        var entries: [(text: String, midpointY: CGFloat?)] = []
        visitAccessibilityTree(group) { element in
            guard accessibilityAttribute(element, key: kAXRoleAttribute) as? String
                    == kAXButtonRole else { return }
            let text = accessibilityText(element)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  text != "歌词",
                  !text.hasPrefix("创作者：") else { return }
            let midpointY: CGFloat?
            if let position = accessibilityPoint(element),
               let size = accessibilitySize(element),
               size.height > 0 {
                midpointY = position.y + size.height / 2
            } else {
                midpointY = nil
            }
            entries.append((text, midpointY))
        }

        let groupMidpointY: CGFloat?
        if let position = accessibilityPoint(group),
           let size = accessibilitySize(group),
           size.height > 0 {
            groupMidpointY = position.y + size.height / 2
        } else {
            groupMidpointY = nil
        }
        let activeIndex = groupMidpointY.flatMap { midpoint in
            entries.indices
                .filter { entries[$0].midpointY != nil }
                .min {
                    abs((entries[$0].midpointY ?? midpoint) - midpoint) <
                        abs((entries[$1].midpointY ?? midpoint) - midpoint)
                }
        }
        return (entries.map(\.text), activeIndex)
    }

    nonisolated private static func accessibilityPoint(_ element: AXUIElement) -> CGPoint? {
        guard let rawValue = accessibilityAttribute(element, key: kAXPositionAttribute),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let value = rawValue as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    nonisolated private static func accessibilitySize(_ element: AXUIElement) -> CGSize? {
        guard let rawValue = accessibilityAttribute(element, key: kAXSizeAttribute),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let value = rawValue as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    nonisolated private static func closeMusicLyricsPanelIfVisible() {
        guard let music = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.Music"
        }) else { return }
        let application = AXUIElementCreateApplication(music.processIdentifier)
        guard let windows = accessibilityAttribute(
            application,
            key: kAXWindowsAttribute
        ) as? [AXUIElement],
              findLyricsGroup(in: windows) != nil,
              let lyricsToggle = findElement(in: windows, matching: { element in
                  accessibilityText(element) == "歌词" &&
                      accessibilityAttribute(element, key: kAXRoleAttribute) as? String
                          == kAXButtonRole
              }) else { return }
        _ = AXUIElementPerformAction(lyricsToggle, kAXPressAction as CFString)
    }

    nonisolated private static func findElement(
        in roots: [AXUIElement],
        depth: Int = 0,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard depth <= 16 else { return nil }
        for root in roots {
            if predicate(root) { return root }
            if let children = accessibilityAttribute(
                root,
                key: kAXChildrenAttribute
            ) as? [AXUIElement],
               let match = findElement(
                   in: children,
                   depth: depth + 1,
                   matching: predicate
               ) {
                return match
            }
        }
        return nil
    }

    nonisolated private static func visitAccessibilityTree(
        _ element: AXUIElement,
        depth: Int = 0,
        visit: (AXUIElement) -> Void
    ) {
        guard depth <= 10 else { return }
        visit(element)
        guard let children = accessibilityAttribute(
            element,
            key: kAXChildrenAttribute
        ) as? [AXUIElement] else { return }
        children.forEach {
            visitAccessibilityTree($0, depth: depth + 1, visit: visit)
        }
    }

    nonisolated private static func accessibilityText(_ element: AXUIElement) -> String {
        for key in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
            if let text = accessibilityAttribute(element, key: key) as? String,
               !text.isEmpty {
                return text
            }
        }
        return ""
    }

    nonisolated private static func accessibilityAttribute(
        _ element: AXUIElement,
        key: String
    ) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            key as CFString,
            &value
        ) == .success else { return nil }
        return value as AnyObject?
    }

    /// Music 不会通过 AppleScript 暴露多数订阅曲目的同步歌词。
    /// 本地歌词为空时，按曲目签名向 LRCLIB 精确匹配；只发送歌曲元数据，
    /// 不会读取或上传音频文件。
    private func loadRemoteLyricsIfNeeded() {
        guard !trackTitle.isEmpty, !trackArtist.isEmpty else { return }
        let signature = [
            trackTitle,
            trackArtist,
            trackAlbum,
            String(Int(trackDuration.rounded()))
        ].joined(separator: "|")
        guard requestedLyricsSignature != signature else { return }
        requestedLyricsSignature = signature

        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: trackTitle),
            URLQueryItem(name: "artist_name", value: trackArtist),
            URLQueryItem(name: "album_name", value: trackAlbum),
            URLQueryItem(name: "duration", value: String(Int(trackDuration.rounded())))
        ]
        guard let url = components?.url else { return }

        lyricsRequest?.cancel()
        let request = Self.remoteLyricsRequest(url: url)
        lyricsRequest = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            if statusCode == 404 {
                DispatchQueue.main.async {
                    self?.searchRemoteLyrics(for: signature)
                }
                return
            }
            guard let data,
                  statusCode == 200,
                  let payload = try? JSONDecoder().decode(RemoteLyricsPayload.self, from: data) else { return }
            let parsed = Self.parseRemoteLyrics(synced: payload.syncedLyrics, plain: payload.plainLyrics)
            DispatchQueue.main.async {
                self?.applyRemoteLyrics(parsed, for: signature)
            }
        }
        lyricsRequest?.resume()
    }

    /// 精确曲目签名未命中时，使用歌名和歌手搜索，再选择时长最接近的结果。
    private func searchRemoteLyrics(for signature: String) {
        guard requestedLyricsSignature == signature,
              lyricsLines.isEmpty,
              !trackTitle.isEmpty,
              !trackArtist.isEmpty else { return }
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: trackTitle),
            URLQueryItem(name: "artist_name", value: trackArtist)
        ]
        guard let url = components?.url else { return }

        let request = Self.remoteLyricsRequest(url: url)
        let targetDuration = trackDuration
        lyricsRequest = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let candidates = try? JSONDecoder().decode([RemoteLyricsPayload].self, from: data) else { return }
            let candidatesWithLyrics = candidates.filter {
                !($0.syncedLyrics ?? "").isEmpty || !($0.plainLyrics ?? "").isEmpty
            }
            guard let payload = candidatesWithLyrics.min(by: {
                abs(($0.duration ?? targetDuration) - targetDuration) <
                    abs(($1.duration ?? targetDuration) - targetDuration)
            }) else { return }
            let parsed = Self.parseRemoteLyrics(synced: payload.syncedLyrics, plain: payload.plainLyrics)
            DispatchQueue.main.async {
                self?.applyRemoteLyrics(parsed, for: signature)
            }
        }
        lyricsRequest?.resume()
    }

    nonisolated private static func remoteLyricsRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("DynamicIsland/1.0 (OAKunO.DynamicIsland)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func applyRemoteLyrics(_ parsed: (lines: [String], timestamps: [Double]), for signature: String) {
        guard currentSourceBundleIdentifier == "com.apple.Music",
              requestedLyricsSignature == signature, lyricsLines.isEmpty,
              !parsed.lines.isEmpty else { return }
        lyricsLines = parsed.lines
        lyricTimestamps = parsed.timestamps
        activeLyricIndex = nil
    }

    /// Pure parsing stays on the URLSession callback queue. Only the guarded
    /// publication of a finished result belongs on the main actor.
    nonisolated static func parseRemoteLyrics(synced: String?, plain: String?) -> (lines: [String], timestamps: [Double]) {
        let syncedLines = parseSyncedLyrics(synced ?? "")
        if !syncedLines.isEmpty {
            return (syncedLines.map(\.line), syncedLines.map(\.time))
        }
        let plainLines = (plain ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (plainLines, [])
    }

    nonisolated private static func parseSyncedLyrics(
        _ lyrics: String
    ) -> [(time: Double, line: String)] {
        lyrics.components(separatedBy: .newlines).compactMap { rawLine in
            guard rawLine.first == "[",
                  let closingBracket = rawLine.firstIndex(of: "]") else { return nil }
            let timestamp = rawLine[rawLine.index(after: rawLine.startIndex)..<closingBracket]
            let components = timestamp.split(separator: ":")
            guard components.count == 2,
                  let minutes = Double(components[0]),
                  let seconds = Double(components[1]) else { return nil }
            let line = rawLine[rawLine.index(after: closingBracket)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            return (minutes * 60 + seconds, line)
        }
    }

    private func loadMusicArtworkFromMusicApp(force: Bool = false) {
        guard !isLoadingMusicArtwork else {
            if force { hasPendingMusicArtworkReload = true }
            return
        }
        isLoadingMusicArtwork = true

        let scriptSource = """
        tell application id "com.apple.Music"
            try
                return raw data of artwork 1 of current track
            on error
                return data of artwork 1 of current track
            end try
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let descriptor = AppleScriptRunner.run(scriptSource)
            let artwork = descriptor.flatMap { NSImage(data: $0.data) }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingMusicArtwork = false
                if self.currentSourceBundleIdentifier == "com.apple.Music",
                   let artwork {
                    self.applyMusicArtwork(artwork)
                }

                if self.hasPendingMusicArtworkReload {
                    self.hasPendingMusicArtworkReload = false
                    // 给 Music 很短的时间完成 current track 的内部切换，再读取新封面。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        self.loadMusicArtworkFromMusicApp()
                    }
                }
            }
        }
    }

    private func resolvedApplication(
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) -> NSRunningApplication? {
        let canonicalBundleIdentifier = canonicalBundleIdentifier(for: bundleIdentifier)
        if let canonicalBundleIdentifier,
           let application = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == canonicalBundleIdentifier
           }) {
            return application
        }
        return NSRunningApplication(processIdentifier: processIdentifier)
    }

    private func canonicalBundleIdentifier(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        if bundleIdentifier.hasPrefix("com.google.Chrome") { return "com.google.Chrome" }
        if bundleIdentifier.hasPrefix("com.apple.WebKit") { return "com.apple.Safari" }
        if bundleIdentifier.hasPrefix("com.microsoft.edgemac") { return "com.microsoft.edgemac" }
        if bundleIdentifier.hasPrefix("org.mozilla.firefox") { return "org.mozilla.firefox" }
        return bundleIdentifier
    }

    private func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let canonicalBundleIdentifier = canonicalBundleIdentifier(for: bundleIdentifier),
              let applicationURL = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: canonicalBundleIdentifier
              ) else { return nil }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    private func applyMusicArtwork(_ artwork: NSImage) {
        musicArtwork = artwork
        sourceIcon = artwork
        artworkThemeColor = Self.themeColor(from: artwork) ?? .systemPink
    }

    /// 将封面缩小采样后按色相聚类，优先选择饱和、可见度高的主色。
    /// 相比直接求全图平均值，这样不会把人物与背景混成灰褐色。
    private static func themeColor(from image: NSImage) -> NSColor? {
        let sampleSize = 28
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: sampleSize,
            pixelsHigh: sampleSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = NSSize(width: sampleSize, height: sampleSize)
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: sampleSize, height: sampleSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let hueBinCount = 18
        let neutralBin = hueBinCount
        var weights = Array(repeating: CGFloat.zero, count: hueBinCount + 1)
        var redTotals = weights
        var greenTotals = weights
        var blueTotals = weights

        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.12 else { continue }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let high = max(red, green, blue)
                let low = min(red, green, blue)
                let chroma = high - low
                let saturation = high > 0 ? chroma / high : 0
                let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
                let centerDistance = min(abs(luminance - 0.55) / 0.55, 1)
                let visibility = 1 - centerDistance * 0.42
                let weight = color.alphaComponent * visibility * (0.25 + saturation * 1.9)

                let bin: Int
                if saturation < 0.10 || chroma < 0.02 {
                    bin = neutralBin
                } else {
                    let rawHue: CGFloat
                    if high == red {
                        rawHue = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
                    } else if high == green {
                        rawHue = (blue - red) / chroma + 2
                    } else {
                        rawHue = (red - green) / chroma + 4
                    }
                    let hue = (rawHue / 6 + 1).truncatingRemainder(dividingBy: 1)
                    bin = min(Int(hue * CGFloat(hueBinCount)), hueBinCount - 1)
                }

                weights[bin] += weight
                redTotals[bin] += red * weight
                greenTotals[bin] += green * weight
                blueTotals[bin] += blue * weight
            }
        }

        guard let dominantBin = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[dominantBin] > 0 else { return nil }
        let weight = weights[dominantBin]
        var result = NSColor(
            srgbRed: redTotals[dominantBin] / weight,
            green: greenTotals[dominantBin] / weight,
            blue: blueTotals[dominantBin] / weight,
            alpha: 1
        )
        let luminance = result.redComponent * 0.2126 +
            result.greenComponent * 0.7152 +
            result.blueComponent * 0.0722
        if luminance < 0.30 {
            result = result.blended(withFraction: 0.34, of: .white) ?? result
        } else if luminance > 0.88 {
            result = result.blended(withFraction: 0.14, of: .black) ?? result
        }
        return result
    }

    private func clearPlaybackSource() {
        guard isPlaying || isExpanded || sourceIcon != nil || sourceName != nil else { return }
        isPlaying = false
        collapseMusicCard()
        currentSourceBundleIdentifier = nil
        sourceIcon = nil
        artworkThemeColor = nil
        sourceName = nil
        activeLyricIndex = nil
    }

    private func startMonitoringMusicNotifications() {
        let center = DistributedNotificationCenter.default()
        let names = ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"]
        musicNotificationObservers = names.map { rawName in
            center.addObserver(
                forName: Notification.Name(rawName),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleMusicNotification(notification)
            }
        }
    }

    private func handleMusicNotification(_ notification: Notification) {
        // Music 的分布式通知可比 AppleScript 更早给出基本曲目信息，
        // 先用它填充歌名/歌手，再由轮询补齐进度与歌词。
        if let title = notification.userInfo?["Name"] as? String, !title.isEmpty {
            trackTitle = title
        }
        if let artist = notification.userInfo?["Artist"] as? String, !artist.isEmpty {
            trackArtist = artist
        }
        if let totalMilliseconds = notification.userInfo?["Total Time"] as? NSNumber {
            trackDuration = max(0, totalMilliseconds.doubleValue / 1_000)
        }
        if lyricsLines.isEmpty {
            loadRemoteLyricsIfNeeded()
        }

        let state = notification.userInfo?["Player State"] as? String ??
            notification.userInfo?["playerState"] as? String ??
            notification.userInfo?["state"] as? String
        guard let normalizedState = state?.lowercased() else { return }

        if normalizedState.contains("playing") {
            musicIsPlaying = true
            refreshMusicArtworkIfNeeded(force: true)
            refresh()
        } else if normalizedState.contains("paused") || normalizedState.contains("stopped") {
            musicIsPlaying = false
            if currentSourceBundleIdentifier == "com.apple.Music" || sourceName == "Music" {
                clearPlaybackSource()
            }
        }
    }
}

nonisolated private struct RemoteLyricsPayload: Decodable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let duration: Double?
}

private struct MusicAccessibilitySnapshot: Sendable {
    let title: String
    let artist: String
    let album: String
    let lyrics: [String]
    let activeLyricIndex: Int?
    let openedLyricsPanel: Bool

    nonisolated static let empty = MusicAccessibilitySnapshot(
        title: "",
        artist: "",
        album: "",
        lyrics: [],
        activeLyricIndex: nil,
        openedLyricsPanel: false
    )
}

/// 读取指定进程的真实 PCM 输出，用连续静音判断浏览器是否已经暂停。
/// Core Audio 的 `isRunningOutput` 只表示 IO 流仍存在，Chrome 暂停后可能长时间不关闭它。
private nonisolated final class ProcessAudioActivityMonitor {
    private let callbackQueue = DispatchQueue(
        label: "OAKunO.DynamicIsland.audio-activity",
        qos: .userInteractive
    )
    private let activityChanged: @MainActor @Sendable (Bool) -> Void
    private var tapIdentifier = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceIdentifier = AudioObjectID(kAudioObjectUnknown)
    private var ioProcIdentifier: AudioDeviceIOProcID?
    private var isAudible: Bool?
    private var lastAudibleSampleTime = CFAbsoluteTimeGetCurrent()

    init?(
        processIdentifier: pid_t,
        activityChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.activityChanged = activityChanged
        guard start(processIdentifier: processIdentifier) else { return nil }
    }

    deinit {
        stop()
    }

    private func start(processIdentifier: pid_t) -> Bool {
        guard let processObjectIdentifier = processObjectIdentifier(
            for: processIdentifier
        ) else { return false }

        let description = CATapDescription(
            stereoMixdownOfProcesses: [processObjectIdentifier]
        )
        description.name = "DynamicIsland Browser Activity"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        guard AudioHardwareCreateProcessTap(
            description,
            &tapIdentifier
        ) == noErr else { return false }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamicIsland Browser Activity",
            kAudioAggregateDeviceUIDKey: "OAKunO.DynamicIsland.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]

        guard AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceIdentifier
        ) == noErr else {
            AudioHardwareDestroyProcessTap(tapIdentifier)
            tapIdentifier = AudioObjectID(kAudioObjectUnknown)
            return false
        }

        var createdIOProc: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdIOProc,
            aggregateDeviceIdentifier,
            callbackQueue
        ) { [weak self] _, inputData, _, _, _ in
            self?.consume(inputData)
        }
        guard createStatus == noErr, let createdIOProc else {
            stop()
            return false
        }

        ioProcIdentifier = createdIOProc
        guard AudioDeviceStart(
            aggregateDeviceIdentifier,
            createdIOProc
        ) == noErr else {
            stop()
            return false
        }
        return true
    }

    private func processObjectIdentifier(for processIdentifier: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableProcessIdentifier = processIdentifier
        var processObjectIdentifier = AudioObjectID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &mutableProcessIdentifier) { processIdentifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(bitPattern: kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                processIdentifierPointer,
                &outputSize,
                &processObjectIdentifier
            )
        }
        guard status == noErr,
              processObjectIdentifier != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return processObjectIdentifier
    }

    private func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        let mutableInputData = UnsafeMutablePointer<AudioBufferList>(
            mutating: inputData
        )
        let buffers = UnsafeMutableAudioBufferListPointer(mutableInputData)
        var peak: Float = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            var index = 0
            while index < sampleCount {
                peak = max(peak, abs(samples[index]))
                index += 8
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        if peak > 0.0008 {
            lastAudibleSampleTime = now
            setAudible(true)
        } else if now - lastAudibleSampleTime >= 0.60 {
            setAudible(false)
        }
    }

    private func setAudible(_ newValue: Bool) {
        guard isAudible != newValue else { return }
        isAudible = newValue
        DispatchQueue.main.async { [activityChanged] in
            MainActor.assumeIsolated {
                activityChanged(newValue)
            }
        }
    }

    private func stop() {
        if let ioProcIdentifier,
           aggregateDeviceIdentifier != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateDeviceIdentifier, ioProcIdentifier)
            AudioDeviceDestroyIOProcID(aggregateDeviceIdentifier, ioProcIdentifier)
            self.ioProcIdentifier = nil
        }
        if aggregateDeviceIdentifier != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceIdentifier)
            aggregateDeviceIdentifier = AudioObjectID(kAudioObjectUnknown)
        }
        if tapIdentifier != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapIdentifier)
            tapIdentifier = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

private nonisolated struct AudioOutputProcess: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

/// 使用公开 Core Audio HAL 属性查找正在运行输出流的进程。
/// 所有方法都在 `halQueue` 上调用，显式声明为 nonisolated 以避免被默认
/// 的 MainActor 隔离绑到主线程。
private nonisolated enum CoreAudioPlaybackDetector {
    static func activeOutputProcess() -> AudioOutputProcess? {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        var byteCount: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &listAddress,
            0,
            nil,
            &byteCount
        ) == noErr, byteCount > 0 else { return nil }

        var processObjects = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            systemObject,
            &listAddress,
            0,
            nil,
            &byteCount,
            &processObjects
        ) == noErr else { return nil }

        for processObject in processObjects {
            guard readUInt32(
                from: processObject,
                selector: kAudioProcessPropertyIsRunningOutput
            ) == 1,
            let rawProcessIdentifier = readUInt32(
                from: processObject,
                selector: kAudioProcessPropertyPID
            ) else { continue }

            let processIdentifier = pid_t(bitPattern: rawProcessIdentifier)
            guard processIdentifier != getpid() else { continue }
            let bundleIdentifier = readBundleIdentifier(from: processObject)
            guard isSupportedAudioProcess(bundleIdentifier) else { continue }

            return AudioOutputProcess(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        }
        return nil
    }

    private static func readUInt32(
        from object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private static func readBundleIdentifier(from object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func isSupportedAudioProcess(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        // Chrome 的实际输出可能来自 Helper 进程，因此用前缀匹配并在上层
        // 归一化为 com.google.Chrome；其余所有 App（包括剪映和 ToDesk）均忽略。
        return bundleIdentifier == "com.apple.Music" ||
            bundleIdentifier.hasPrefix("com.google.Chrome")
    }
}

/// MediaRemote 没有公开 SDK 头文件，因此运行时加载；加载失败时功能自动停用。
private final class MediaRemoteAPI {
    typealias IsPlayingCallback = @convention(block) (Bool) -> Void
    typealias ProcessIdentifierCallback = @convention(block) (pid_t) -> Void
    // C API 实际回传 CFDictionaryRef。直接声明成 NSDictionary 会在新版
    // macOS 上产生错误桥接，表现为字典存在但所有字段均读取失败。
    typealias NowPlayingInfoCallback = @convention(block) (CFDictionary) -> Void
    typealias GetIsPlaying = @convention(c) (
        DispatchQueue,
        @escaping IsPlayingCallback
    ) -> Void
    typealias GetApplicationPID = @convention(c) (
        DispatchQueue,
        @escaping ProcessIdentifierCallback
    ) -> Void
    typealias GetNowPlayingInfo = @convention(c) (
        DispatchQueue,
        @escaping NowPlayingInfoCallback
    ) -> Void

    let getIsPlaying: GetIsPlaying
    let getApplicationPID: GetApplicationPID
    let getNowPlayingInfo: GetNowPlayingInfo?

    private let handle: UnsafeMutableRawPointer

    init?() {
        let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { return nil }
        guard let isPlayingSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying"),
              let processIdentifierSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") else {
            dlclose(handle)
            return nil
        }

        self.handle = handle
        getIsPlaying = unsafeBitCast(isPlayingSymbol, to: GetIsPlaying.self)
        getApplicationPID = unsafeBitCast(processIdentifierSymbol, to: GetApplicationPID.self)
        if let nowPlayingInfoSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(nowPlayingInfoSymbol, to: GetNowPlayingInfo.self)
        } else {
            getNowPlayingInfo = nil
        }
    }

    deinit {
        dlclose(handle)
    }
}

/// AppleScript / Apple Event 组件不是线程安全的：多个队列并发调用
/// `NSAppleScript.executeAndReturnError` 会互相争用全局状态，甚至在主线程
/// 等待时把整个 App 卡死。所有脚本调用都必须经过这个串行队列。
nonisolated enum AppleScriptRunner {
    private static let queue = DispatchQueue(
        label: "OAKunO.DynamicIsland.applescript",
        qos: .userInitiated
    )

    /// 串行执行 AppleScript，返回结果描述符；脚本失败时返回 nil。
    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        queue.sync {
            var error: NSDictionary?
            return NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}
