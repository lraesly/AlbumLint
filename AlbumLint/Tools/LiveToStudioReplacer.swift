import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.albumlint", category: "LiveToStudioReplacer")

/// Finds live recordings and matches them to studio versions.
actor LiveToStudioReplacer {

    private let scanner = LibraryScanner()
    private let matcher = CatalogMatcher()
    private let playlistManager = PlaylistManager()

    // MARK: - Scan

    func scan(outputURL: URL) async throws -> [LiveMatch] {
        log.info("Starting live track scan...")

        let liveSongs = try await scanner.liveTracks()
        let playlistIdx = try await playlistManager.buildIndex()

        var matches: [LiveMatch] = []

        for (song, keyword) in liveSongs {
            let artist = song.artistName
            let title = song.title
            let duration = song.duration ?? 0

            let metadata = await AppleScriptBridge.getMetadata(persistentID: song.id.rawValue)

            // Determine confidence based on keyword
            let keywordConfidence: MatchConfidence =
                LibraryScanner.highConfidenceKeywords.contains(keyword) ? .high : .medium

            // Search for studio version
            let result = await matcher.findStudioVersion(
                artist: artist,
                liveTitle: title,
                duration: duration
            )

            let playlists = await playlistManager.playlistNames(
                for: song.id.rawValue,
                in: playlistIdx
            )

            // Use the lower of keyword confidence and match confidence
            let overallConfidence: MatchConfidence
            if result.confidence == .none {
                overallConfidence = .none
            } else if keywordConfidence == .medium || result.confidence == .low {
                overallConfidence = .low
            } else if result.confidence == .medium {
                overallConfidence = .medium
            } else {
                overallConfidence = .high
            }

            let match = LiveMatch(
                liveAlbum: song.albumTitle ?? "Unknown Album",
                liveTrackID: song.id.rawValue,
                artist: artist,
                title: title,
                rawTitle: song.title,
                playCount: metadata.playCount,
                rating: metadata.rating,
                loved: metadata.loved,
                liveDuration: duration,
                liveURL: song.url,
                matchedKeyword: keyword,
                studioAlbum: result.catalogSong?.albumTitle,
                studioCatalogID: result.catalogSong?.id.rawValue,
                studioDuration: result.catalogSong?.duration,
                studioURL: result.catalogSong?.url,
                studioISRC: result.catalogSong?.isrc,
                confidence: overallConfidence,
                durationDelta: result.durationDelta,
                action: overallConfidence == .none ? .skip : (overallConfidence == .low ? .review : .replace),
                playlists: playlists
            )
            matches.append(match)
        }

        try exportToExcel(matches: matches, url: outputURL)
        log.info("Live scan complete: \(matches.count) live tracks, \(matches.filter { $0.confidence != .none }.count) matched")
        return matches
    }

    // MARK: - Execute (add studio tracks to library)

    func execute(inputURL: URL) async throws -> ExecutionReport {
        let (headers, rows) = try ExcelExporter.read(from: inputURL)

        guard let actionCol = headers.firstIndex(of: "action"),
              let artistCol = headers.firstIndex(of: "artist"),
              let titleCol = headers.firstIndex(of: "title"),
              let catalogIDCol = headers.firstIndex(of: "studio_catalog_id"),
              let liveTrackIDCol = headers.firstIndex(of: "live_track_id"),
              let playCountCol = headers.firstIndex(of: "play_count"),
              let ratingCol = headers.firstIndex(of: "rating"),
              let lovedCol = headers.firstIndex(of: "loved")
        else {
            throw ExecutionError.missingColumns
        }

        var report = ExecutionReport()

        for row in rows {
            guard row.count > max(actionCol, catalogIDCol) else { continue }
            guard row[actionCol] == "replace" else {
                report.skipped += 1
                continue
            }

            let artist = row[artistCol]
            let title = row[titleCol]
            let catalogID = row[catalogIDCol]
            let liveTrackID = row[liveTrackIDCol]
            let playCount = Int(row[playCountCol]) ?? 0
            let rating = Int(row[ratingCol]) ?? 0
            let loved = row[lovedCol].lowercased() == "true"

            guard !catalogID.isEmpty else {
                report.errors.append("\(artist) - \(title): No catalog ID")
                continue
            }

            // Add studio track to library via AppleScript (MusicLibrary.add unavailable on macOS)
            do {
                let musicItemID = MusicItemID(catalogID)
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: musicItemID)
                let response = try await request.response()
                guard let catalogSong = response.items.first else {
                    report.errors.append("\(artist) - \(title): Catalog song not found")
                    continue
                }

                if let url = catalogSong.url {
                    let added = await AppleScriptBridge.addToLibrary(storeURL: url.absoluteString)
                    if !added {
                        report.errors.append("\(artist) - \(title): Failed to add via store URL")
                        continue
                    }
                } else {
                    report.errors.append("\(artist) - \(title): No store URL available")
                    continue
                }
                report.added += 1
                log.info("Added studio version: \(artist) - \(title)")
            } catch {
                report.errors.append("\(artist) - \(title): Failed to add — \(error.localizedDescription)")
                continue
            }

            // Apply metadata
            try? await Task.sleep(for: .seconds(1))
            if let newPID = await AppleScriptBridge.findPersistentID(artist: artist, title: title) {
                let success = await AppleScriptBridge.applyMetadata(
                    persistentID: newPID,
                    playCount: playCount,
                    rating: rating,
                    loved: loved
                )
                if success {
                    report.metadataApplied += 1
                }
            }

            // Move live track to cleanup playlist
            let moved = await AppleScriptBridge.addToPlaylist(
                persistentID: liveTrackID,
                playlistName: "AlbumLint — Live Replaced"
            )
            if moved {
                report.movedToCleanup += 1
            }
        }

        log.info("Live execute complete: \(report)")
        return report
    }

    // MARK: - Playlist Swap (separate step)

    /// Scan playlists for live tracks that have studio equivalents in the library,
    /// and export a spreadsheet of proposed swaps.
    func playlistSwapScan(outputURL: URL) async throws -> [(playlistName: String, liveTrackID: String, studioTrackID: String, artist: String, title: String)] {
        log.info("Starting playlist swap scan...")

        let playlistIdx = try await playlistManager.buildIndex()
        let liveSongs = try await scanner.liveTracks()

        var swaps: [(playlistName: String, liveTrackID: String, studioTrackID: String, artist: String, title: String)] = []

        for (song, _) in liveSongs {
            let trackPlaylists = await playlistManager.playlistNames(
                for: song.id.rawValue,
                in: playlistIdx
            )
            guard !trackPlaylists.isEmpty else { continue }

            // Check if a studio version exists in the library
            let cleanTitle = song.title  // title might already be clean; studio version was added in execute step
            if let studioPID = await AppleScriptBridge.findPersistentID(
                artist: song.artistName,
                title: cleanTitle
            ), studioPID != song.id.rawValue {
                for playlist in trackPlaylists {
                    swaps.append((playlist, song.id.rawValue, studioPID, song.artistName, song.title))
                }
            }
        }

        // Export
        let headers = ["playlist", "live_track_id", "studio_track_id", "artist", "title", "action"]
        let rows: [[ExcelExporter.CellValue]] = swaps.map { s in
            [.string(s.playlistName), .string(s.liveTrackID), .string(s.studioTrackID),
             .string(s.artist), .string(s.title), .string("replace")]
        }
        try ExcelExporter.write(headers: headers, rows: rows, sheetName: "Playlist Swaps", to: outputURL)

        log.info("Playlist swap scan: \(swaps.count) swaps proposed")
        return swaps
    }

    /// Execute playlist swaps from a reviewed spreadsheet.
    func playlistSwapExecute(inputURL: URL) async throws -> Int {
        let (headers, rows) = try ExcelExporter.read(from: inputURL)

        guard let actionCol = headers.firstIndex(of: "action"),
              let playlistCol = headers.firstIndex(of: "playlist"),
              let liveIDCol = headers.firstIndex(of: "live_track_id"),
              let studioIDCol = headers.firstIndex(of: "studio_track_id")
        else {
            throw ExecutionError.missingColumns
        }

        var count = 0
        for row in rows {
            guard row.count > max(actionCol, studioIDCol) else { continue }
            guard row[actionCol] == "replace" else { continue }

            let success = await AppleScriptBridge.replaceInPlaylist(
                oldPersistentID: row[liveIDCol],
                newPersistentID: row[studioIDCol],
                playlistName: row[playlistCol]
            )
            if success { count += 1 }
        }

        log.info("Playlist swap complete: \(count) swaps executed")
        return count
    }

    // MARK: - Excel Export

    private func exportToExcel(matches: [LiveMatch], url: URL) throws {
        let headers = [
            "live_album", "live_track_id", "artist", "title", "raw_title",
            "play_count", "rating", "loved",
            "live_duration", "live_link", "matched_keyword",
            "studio_album", "studio_catalog_id", "studio_duration",
            "studio_link", "studio_isrc",
            "confidence", "duration_delta", "action", "playlists"
        ]

        let rows: [[ExcelExporter.CellValue]] = matches.map { m in
            [
                .string(m.liveAlbum), .string(m.liveTrackID),
                .string(m.artist), .string(m.title), .string(m.rawTitle),
                .number(Double(m.playCount)), .number(Double(m.rating)),
                .string(m.loved ? "true" : "false"),
                .number(m.liveDuration),
                m.liveURL.map { .hyperlink(url: $0.absoluteString, display: "Play") } ?? .string(""),
                .string(m.matchedKeyword),
                .string(m.studioAlbum ?? ""), .string(m.studioCatalogID ?? ""),
                .number(m.studioDuration ?? 0),
                m.studioURL.map { .hyperlink(url: $0.absoluteString, display: "Play") } ?? .string(""),
                .string(m.studioISRC ?? ""),
                .string(m.confidence.rawValue), .number(m.durationDelta ?? 0),
                .string(m.action.rawValue),
                .string(m.playlists.joined(separator: ", "))
            ]
        }

        try ExcelExporter.write(headers: headers, rows: rows, sheetName: "Live Tracks", to: url)
    }

    // MARK: - Types

    struct ExecutionReport: CustomStringConvertible {
        var added = 0
        var metadataApplied = 0
        var movedToCleanup = 0
        var skipped = 0
        var errors: [String] = []

        var description: String {
            "Added: \(added), Metadata: \(metadataApplied), Cleanup: \(movedToCleanup), Skipped: \(skipped), Errors: \(errors.count)"
        }
    }

    enum ExecutionError: Error, LocalizedError {
        case missingColumns
        var errorDescription: String? {
            switch self {
            case .missingColumns: return "Spreadsheet is missing required columns"
            }
        }
    }
}
