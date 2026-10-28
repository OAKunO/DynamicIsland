import SwiftUI
import AppKit

struct AudioExpandedCard: View {
    @ObservedObject var audioPlayback: AudioPlaybackMonitor

    private struct CenteredLyricLine: Identifiable {
        let relativePosition: Int
        let text: String?

        var id: Int { relativePosition }
        var isCurrent: Bool { relativePosition == 0 }
    }

    private var progress: Double {
        guard audioPlayback.trackDuration > 0 else { return 0 }
        return min(max(audioPlayback.playbackPosition / audioPlayback.trackDuration, 0), 1)
    }

    private var activeLineIndex: Int {
        guard !audioPlayback.lyricsLines.isEmpty else { return 0 }
        if let accessibilityIndex = audioPlayback.activeLyricIndex,
           audioPlayback.lyricsLines.indices.contains(accessibilityIndex) {
            return accessibilityIndex
        }
        if audioPlayback.lyricTimestamps.count == audioPlayback.lyricsLines.count {
            return audioPlayback.lyricTimestamps.lastIndex(where: {
                $0 <= audioPlayback.playbackPosition
            }) ?? 0
        }
        return min(
            audioPlayback.lyricsLines.count - 1,
            Int(progress * Double(audioPlayback.lyricsLines.count))
        )
    }

    private var centeredLyricLines: [CenteredLyricLine] {
        [-1, 0, 1].map { relativePosition in
            let index = activeLineIndex + relativePosition
            return CenteredLyricLine(
                relativePosition: relativePosition,
                text: audioPlayback.lyricsLines.indices.contains(index)
                    ? audioPlayback.lyricsLines[index]
                    : nil
            )
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            artworkColumn
                .frame(width: 104)

            if audioPlayback.isMusicPlayback {
                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                genericAudioColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 42)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    private var artworkColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(nsImage: audioPlayback.sourceIcon ?? fallbackArtwork)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.42), radius: 12, y: 7)

            Text(primaryPlaybackTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(secondaryPlaybackTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.52))
                .lineLimit(1)
        }
    }

    private var primaryPlaybackTitle: String {
        if audioPlayback.isMusicPlayback, !audioPlayback.trackTitle.isEmpty {
            return audioPlayback.trackTitle
        }
        return audioPlayback.sourceName ?? "正在播放"
    }

    private var secondaryPlaybackTitle: String {
        if audioPlayback.isMusicPlayback {
            return audioPlayback.trackArtist.isEmpty ? "Apple Music" : audioPlayback.trackArtist
        }
        return "正在播放音频"
    }

    private var genericAudioColumn: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            AudioWaveformView(themeColor: audioPlayback.artworkThemeColor)
                .scaleEffect(1.8)
                .frame(width: 64, height: 42)
            Text("正在播放")
                .font(.system(size: 17, weight: .bold))
            Text(audioPlayback.sourceName ?? "其他音频来源")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.46))
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
    }

    private var lyricsColumn: some View {
        VStack(alignment: .center, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "quote.bubble.fill")
                Text("歌词")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.48))

            Spacer(minLength: 10)

            ZStack(alignment: .center) {
                if audioPlayback.lyricsLines.isEmpty {
                    VStack(alignment: .center, spacing: 7) {
                        Text("♪")
                            .font(.system(size: 25, weight: .bold))
                        Text(audioPlayback.lyricsAccessibilityPermissionNeeded
                             ? "需要辅助功能权限"
                             : "暂未获取到歌词")
                            .font(.system(size: 16, weight: .bold))
                        Text(audioPlayback.lyricsAccessibilityPermissionNeeded
                             ? "允许后即可读取 Music 的歌词文本"
                             : "歌曲仍会继续播放")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.42))
                            .multilineTextAlignment(.center)
                        if audioPlayback.lyricsAccessibilityPermissionNeeded {
                            Button("打开系统设置") {
                                audioPlayback.openAccessibilitySettings()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.82))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.12), in: Capsule())
                        }
                    }
                } else {
                    VStack(alignment: .center, spacing: 6) {
                        ForEach(centeredLyricLines) { lyric in
                            Group {
                                if let text = lyric.text {
                                    Text(text)
                                        .font(.system(
                                            size: lyric.isCurrent ? 17 : 14,
                                            weight: lyric.isCurrent ? .bold : .semibold
                                        ))
                                        .foregroundStyle(
                                            Color.white.opacity(lyric.isCurrent ? 1 : 0.34)
                                        )
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 42, alignment: .center)
                        }
                    }
                    .id(activeLineIndex)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 12)),
                        removal: .opacity.combined(with: .offset(y: -12))
                    ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(IslandMotion.content, value: activeLineIndex)
        }
    }

    private var fallbackArtwork: NSImage {
        NSImage(systemSymbolName: "music.note", accessibilityDescription: "正在播放") ?? NSImage()
    }

}

struct AudioWaveformView: View {
    private struct Bar {
        let maximumHeight: Double
        let speed: Double
        let phase: Double
    }

    let themeColor: NSColor?

    // iPhone 紧凑播放态使用的是一小簇单色脉冲，而不是铺开的均衡器。
    // 每根柱子的速度和相位刻意错开，让它们呈现轻微、不规则的呼吸感。
    private let bars: [Bar] = [
        Bar(maximumHeight: 8.0, speed: 2.10, phase: 0.20),
        Bar(maximumHeight: 12.5, speed: 2.55, phase: 1.70),
        Bar(maximumHeight: 10.0, speed: 1.90, phase: 3.10),
        Bar(maximumHeight: 15.0, speed: 2.80, phase: 4.45),
        Bar(maximumHeight: 11.5, speed: 2.25, phase: 5.80),
        Bar(maximumHeight: 13.5, speed: 2.65, phase: 2.55),
        Bar(maximumHeight: 8.5, speed: 2.00, phase: 4.00)
    ]

    private var palette: [Color] {
        // 没拿到封面时也保持单色，避免短暂回到旧的彩虹波形。
        let base = themeColor?.usingColorSpace(.deviceRGB) ?? .systemPink
        let blends: [(CGFloat, NSColor)] = [
            (0.34, .white), (0.22, .white), (0.10, .white),
            (0, .white), (0.08, .black), (0.16, .black), (0.24, .black)
        ]
        return blends.map { fraction, target in
            Color(nsColor: base.blended(withFraction: fraction, of: target) ?? base)
        }
    }

    var body: some View {
        let colors = palette
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.35) {
                ForEach(bars.indices, id: \.self) { index in
                    let bar = bars[index]
                    let primary = sin(time * bar.speed + bar.phase)
                    let secondary = sin(time * bar.speed * 0.43 + bar.phase * 1.73)
                    let tertiary = sin(time * bar.speed * 0.19 - bar.phase * 0.61)
                    let signal = primary * 0.58 + secondary * 0.28 + tertiary * 0.14
                    let energy = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? 0.48
                        : 0.24 + abs(signal) * 0.76

                    Capsule(style: .continuous)
                        .fill(colors[index])
                        .frame(
                            width: 2.0,
                            height: 2.5 + bar.maximumHeight * energy
                        )
                }
            }
            .frame(width: 24, height: 19)
        }
    }
}
