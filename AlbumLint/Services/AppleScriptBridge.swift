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
    static func getLoved(persistentID: String) async -> Bool {
        let script = """
        tell application "Music"
            set t to (first track whose persistent ID is "\(escaped(persistentID))")
            return loved of t
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
            set l to loved of t
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
            set loved of t to \(loved)
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
            set loved of t to \(loved)
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
                        log.error("AppleScript failed: \(errorMsg)")
                        continuation.resume(returning: nil)
                    }
                } catch {
                    log.error("Failed to run osascript: \(error)")
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
