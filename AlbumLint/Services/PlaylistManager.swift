import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.albumlint", category: "PlaylistManager")

/// Manages playlist scanning and track substitution.
actor PlaylistManager {

    /// A reference to a track's position in a playlist.
    struct PlaylistEntry {
        let playlistName: String
        let playlistID: String    // MusicItemID
        let trackID: String       // MusicItemID of the song
    }

    /// Build an index mapping track IDs to the playlists they appear in.
    func buildIndex() async throws -> [String: [PlaylistEntry]] {
        let request = MusicLibraryRequest<Playlist>()
        let response = try await request.response()

        var index: [String: [PlaylistEntry]] = [:]

        for playlist in response.items {
            let detailed = try await playlist.with(.tracks)
            guard let tracks = detailed.tracks else { continue }

            for track in tracks {
                let plEntry = PlaylistEntry(
                    playlistName: playlist.name,
                    playlistID: playlist.id.rawValue,
                    trackID: track.id.rawValue
                )
                index[track.id.rawValue, default: []].append(plEntry)
            }
        }

        log.info("Playlist index: \(index.count) unique tracks across \(response.items.count) playlists")
        return index
    }

    /// Get playlist names for a given track ID.
    func playlistNames(for trackID: String, in index: [String: [PlaylistEntry]]) -> [String] {
        (index[trackID] ?? []).map(\.playlistName)
    }

    /// Substitute a track in all playlists via AppleScript.
    /// Returns the number of successful substitutions.
    func substituteInPlaylists(
        oldTrackArtist: String,
        oldTrackTitle: String,
        newTrackArtist: String,
        newTrackTitle: String,
        playlistNames: [String]
    ) async -> Int {
        // First, find the persistent IDs for both tracks
        guard let oldPID = await AppleScriptBridge.findPersistentID(artist: oldTrackArtist, title: oldTrackTitle) else {
            log.error("Could not find persistent ID for old track: \(oldTrackArtist) - \(oldTrackTitle)")
            return 0
        }
        guard let newPID = await AppleScriptBridge.findPersistentID(artist: newTrackArtist, title: newTrackTitle) else {
            log.error("Could not find persistent ID for new track: \(newTrackArtist) - \(newTrackTitle)")
            return 0
        }

        var count = 0
        for name in playlistNames {
            let success = await AppleScriptBridge.replaceInPlaylist(
                oldPersistentID: oldPID,
                newPersistentID: newPID,
                playlistName: name
            )
            if success {
                count += 1
                log.info("Replaced in playlist '\(name)': \(oldTrackTitle) → \(newTrackTitle)")
            } else {
                log.warning("Failed to replace in playlist '\(name)'")
            }
        }
        return count
    }
}
