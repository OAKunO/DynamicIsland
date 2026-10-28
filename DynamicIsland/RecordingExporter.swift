import AVFoundation
import Foundation

enum RecordingExportError: LocalizedError {
    case noVideo, cannotCreateExport
    var errorDescription: String? {
        switch self {
        case .noVideo: "未获得有效画面，请重新录制。"
        case .cannotCreateExport: "无法创建录屏文件。"
        }
    }
}

/// Each pause finishes a segment. Concatenating just these segments removes the
/// paused interval from both video and audio, without timestamp drift on resume.
@MainActor
enum RecordingExporter {
    static func export(segments: [URL], to destination: URL) async throws {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingExportError.noVideo
        }
        var audioTracks: [Int: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await sourceVideo.load(.timeRange)
            guard range.duration.seconds.isFinite, range.duration > .zero else { continue }
            if cursor == .zero { video.preferredTransform = try await sourceVideo.load(.preferredTransform) }
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            for (index, source) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                if audioTracks[index] == nil {
                    audioTracks[index] = composition.addMutableTrack(withMediaType: .audio,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                let audioRange = try await source.load(.timeRange)
                let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if overlap.duration > .zero {
                    try audioTracks[index]?.insertTimeRange(overlap, of: source,
                                                           at: cursor + overlap.start - range.start)
                }
            }
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw RecordingExportError.noVideo }
        let needsMix = audioTracks.count > 1
        // Normal recordings already contain a mixed audio track. Concatenate
        // their encoded samples directly, avoiding another full video encode.
        guard let exporter = AVAssetExportSession(asset: composition, presetName: needsMix
                                                  ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough) else {
            throw RecordingExportError.cannotCreateExport
        }
        // Older ScreenCaptureKit versions may produce separate system/mic tracks.
        // An explicit mix ensures ordinary players hear both sources in the MP4.
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.values.map { track in
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(audioTracks.count > 1 ? 0.7 : 1, at: .zero)
            return parameter
        }
        if needsMix { exporter.audioMix = mix }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: destination, as: .mp4)
    }
}
