import Foundation
import os

private let log = Logger(subsystem: "com.albumlint", category: "LibraryIndex")

/// Snapshot of one library track's identifying metadata as Music.app sees it.
struct LibraryTrackInfo {
    let persistentID: String
    let artist: String
    let title: String
    let album: String
    let duration: Double
}

/// Maps MusicKit `Song` records to Music.app's library persistent IDs.
///
/// MusicKit's `Song.id.rawValue` is the Apple Music *catalog* ID (e.g. `i.QvzLoPPUMqDgJ`),
/// but Music.app's AppleScript interface keys tracks by their 16-char hex *library*
/// persistent ID. The two namespaces are disjoint, so any AppleScript call that uses a
/// catalog ID where a persistent ID is expected silently fails (error -1728).
///
/// This index resolves the gap by snapshotting Music.app's library once per scan via a
/// single bulk AppleScript export, then matching MusicKit songs back by (artist, title,
/// album) with a duration tiebreaker.
actor LibraryIndex {

    private let byKey: [String: [LibraryTrackInfo]]
    private let byArtistTitle: [String: [LibraryTrackInfo]]

    private init(byKey: [String: [LibraryTrackInfo]], byArtistTitle: [String: [LibraryTrackInfo]]) {
        self.byKey = byKey
        self.byArtistTitle = byArtistTitle
    }

    static func build() async throws -> LibraryIndex {
        // Returns the library as 5 lines (pid, artist, name, album, duration), each line
        // containing N tab-separated fields. AppleScript bulk property-of-every-track
        // queries are O(N) where individual property lookups would be O(N) per call.
        let script = """
        tell application "Music"
            set lib to library playlist 1
            set old_delim to AppleScript's text item delimiters

            set AppleScript's text item delimiters to (ASCII character 9)
            set p_text to (persistent ID of every track of lib) as text
            set a_text to (artist of every track of lib) as text
            set n_text to (name of every track of lib) as text
            set b_text to (album of every track of lib) as text
            set d_text to (duration of every track of lib) as text

            set AppleScript's text item delimiters to (ASCII character 10)
            set big to {p_text, a_text, n_text, b_text, d_text} as text

            set AppleScript's text item delimiters to old_delim
            return big
        end tell
        """

        guard let output = await AppleScriptBridge.runLargeScript(script) else {
            throw IndexError.scriptFailed
        }

        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 5 else {
            throw IndexError.malformed
        }
        let pids = lines[0].components(separatedBy: "\t")
        let arts = lines[1].components(separatedBy: "\t")
        let nams = lines[2].components(separatedBy: "\t")
        let albs = lines[3].components(separatedBy: "\t")
        let durs = lines[4].components(separatedBy: "\t")

        let count = pids.count
        guard arts.count == count, nams.count == count, albs.count == count, durs.count == count else {
            throw IndexError.malformed
        }

        var byKey: [String: [LibraryTrackInfo]] = [:]
        var byArtistTitle: [String: [LibraryTrackInfo]] = [:]
        for i in 0..<count {
            let info = LibraryTrackInfo(
                persistentID: pids[i],
                artist: arts[i],
                title: nams[i],
                album: albs[i],
                duration: Double(durs[i]) ?? 0
            )
            byKey[Self.key(artist: info.artist, title: info.title, album: info.album), default: []].append(info)
            byArtistTitle[Self.atKey(artist: info.artist, title: info.title), default: []].append(info)
        }
        log.info("Built library index: \(count) tracks")
        return LibraryIndex(byKey: byKey, byArtistTitle: byArtistTitle)
    }

    /// Resolve a MusicKit song to its Music.app library persistent ID.
    /// Tries (artist, title, album) first; falls back to (artist, title) if no album hit.
    /// When multiple library entries share the key, the closest-duration match wins.
    func resolve(artist: String, title: String, album: String, duration: Double?) -> String? {
        let candidates = byKey[Self.key(artist: artist, title: title, album: album)]
            ?? byArtistTitle[Self.atKey(artist: artist, title: title)]
            ?? []

        if candidates.isEmpty { return nil }
        if candidates.count == 1 { return candidates[0].persistentID }

        guard let dur = duration else { return candidates[0].persistentID }
        return candidates.min { abs($0.duration - dur) < abs($1.duration - dur) }?.persistentID
    }

    private static func key(artist: String, title: String, album: String) -> String {
        "\(artist.lowercased())|\(title.lowercased())|\(album.lowercased())"
    }

    private static func atKey(artist: String, title: String) -> String {
        "\(artist.lowercased())|\(title.lowercased())"
    }

    enum IndexError: Error, LocalizedError {
        case scriptFailed
        case malformed
        var errorDescription: String? {
            switch self {
            case .scriptFailed: return "Failed to read library from Music.app"
            case .malformed: return "Library export from Music.app was malformed"
            }
        }
    }
}
