import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

@MainActor
final class ScreenRecordingController: NSObject, ObservableObject, SCStreamDelegate {
    enum Phase { case idle, selecting, countdown, recording, paused, saving }
    static let shared = ScreenRecordingController()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var countdownRemaining = 0
    @Published private(set) var isTransitioning = false
    @Published private(set) var lastSavedURL: URL?
    @Published var errorMessage: String?

    let settings: RecordingSettings
    private let contentProvider: () async throws -> SCShareableContent
    private var settingsObservation: AnyCancellable?
    private var operation: Task<Void, Never>?
    private let selector = RecordingTargetSelector()
    private var stream: SCStream?
    private var captureFilter: SCContentFilter?
    private var captureConfiguration: SCStreamConfiguration?
    private var segment: RecordingSegment?
    private var segmentURLs: [URL] = []
    private var temporaryDirectory: URL?
    private var destination: URL?
    private var accessedDirectory: URL?
    private var clock = RecordingClock()
    private var tick: Timer?

    init(settings: RecordingSettings? = nil,
         contentProvider: @escaping () async throws -> SCShareableContent = {
             try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
         }) {
        self.settings = settings ?? .shared
        self.contentProvider = contentProvider
        super.init()
        settingsObservation = self.settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isBusy: Bool { phase != .idle }
    var isCapturing: Bool { phase == .recording || phase == .paused }
    var hasCompactStatus: Bool { isCapturing || phase == .countdown }
    var isPaused: Bool { phase == .paused }
    var elapsedTime: TimeInterval { clock.elapsed(at: ProcessInfo.processInfo.systemUptime) }
    var timeText: String { RecordingClock.text(seconds: elapsedTime) }
    var compactText: String { phase == .countdown ? "\(countdownRemaining)" : timeText }
    var compactActivity: IslandTimerActivity {
        guard hasCompactStatus && settings.configuration.showsStatus else { return .off }
        if isPaused { return elapsedSeconds >= 3600 ? .pausedHours : .pausedMinutes }
        return elapsedSeconds >= 3600 ? .runningHours : .runningMinutes
    }
    func displaySnapshot(_ base: IslandDisplaySettingsSnapshot) -> IslandDisplaySettingsSnapshot {
        base.forRecording(isActive: hasCompactStatus, showsStatus: settings.configuration.showsStatus,
                          coexists: settings.configuration.coexistsWithOtherActivities)
    }

    func start() {
        guard phase == .idle else { return }
        phase = .selecting
        errorMessage = nil
        lastSavedURL = nil
        elapsedSeconds = 0
        clock = .init()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { operation = nil }
            do { try await prepareAndStart() }
            catch is CancellationError { await discardPreparation() }
            catch {
                errorMessage = error.localizedDescription
                await discardPreparation()
            }
        }
    }

    func cancelPreparation() {
        guard phase == .selecting || phase == .countdown else { return }
        operation?.cancel()
        selector.cancel()
    }

    func togglePause() {
        guard isCapturing, !isTransitioning else { return }
        isTransitioning = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { isTransitioning = false; operation = nil }
            do {
                if phase == .recording {
                    clock.pause(at: ProcessInfo.processInfo.systemUptime)
                    refreshElapsed()
                    try await finishSegment()
                    // Stop capture as well, releasing the microphone during a pause.
                    try await stream?.stopCapture()
                    stream = nil
                    phase = .paused
                } else {
                    try await startSegment()
                    clock.resume(at: ProcessInfo.processInfo.systemUptime)
                    phase = .recording
                }
            } catch { await finishRecording(interruption: error) }
        }
    }

    func stop() {
        guard isCapturing, !isTransitioning else { return }
        isTransitioning = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { isTransitioning = false; operation = nil }
            await finishRecording()
        }
    }

    func finishBeforeQuit() async {
        cancelPreparation()
        await operation?.value
        if isCapturing { await finishRecording() }
    }

    private func prepareAndStart() async throws {
        let configuration = settings.configuration.validated
        // 直接由实际录制所用的框架确认授权。旧的 CoreGraphics 预检查
        // 可能仍报告未授权，不能据此拦截已经在系统设置中开启的录屏。
        let content: SCShareableContent
        do {
            content = try await contentProvider()
        } catch {
            let failure = error as NSError
            if failure.domain == SCStreamErrorDomain,
               failure.code == SCStreamError.Code.userDeclined.rawValue {
                throw RecordingFailure.message("系统尚未允许当前版本的灵动岛录屏。请在系统设置 → 隐私与安全性 → 录屏与系统录音中允许 DynamicIsland。如果已经开启，请退出并重新打开灵动岛后重试。")
            }
            throw error
        }
        try Task.checkCancellation()
        if configuration.microphone {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else {
                throw RecordingFailure.message("请在系统设置 → 隐私与安全性 → 麦克风中允许灵动岛使用麦克风，或关闭录屏的麦克风选项。")
            }
        }
        try Task.checkCancellation()
        guard let target = await selector.select(source: configuration.source, content: content) else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        streamConfiguration.queueDepth = 5
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = configuration.systemAudio
        streamConfiguration.captureMicrophone = configuration.microphone
        streamConfiguration.sampleRate = 48000
        streamConfiguration.channelCount = 2
        streamConfiguration.ignoreShadowsSingleWindow = true
        let filter: SCContentFilter
        let size: CGSize
        let scale: CGFloat
        switch target {
        case let .display(display, region):
            let islandID = WindowManager.window.map { CGWindowID($0.windowNumber) }
            let excluded = configuration.includesIsland ? [] : content.windows.filter { $0.windowID == islandID }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            size = region?.size ?? display.frame.size
            scale = NSScreen.screens.first { $0.recordingDisplayID == display.displayID }?.backingScaleFactor ?? 2
            if let region { streamConfiguration.sourceRect = region }
        case let .window(window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = filter.contentRect.size
            scale = CGFloat(filter.pointPixelScale)
        }
        // H.264 requires even dimensions. Preserve Retina detail up to 4096px
        // so large external displays stay within widely supported encoder sizes.
        let outputScale = min(scale, 4096 / max(size.width, size.height))
        streamConfiguration.width = max(2, Int(size.width * outputScale) / 2 * 2)
        streamConfiguration.height = max(2, Int(size.height * outputScale) / 2 * 2)
        captureFilter = filter
        captureConfiguration = streamConfiguration
        if configuration.countdown > 0 {
            countdownRemaining = configuration.countdown
            phase = .countdown
            let deadline = ProcessInfo.processInfo.systemUptime + Double(configuration.countdown)
            while ProcessInfo.processInfo.systemUptime < deadline {
                countdownRemaining = max(1, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try Task.checkCancellation()
        try prepareDestination()
        isTransitioning = true
        defer { isTransitioning = false }
        try await startSegment()
        try Task.checkCancellation()
        clock.resume(at: ProcessInfo.processInfo.systemUptime)
        phase = .recording
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func prepareDestination() throws {
        let directory = settings.directory
        if directory.startAccessingSecurityScopedResource() { accessedDirectory = directory }
        let defaultDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        if directory == defaultDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw RecordingFailure.message("保存文件夹不可写，请在「录屏设置」中重新选择保存位置。")
        }
        let url = directory.appendingPathComponent(RecordingFileName.name(at: Date()))
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingFailure.message("同名录屏文件已存在，请稍后重新开始录制。")
        }
        destination = url
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicIsland-Recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        temporaryDirectory = temporary
        segmentURLs.removeAll()
    }

    private func startSegment() async throws {
        guard let captureFilter, let captureConfiguration, let temporaryDirectory else {
            throw RecordingFailure.message("录屏尚未准备好。")
        }
        let stream = SCStream(filter: captureFilter, configuration: captureConfiguration, delegate: self)
        self.stream = stream
        let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        let next = RecordingSegment(url: url) { [weak self] failed, error in
            guard self?.segment === failed else { return }
            self?.captureFailed(error)
        }
        segment = next
        try stream.addRecordingOutput(next.output)
        try await stream.startCapture()
        try await next.waitForStart()
    }

    private func finishSegment() async throws {
        guard let segment, let stream else { return }
        defer { self.segment = nil }
        try stream.removeRecordingOutput(segment.output)
        try await segment.waitForFinish()
        segmentURLs.append(segment.url)
    }

    private func finishRecording(interruption: Error? = nil) async {
        phase = .saving
        clock.pause(at: ProcessInfo.processInfo.systemUptime)
        refreshElapsed()
        tick?.invalidate()
        tick = nil
        var failure = interruption
        do { try await finishSegment() } catch { failure = error }
        do { try await stream?.stopCapture() } catch { if failure == nil { failure = error } }
        stream = nil
        do {
            guard let destination else { throw RecordingExportError.cannotCreateExport }
            try await RecordingExporter.export(segments: segmentURLs, to: destination)
            lastSavedURL = destination
            if let failure { errorMessage = "录制意外中断，已保存可用内容。\n\(failure.localizedDescription)" }
            cleanUp(removeTemporaryFiles: true)
        } catch {
            let recovery = temporaryDirectory.map { "\n原始录制片段保留在：\($0.path)" } ?? ""
            errorMessage = "录屏保存失败：\((failure ?? error).localizedDescription)\(recovery)"
            if let destination { try? FileManager.default.removeItem(at: destination) }
            cleanUp(removeTemporaryFiles: false)
        }
        phase = .idle
    }

    private func discardPreparation() async {
        // Cancellation may arrive while the native stream is starting.
        if let stream { try? await stream.stopCapture() }
        if let segment { try? await segment.waitForFinish() }
        stream = nil
        cleanUp(removeTemporaryFiles: true)
        phase = .idle
    }

    private func cleanUp(removeTemporaryFiles: Bool) {
        tick?.invalidate()
        tick = nil
        if removeTemporaryFiles, let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        segment = nil
        captureFilter = nil
        captureConfiguration = nil
        segmentURLs.removeAll()
        destination = nil
        accessedDirectory?.stopAccessingSecurityScopedResource()
        accessedDirectory = nil
    }

    private func refreshElapsed() {
        let seconds = Int(elapsedTime)
        if elapsedSeconds != seconds { elapsedSeconds = seconds }
    }

    private func captureFailed(_ error: Error) {
        guard isCapturing, !isTransitioning else { return }
        isTransitioning = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { isTransitioning = false; operation = nil }
            await finishRecording(interruption: error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard self?.stream === stream else { return }
            self?.captureFailed(error)
        }
    }
}

private enum RecordingFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}

@MainActor
private final class RecordingSegment: NSObject, SCRecordingOutputDelegate {
    let url: URL
    private(set) var output: SCRecordingOutput!
    private var startResult: Result<Void, Error>?
    private var finishResult: Result<Void, Error>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private let failure: (RecordingSegment, Error) -> Void

    init(url: URL, failure: @escaping (RecordingSegment, Error) -> Void) {
        self.url = url
        self.failure = failure
        super.init()
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.outputFileType = .mp4
        configuration.videoCodecType = .h264
        output = SCRecordingOutput(configuration: configuration, delegate: self)
    }

    func waitForStart() async throws {
        if let startResult { return try startResult.get() }
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, startResult == nil else { return }
                settleStart(.failure(RecordingFailure.message("录屏启动超时，请重新选择录制目标。")))
            }
        }
    }
    func waitForFinish() async throws {
        if let finishResult { return try finishResult.get() }
        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, finishResult == nil else { return }
                settleFinish(.failure(RecordingFailure.message("录屏片段保存超时。")))
            }
        }
    }
    private func settleStart(_ result: Result<Void, Error>) {
        guard startResult == nil else { return }
        startResult = result
        startContinuation?.resume(with: result)
        startContinuation = nil
    }
    private func settleFinish(_ result: Result<Void, Error>) {
        guard finishResult == nil else { return }
        finishResult = result
        finishContinuation?.resume(with: result)
        finishContinuation = nil
    }
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.settleStart(.success(())) }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.settleFinish(.success(()))
            self?.settleStart(.failure(RecordingFailure.message("录制在首帧到达前已结束。")))
        }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            settleStart(.failure(error))
            settleFinish(.failure(error))
            failure(self, error)
        }
    }
}
