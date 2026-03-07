import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.albumlint", category: "CompilationReplacer")

/// Scans for compilation tracks, matches to original albums, and executes replacements.
actor CompilationReplacer {

    private let scanner = LibraryScanner()
    private let matcher = CatalogMatcher()
    private let playlistManager = PlaylistManager()

    // MARK: - Scan

    /// Scan the library for compilation tracks and find original album versions.
    /// Returns matches and writes an xlsx file for review.
    func scan(outputURL: URL) async throws -> [CompilationMatch] {
        log.info("Starting compilation scan...")

        // Step 1: Get all compilation tracks
        let compilationSongs = try await scanner.compilationTracks()
        log.info("Found \(compilationSongs.count) compilation tracks")

        // Step 2: Build playlist index
        let playlistIdx = try await playlistManager.buildIndex()

        // Step 3: Match each track to an original album version
        var matches: [CompilationMatch] = []

        for song in compilationSongs {
            let artist = song.artistName
            let title = song.title
            let duration = song.duration ?? 0

            // Get metadata via AppleScript (play count, rating, loved)
            let metadata = await AppleScriptBridge.getMetadata(persistentID: song.id.rawValue)

            // Search for original
            let result = await matcher.findOriginal(
                artist: artist,
                title: title,
                duration: duration,
                isrc: song.isrc
            )

            // Check quality warning
            var qualityWarning: String? = nil
            if let catalogSong = result.catalogSong {
                if await matcher.isHigherQuality(song, catalogSong) {
                    qualityWarning = "Compilation has higher quality available"
                }
            }

            // Get playlist memberships
            let playlists = await playlistManager.playlistNames(
                for: song.id.rawValue,
                in: playlistIdx
            )

            let match = CompilationMatch(
                compilationAlbum: song.albumTitle ?? "Unknown Album",
                compilationTrackID: song.id.rawValue,
                artist: artist,
                title: title,
                playCount: metadata.playCount,
                rating: metadata.rating,
                loved: metadata.loved,
                dateAdded: song.libraryAddedDate,
                compilationDuration: duration,
                compilationURL: song.url,
                originalAlbum: result.catalogSong?.albumTitle,
                originalCatalogID: result.catalogSong?.id.rawValue,
                originalDuration: result.catalogSong?.duration,
                originalURL: result.catalogSong?.url,
                originalISRC: result.catalogSong?.isrc,
                audioQualityAvailable: result.qualityAvailable,
                qualityWarning: qualityWarning,
                confidence: result.confidence,
                durationDelta: result.durationDelta,
                action: result.confidence == .none ? .skip : (result.confidence == .low ? .review : .replace),
                playlists: playlists
            )
            matches.append(match)
        }

        // Step 4: Export to xlsx
        try exportToExcel(matches: matches, url: outputURL)

        log.info("Scan complete: \(matches.count) tracks, \(matches.filter { $0.confidence != .none }.count) matched")
        return matches
    }

    // MARK: - Execute

    /// Execute replacements from a reviewed xlsx file.
    func execute(inputURL: URL) async throws -> ExecutionReport {
        let (headers, rows) = try ExcelExporter.read(from: inputURL)

        // Find column indices
        guard let actionCol = headers.firstIndex(of: "action"),
              let artistCol = headers.firstIndex(of: "artist"),
              let titleCol = headers.firstIndex(of: "title"),
              let catalogIDCol = headers.firstIndex(of: "original_catalog_id"),
              let compTrackIDCol = headers.firstIndex(of: "compilation_track_id"),
              let playCountCol = headers.firstIndex(of: "play_count"),
              let ratingCol = headers.firstIndex(of: "rating"),
              let lovedCol = headers.firstIndex(of: "loved"),
              let playlistsCol = headers.firstIndex(of: "playlists")
        else {
            throw ExecutionError.missingColumns
        }

        var report = ExecutionReport()

        for row in rows {
            guard row.count > max(actionCol, catalogIDCol, playlistsCol) else { continue }
            guard row[actionCol] == "replace" else {
                report.skipped += 1
                continue
            }

            let artist = row[artistCol]
            let title = row[titleCol]
            let catalogID = row[catalogIDCol]
            let compilationTrackID = row[compTrackIDCol]
            let playCount = Int(row[playCountCol]) ?? 0
            let rating = Int(row[ratingCol]) ?? 0
            let loved = row[lovedCol].lowercased() == "true"
            let playlistNames = row[playlistsCol]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            guard !catalogID.isEmpty else {
                report.errors.append("\(artist) - \(title): No catalog ID")
                continue
            }

            // Step 1: Add the original track to the library via AppleScript
            // MusicLibrary.shared.add() is unavailable on macOS; use store URL instead
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
                log.info("Added to library: \(artist) - \(title)")
                report.added += 1
            } catch {
                report.errors.append("\(artist) - \(title): Failed to add — \(error.localizedDescription)")
                continue
            }

            // Step 2: Wait briefly for the track to appear in Music.app, then apply metadata
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
                } else {
                    report.errors.append("\(artist) - \(title): Metadata apply failed")
                }

                // Step 3: Update playlists — swap compilation track for original
                if !playlistNames.isEmpty {
                    for playlist in playlistNames {
                        let swapped = await AppleScriptBridge.replaceInPlaylist(
                            oldPersistentID: compilationTrackID,
                            newPersistentID: newPID,
                            playlistName: playlist
                        )
                        if swapped {
                            report.playlistSwaps += 1
                        }
                    }
                }
            }

            // Step 4: Move compilation track to cleanup playlist
            let moved = await AppleScriptBridge.addToPlaylist(
                persistentID: compilationTrackID,
                playlistName: "AlbumLint — Compilation Dupes"
            )
            if moved {
                report.movedToCleanup += 1
            }
        }

        log.info("Execution complete: \(report)")
        return report
    }

    // MARK: - Excel Export

    private func exportToExcel(matches: [CompilationMatch], url: URL) throws {
        let headers = [
            "compilation_album", "compilation_track_id", "artist", "title",
            "play_count", "rating", "loved", "date_added",
            "compilation_duration", "compilation_link",
            "original_album", "original_catalog_id", "original_duration",
            "original_link", "original_isrc",
            "audio_quality", "quality_warning",
            "confidence", "duration_delta", "action", "playlists"
        ]

        let rows: [[ExcelExporter.CellValue]] = matches.map { m in
            [
                .string(m.compilationAlbum),
                .string(m.compilationTrackID),
                .string(m.artist),
                .string(m.title),
                .number(Double(m.playCount)),
                .number(Double(m.rating)),
                .string(m.loved ? "true" : "false"),
                .string(m.dateAdded.map { ISO8601DateFormatter().string(from: $0) } ?? ""),
                .number(m.compilationDuration),
                m.compilationURL.map { .hyperlink(url: $0.absoluteString, display: "Play") } ?? .string(""),
                .string(m.originalAlbum ?? ""),
                .string(m.originalCatalogID ?? ""),
                .number(m.originalDuration ?? 0),
                m.originalURL.map { .hyperlink(url: $0.absoluteString, display: "Play") } ?? .string(""),
                .string(m.originalISRC ?? ""),
                .string(m.audioQualityAvailable ?? ""),
                .string(m.qualityWarning ?? ""),
                .string(m.confidence.rawValue),
                .number(m.durationDelta ?? 0),
                .string(m.action.rawValue),
                .string(m.playlists.joined(separator: ", "))
            ]
        }

        try ExcelExporter.write(headers: headers, rows: rows, sheetName: "Compilations", to: url)
    }

    // MARK: - Types

    struct ExecutionReport: CustomStringConvertible {
        var added = 0
        var metadataApplied = 0
        var playlistSwaps = 0
        var movedToCleanup = 0
        var skipped = 0
        var errors: [String] = []

        var description: String {
            "Added: \(added), Metadata: \(metadataApplied), Playlist swaps: \(playlistSwaps), Cleanup: \(movedToCleanup), Skipped: \(skipped), Errors: \(errors.count)"
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
