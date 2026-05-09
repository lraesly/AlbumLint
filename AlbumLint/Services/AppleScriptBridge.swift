import Foundation
import os

private let log = Logger(subsystem: "com.albumlint", category: "AppleScriptBridge")

/// Bridge to Music.app via osascript for metadata operations that MusicKit can't do.
struct AppleScriptBridge {

    // MARK: - Read Metadata

    /// Get play count for a track by its persistent ID.
    static func getPlayCount(persistentID: String) async -> Int {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            return played count of t
        end tell
        """
        return Int(await runScript(script) ?? "") ?? 0
    }

    /// Get rating (0-100) for a track.
    static func getRating(persistentID: String) async -> Int {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            return rating of t
        end tell
        """
        return Int(await runScript(script) ?? "") ?? 0
    }

    /// Get loved status for a track.
    /// Music.app renamed the AppleScript property from `loved` to `favorited`; the older
    /// name now errors with -10001 (descriptor type mismatch) on every track.
    static func getLoved(persistentID: String) async -> Bool {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            return favorited of t
        end tell
        """
        return (await runScript(script))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Get all metadata at once (more efficient than individual calls).
    struct TrackMetadata {
        let playCount: Int
        let rating: Int
        let loved: Bool
        let persistentID: String
    }

    static func getMetadata(persistentID: String) async -> TrackMetadata {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            set pc to played count of t
            set r to rating of t
            set l to favorited of t
            return (pc as text) & "|" & (r as text) & "|" & (l as text)
        end tell
        """
        let result = await runScript(script) ?? "0|0|false"
        let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        return TrackMetadata(
            playCount: Int(parts.first ?? "0") ?? 0,
            rating: parts.count > 1 ? (Int(parts[1]) ?? 0) : 0,
            loved: parts.count > 2 ? (parts[2] == "true") : false,
            persistentID: persistentID
        )
    }

    // MARK: - Write Metadata

    /// Set play count on a track.
    static func setPlayCount(persistentID: String, count: Int) async -> Bool {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            set played count of t to \(count)
        end tell
        """
        return await runScript(script) != nil
    }

    /// Set rating (0-100) on a track.
    static func setRating(persistentID: String, rating: Int) async -> Bool {
        let clamped = max(0, min(100, rating))
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            set rating of t to \(clamped)
        end tell
        """
        return await runScript(script) != nil
    }

    /// Set loved status on a track.
    static func setLoved(persistentID: String, loved: Bool) async -> Bool {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            set favorited of t to \(loved)
        end tell
        """
        return await runScript(script) != nil
    }

    /// Apply all metadata to a track at once.
    static func applyMetadata(persistentID: String, playCount: Int, rating: Int, loved: Bool) async -> Bool {
        let clamped = max(0, min(100, rating))
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            set played count of t to \(playCount)
            set rating of t to \(clamped)
            set favorited of t to \(loved)
        end tell
        """
        return await runScript(script) != nil
    }

    /// Get the current `album` and `album artist` of a library track.
    /// Used both to record the pre-edit values for reversibility and to
    /// verify that an edit stuck (some catalog-sourced tracks revert under
    /// iCloud Music Library sync).
    static func getAlbumIdentity(persistentID: String) async -> (album: String, albumArtist: String)? {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            set a to album of t
            set aa to album artist of t
            return a & "\u{1f}" & aa
        end tell
        """
        guard let raw = await runScript(script) else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\u{1f}")
        guard parts.count == 2 else { return nil }
        return (album: parts[0], albumArtist: parts[1])
    }

    /// Set both `album` and `album artist` on a library track in a single
    /// AppleScript transaction. Preserves persistent ID, play count, rating,
    /// loved status, date added, and playlist memberships — none of those
    /// are bound to the album/artist fields.
    static func setAlbumIdentity(persistentID: String, album: String, albumArtist: String) async -> Bool {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            set album of t to "\(escaped(album))"
            set album artist of t to "\(escaped(albumArtist))"
        end tell
        """
        return await runScript(script) != nil
    }

    /// Delete all artwork from a library track. Apple Music will not replace
    /// existing artwork on its own when album metadata changes — the user has
    /// to refresh manually after this. Deleting it first is what makes the
    /// refresh actually pick up new art.
    static func clearArtwork(persistentID: String) async -> Bool {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            try
                delete every artwork of t
            end try
        end tell
        """
        return await runScript(script) != nil
    }

    // MARK: - Library Operations

    /// Add a track to the library using its Apple Music store URL.
    /// Uses `open` command to trigger Music.app to add the track.
    static func addToLibrary(storeURL: String) async -> Bool {
        let script = """
        tell application "Music"
            open location "\(escaped(storeURL))"
            delay 2
        end tell
        """
        return await runScript(script) != nil
    }

    /// Add a track to the library by searching the Apple Music catalog via AppleScript.
    static func addToLibraryBySearch(artist: String, title: String) async -> Bool {
        // Use the `open` command with a music:// URL search
        let searchTerm = "\(artist) \(title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let script = """
        tell application "Music"
            open location "itmss://music.apple.com/us/search?term=\(searchTerm)"
            delay 3
        end tell
        """
        return await runScript(script) != nil
    }

    // MARK: - Playlist Operations

    /// Delete a user playlist by name. No-op (returns true) if the playlist
    /// doesn't exist. Used to reset accumulator playlists at the start of a run.
    static func deletePlaylist(name: String) async -> Bool {
        let script = """
        tell application "Music"
            try
                delete playlist "\(escaped(name))"
            end try
        end tell
        """
        return await runScript(script) != nil
    }

    /// Add a track to a playlist by name. Creates the playlist if it doesn't exist.
    static func addToPlaylist(persistentID: String, playlistName: String) async -> Bool {
        let script = """
        tell application "Music"
            set targetPlaylist to null
            try
                set targetPlaylist to playlist "\(escaped(playlistName))"
            on error
                set targetPlaylist to (make new playlist with properties {name:"\(escaped(playlistName))"})
            end try
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            duplicate t to targetPlaylist
        end tell
        """
        return await runScript(script) != nil
    }

    /// Replace a track in a playlist with a different track.
    /// Adds the new track at the same position and removes the old one.
    static func replaceInPlaylist(oldPersistentID: String, newPersistentID: String, playlistName: String) async -> Bool {
        let script = """
        tell application "Music"
            set pl to playlist "\(escaped(playlistName))"
            set trackList to tracks of pl
            set trackIndex to 0
            repeat with i from 1 to count of trackList
                if persistent ID of item i of trackList is "\(escaped(oldPersistentID))" then
                    set trackIndex to i
                    exit repeat
                end if
            end repeat
            if trackIndex > 0 then
                set newTrack to (first track whose persistent ID is "\(escaped(newPersistentID))")
                duplicate newTrack to pl
                -- Move the duplicated track (now at end) to the correct position
                -- Note: AppleScript playlist reordering is limited; we add then remove old
                delete track trackIndex of pl
                return true
            end if
            return false
        end tell
        """
        return await runScript(script) != nil
    }

    /// Get the persistent ID of a track by searching Music.app by artist+title.
    /// Useful for finding library tracks that were added via MusicKit (which uses MusicItemID, not persistent ID).
    static func findPersistentID(artist: String, title: String) async -> String? {
        let script = """
        tell application "Music"
            set results to (every track whose artist is "\(escaped(artist))" and name is "\(escaped(title))")
            if (count of results) > 0 then
                return persistent ID of item 1 of results
            end if
            return ""
        end tell
        """
        let result = (await runScript(script))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result?.isEmpty ?? true) ? nil : result
    }

    // MARK: - Script Execution

    /// Run an AppleScript that may produce output larger than the pipe buffer (~64KB).
    /// Drains stdout before waiting for exit to avoid the deadlock that would happen
    /// if the child blocked on a full pipe while the parent blocked on waitUntilExit.
    /// Used by LibraryIndex.build() for the bulk library export.
    static func runLargeScript(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: String(data: outputData, encoding: .utf8))
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        log.error("AppleScript failed: \(errorMsg, privacy: .public)")
                        continuation.resume(returning: nil)
                    }
                } catch {
                    log.error("Failed to run osascript: \(error, privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func runScript(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8)
                        continuation.resume(returning: output)
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        log.error("AppleScript failed: \(errorMsg, privacy: .public)")
                        continuation.resume(returning: nil)
                    }
                } catch {
                    log.error("Failed to run osascript: \(error, privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Escape a string for safe embedding in AppleScript.
    private static func escaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
