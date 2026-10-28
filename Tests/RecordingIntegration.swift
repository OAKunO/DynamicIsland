import AppKit
import AVFoundation
import Foundation

@main
struct RecordingIntegration {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        var clock = RecordingClock()
        clock.resume(at: 100)
        clock.pause(at: 165)
        check(clock.elapsed(at: 900) == 65, "Pause freezes elapsed time")
        clock.resume(at: 1000)
        clock.resume(at: 1100)
        clock.pause(at: 1035)
        check(clock.elapsed(at: 9999) == 100, "Resume excludes the pause and cannot restart an active clock")
        check(RecordingClock.text(seconds: 1.37) == "01.37", "Under one minute shows seconds and hundredths")
        check(RecordingClock.text(seconds: 67.30) == "01:07.30", "Under one hour shows minutes, seconds and hundredths")
        check(RecordingClock.text(seconds: 5371.99) == "01:29:31", "Hour-long recordings hide hundredths")
        check(RecordingClock.text(seconds: -1) == "00.00", "Negative elapsed time is clamped")
        check(RecordingClock.text(seconds: 59.999) == "59.99", "Hundredths truncate before the minute boundary")
        check(RecordingClock.text(seconds: 60) == "01:00.00", "The minute boundary changes format")
        check(RecordingClock.text(seconds: 3599.999) == "59:59.99", "Hundredths truncate before the hour boundary")
        check(RecordingClock.text(seconds: 3601) == "01:00:01", "Long recordings include hours")
        var fractionalClock = RecordingClock()
        fractionalClock.resume(at: 100)
        fractionalClock.pause(at: 101.37)
        check(RecordingClock.text(seconds: fractionalClock.elapsed(at: 900)) == "01.37", "Pause preserves hundredths")
        fractionalClock.resume(at: 1000)
        check(RecordingClock.text(seconds: fractionalClock.elapsed(at: 1065.93)) == "01:07.30", "Resuming preserves hundredths and excludes the pause")
        let namingZone = TimeZone(identifier: "Asia/Shanghai")!
        let namingDate = Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: namingZone, year: 2026, month: 10, day: 9, hour: 20, minute: 50, second: 27))!
        check(RecordingFileName.name(at: namingDate, timeZone: namingZone) == "灵动岛录频20261009205027.mp4",
              "Recording names use local Gregorian dates precise to the second")

        let suite = "DynamicIsland.RecordingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RecordingSettings(defaults: defaults)
        check(preferences.configuration.countdown == 3 && preferences.configuration.includesIsland,
              "Defaults use three-second countdown and include the island")
        preferences.configuration.source = .region
        preferences.configuration.microphone = true
        preferences.configuration.systemAudio = false
        preferences.configuration.countdown = 10
        preferences.configuration.coexistsWithOtherActivities = false
        let restored = RecordingSettings(defaults: defaults)
        check(restored.configuration == preferences.configuration, "All recording preferences survive relaunch")
        preferences.configuration.countdown = 7
        check(RecordingSettings(defaults: defaults).configuration.countdown == 3,
              "Invalid countdown values are normalized")

        let base = IslandDisplaySettingsSnapshot(hiddenFeatures: [.usb])
        let exclusive = base.forRecording(isActive: true, showsStatus: true, coexists: false)
        check(exclusive.isEnabled(.recording) && !exclusive.isEnabled(.music) && !exclusive.isEnabled(.codex),
              "Exclusive mode suppresses other content without changing its preferences")
        check(base.isEnabled(.music) && base.isEnabled(.codex), "Exclusive presentation preserves the original snapshot")
        check(base.forRecording(isActive: true, showsStatus: false, coexists: false) == base,
              "Hiding recording status restores other activities")
        check(base.forRecording(isActive: false, showsStatus: true, coexists: false) == base,
              "Stopping recording restores other activities")
        check(base.forRecording(isActive: true, showsStatus: true, coexists: true) == base,
              "Coexist mode preserves other content")
        let solo = CompactActivityLayout(visible: [.recording])
        check(solo.dual == .recording && solo.left.isEmpty && solo.right.isEmpty,
              "A lone recording uses a dot on the left and time on the right")
        let pair = CompactActivityLayout(visible: [.audio, .recording])
        check(pair.dual == nil && pair.right == [.recording], "Paired recording puts dot and time on one side")
        let arrival = CompactActivityLayout(visible: [.audio, .timer, .recording], previousOrder: [.recording, .audio])
        check(arrival.left == [.recording] && arrival.dual == .timer, "New activities preserve recording's existing lane")
        var configuration = IslandLengthConfiguration(music: true, recording: .pausedHours)
        configuration.agents = [.init(provider: .codex, statuses: [.working])]
        check(configuration.compactActivities.contains(.recording), "Recording contributes to compact width")
        let width = WindowManager.defaultSize(for: configuration).width
        configuration.recording = .off
        check(width > WindowManager.defaultSize(for: configuration).width, "Hour-length recording reserves additional width")
        configuration.recording = .runningMinutes
        let hidden = IslandDisplaySettingsSnapshot(hiddenFeatures: [.recording]).filtering(configuration)
        check(hidden.recording == .off && !hidden.compactActivities.contains(.recording), "Hidden recording does not affect width")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try preferences.setDirectory(directory)
        check(RecordingSettings(defaults: defaults).directory.standardizedFileURL == directory.standardizedFileURL,
              "A chosen save directory survives relaunch through a bookmark")
        let first = directory.appendingPathComponent("first.mov")
        let second = directory.appendingPathComponent("second.mov")
        try await makeSegment(at: first, frames: 18, red: true, audio: true)
        try await makeSegment(at: second, frames: 24, red: false, audio: true)
        let output = directory.appendingPathComponent("joined.mp4")
        try await RecordingExporter.export(segments: [first, second], to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        check(abs(duration - 1.4) < 0.1, "Joined video contains only recorded segments, with no paused gap")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        check(videoTracks.count == 1, "Export produces one video track")
        check(audioTracks.count == 1, "System audio and microphone are mixed into one playable audio track")
        let size = try await videoTracks[0].load(.naturalSize)
        check(size.width == 64 && size.height == 48, "Export preserves source geometry")
        let pixels = try await readFrames(asset: asset, track: videoTracks[0])
        check(pixels.first?.0 ?? 0 > 150 && pixels.first?.1 ?? 255 < 80, "The first segment's red frames are retained")
        check(pixels.last?.1 ?? 0 > 150 && pixels.last?.0 ?? 255 < 80, "The resumed segment's green frames are retained")
        let samples = try readAudio(asset: asset, track: audioTracks[0])
        func strength(_ frequency: Double) -> Double {
            let values = Array(samples.dropFirst(4800).prefix(9600))
            let real = values.enumerated().reduce(0.0) { $0 + Double($1.element) * cos(2 * .pi * frequency * Double($1.offset) / 48000) }
            let imaginary = values.enumerated().reduce(0.0) { $0 + Double($1.element) * sin(2 * .pi * frequency * Double($1.offset) / 48000) }
            return hypot(real, imaginary) / Double(max(1, values.count))
        }
        check(strength(440) > 0.03 && strength(880) > 0.03,
              "The exported audio contains both system and microphone test tones")

        let silent = directory.appendingPathComponent("silent.mov")
        try await makeSegment(at: silent, frames: 6, red: true, audio: false)
        let silentOutput = directory.appendingPathComponent("silent-output.mp4")
        try await RecordingExporter.export(segments: [silent], to: silentOutput)
        let silentTracks = try await AVURLAsset(url: silentOutput).loadTracks(withMediaType: .audio)
        check(silentTracks.isEmpty, "Both audio switches off produces video without an audio track")
        for tone in [440.0, 880.0] {
            let single = directory.appendingPathComponent("single-\(Int(tone)).mov")
            let singleOutput = directory.appendingPathComponent("single-\(Int(tone)).mp4")
            try await makeSegment(at: single, frames: 6, red: true, audio: true, tones: [tone])
            try await RecordingExporter.export(segments: [single], to: singleOutput)
            let tracks = try await AVURLAsset(url: singleOutput).loadTracks(withMediaType: .audio)
            check(tracks.count == 1, "An individual system or microphone source is retained by passthrough export")
        }
        do {
            try await RecordingExporter.export(segments: [], to: directory.appendingPathComponent("empty.mp4"))
            fatalError("Empty recordings must not appear successfully saved")
        } catch RecordingExportError.noVideo { checks += 1 }
        print("PASS: \(checks) recording clock, preferences, layout, video concatenation and audio mix checks")
    }

    @MainActor static func makeSegment(at url: URL, frames: Int, red: Bool, audio: Bool,
                                     tones: [Double] = [440, 880]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 30]
        ])
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        var audioInputs: [AVAssetWriterInput] = []
        if audio {
            for _ in tones {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000
                ])
                writer.add(input)
                audioInputs.append(input)
            }
        }
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &pixel)
            let buffer = pixel!
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<48 { for x in 0..<64 {
                let offset = y * stride + x * 4
                bytes[offset] = 0; bytes[offset + 1] = red ? 0 : 220
                bytes[offset + 2] = red ? 220 : 0; bytes[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        video.markAsFinished()
        for (index, input) in audioInputs.enumerated() {
            let toneURL = url.deletingLastPathComponent().appendingPathComponent("tone-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: toneURL) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let count = AVAudioFrameCount(frames * 1600)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            pcm.frameLength = count
            for sample in 0..<Int(count) {
                pcm.floatChannelData![0][sample] = Float(0.3 * sin(2 * .pi * tones[index] * Double(sample) / 48000))
            }
            try AVAudioFile(forWriting: toneURL, settings: format.settings).write(from: pcm)
            let toneAsset = AVURLAsset(url: toneURL)
            let reader = try AVAssetReader(asset: toneAsset)
            let track = try await toneAsset.loadTracks(withMediaType: .audio)[0]
            let source = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(source)
            guard reader.startReading() else { throw reader.error! }
            while let sample = source.copyNextSampleBuffer() {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard input.append(sample) else { throw writer.error! }
            }
            input.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
    }

    @MainActor static func readFrames(asset: AVAsset, track: AVAssetTrack) async throws -> [(UInt8, UInt8)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var colors: [(UInt8, UInt8)] = []
        while let sample = output.copyNextSampleBuffer(), let pixel = sample.imageBuffer {
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let data = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            colors.append((data[2], data[1]))
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        }
        guard reader.status == .completed else { throw reader.error! }
        return colors
    }

    @MainActor static func readAudio(asset: AVAsset, track: AVAssetTrack) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var values: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let result = chunk.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            guard result == kCMBlockBufferNoErr else { fatalError("Unable to decode audio") }
            values.append(contentsOf: chunk)
        }
        guard reader.status == .completed else { throw reader.error! }
        return values
    }
}
