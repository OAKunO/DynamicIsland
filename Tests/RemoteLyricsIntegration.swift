import Foundation

@main
struct RemoteLyricsIntegration {
    static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        let synced = AudioPlaybackMonitor.parseRemoteLyrics(
            synced: "[00:01.25] 第一行 🎵\n[01:02.50] second line\n[01:03.00]  \nmetadata",
            plain: "fallback")
        check(synced.lines == ["第一行 🎵", "second line"], "Synced lyrics retain Unicode text and ignore empty or metadata lines")
        check(synced.timestamps == [1.25, 62.5], "Fractional timestamps remain aligned with their lines")
        let fallback = AudioPlaybackMonitor.parseRemoteLyrics(synced: "[invalid]ignored", plain: " first \r\n\n第二行 ")
        check(fallback.lines == ["first", "第二行"], "Invalid synced lyrics fall back to trimmed plain text")
        check(fallback.timestamps.isEmpty, "Plain text has no timestamps")
        let empty = AudioPlaybackMonitor.parseRemoteLyrics(synced: nil, plain: "  \n")
        check(empty.lines.isEmpty && empty.timestamps.isEmpty, "An empty response supplies no result to publish")

        let large = await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return AudioPlaybackMonitor.parseRemoteLyrics(
                synced: String(repeating: "[00:01.25] 歌词 🎵\n", count: 10_000), plain: nil)
        }.value
        check(large.lines.count == 10_000 && large.timestamps.count == 10_000,
              "Large responses can be parsed outside the main actor without losing line alignment")
        print("PASS: \(checks) remote lyrics, Unicode, fallback and background parsing checks")
    }
}
