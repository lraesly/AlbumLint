import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.albumlint", category: "LibraryScanner")

/// Scans the Apple Music library for compilation tracks, duplicates, and live recordings.
actor LibraryScanner {

    // MARK: - Compilation Scanning

    /// Returns all tracks from compilation albums in the user's library.
    ///
    /// An album counts as a compilation when ANY of:
    ///   - Apple has flagged `Album.isCompilation == true`, OR
    ///   - the album's `artistName` is "Various Artists" (case-insensitive), OR
    ///   - the album's title matches `CatalogMatcher.looksLikeCompilation`
    ///     ("Greatest Hits", "The Complete X", "Anthology", etc.)
    ///
    /// Apple's `isCompilation` flag is unreliable for the user's "Various
    /// Artists comp" pattern — many such albums in real libraries don't have
    /// the flag set, so relying on it alone misses the majority of relabel
    /// candidates. The album-artist union catches Various Artists comps; the
    /// name-regex union catches single-artist comps (so previously-relabeled
    /// tracks that landed on a single-artist comp become visible again, and
    /// the matcher gets a chance to find their original studio album).
    func compilationTracks() async throws -> [Song] {
        let albumRequest = MusicLibraryRequest<Album>()
        let albumResponse = try await albumRequest.response()

        let compilationAlbumNames = Set(albumResponse.items.compactMap { album -> String? in
            if album.isCompilation == true { return album.title }
            if album.artistName.localizedCaseInsensitiveCompare("Various Artists") == .orderedSame {
                return album.title
            }
            if CatalogMatcher.looksLikeCompilation(album.title) {
                return album.title
            }
            return nil
        })

        guard !compilationAlbumNames.isEmpty else {
            log.info("No compilation albums found")
            return []
        }

        let songRequest = MusicLibraryRequest<Song>()
        let songResponse = try await songRequest.response()
        let songs = songResponse.items.filter { song in
            compilationAlbumNames.contains(song.albumTitle ?? "")
        }

        log.info("Found \(songs.count) compilation tracks across \(compilationAlbumNames.count) albums")
        return Array(songs)
    }

    // MARK: - Duplicate Scanning

    /// Groups all library songs by artist+title to find duplicates.
    /// Returns only groups with 2+ tracks.
    func duplicateCandidates() async throws -> [[Song]] {
        let request = MusicLibraryRequest<Song>()
        let response = try await request.response()

        // Group by normalized artist+title
        var groups: [String: [Song]] = [:]
        for song in response.items {
            let key = normalizeForGrouping(artist: song.artistName, title: song.title)
            groups[key, default: []].append(song)
        }

        let duplicates = groups.values.filter { $0.count >= 2 }
        log.info("Found \(duplicates.count) duplicate groups from \(response.items.count) total tracks")
        return Array(duplicates)
    }

    // MARK: - Live Track Scanning

    /// Keywords that indicate a live recording (checked against album name only).
    static let liveKeywords: [String] = [
        "live at", "live in", "live from", "live version",
        "in concert", "concert",
        "unplugged",
        "tiny desk", "austin city limits", "kexp",
        "storytellers",
        "bbc sessions", "bbc session", "bbc radio", "bbc",
        "radio session",
        "sessions", "session",
        "recorded at", "recorded live",
        "on stage",
        "encore",
        "live"  // most generic — check last so more specific matches take priority
    ]

    /// High-confidence keywords (unambiguous live indicators).
    static let highConfidenceKeywords: Set<String> = [
        "live at", "live in", "live from", "live version",
        "in concert", "unplugged", "tiny desk",
        "austin city limits", "kexp", "storytellers",
        "recorded at", "recorded live", "on stage", "live"
    ]

    /// Returns all tracks whose album name matches a live keyword.
    func liveTracks() async throws -> [(song: Song, matchedKeyword: String)] {
        let request = MusicLibraryRequest<Song>()
        let response = try await request.response()

        var results: [(Song, String)] = []
        for song in response.items {
            if let keyword = matchesLiveKeyword(albumName: song.albumTitle ?? "") {
                results.append((song, keyword))
            }
        }

        log.info("Found \(results.count) live tracks from \(response.items.count) total tracks")
        return results
    }

    /// Checks if an album name contains a live keyword. Returns the matched keyword or nil.
    func matchesLiveKeyword(albumName: String) -> String? {
        let lower = albumName.lowercased()
        // Check longer/more specific keywords first
        for keyword in Self.liveKeywords {
            if lower.contains(keyword) {
                return keyword
            }
        }
        return nil
    }

    // MARK: - Playlist Index

    /// Builds an index of track ID → [playlist names] for all user playlists.
    /// Uses .tracks relationship which returns Track items sharing IDs with Songs.
    func playlistIndex() async throws -> [String: [String]] {
        let request = MusicLibraryRequest<Playlist>()
        let response = try await request.response()

        var index: [String: [String]] = [:]
        for playlist in response.items {
            let detailed = try await playlist.with(.tracks)
            guard let tracks = detailed.tracks else { continue }
            for track in tracks {
                index[track.id.rawValue, default: []].append(playlist.name)
            }
        }

        log.info("Built playlist index: \(index.count) tracks across \(response.items.count) playlists")
        return index
    }

    // MARK: - Helpers

    private func normalizeForGrouping(artist: String, title: String) -> String {
        let a = artist.lowercased().trimmingCharacters(in: .whitespaces)
        let t = title.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\s*\\(feat\\..*?\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\[feat\\..*?\\]", with: "", options: .regularExpression)
        return "\(a)|\(t)"
    }
}
