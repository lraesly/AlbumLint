import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.albumlint", category: "TrackDeDuper")

/// Finds duplicate tracks in the library and merges metadata.
actor TrackDeDuper {

    private let scanner = LibraryScanner()
    private let matcher = CatalogMatcher()
    private let playlistManager = PlaylistManager()

    // MARK: - Scan

    func scan(outputURL: URL) async throws -> [DuplicateMatch] {
        log.info("Starting de-dup scan...")

        let groups = try await scanner.duplicateCandidates()
        let playlistIdx = try await playlistManager.buildIndex()
        let libraryIndex = try await LibraryIndex.build()

        var matches: [DuplicateMatch] = []
        var unresolvedSongs = 0
        var skippedSelfDupes = 0

        for group in groups {
            guard group.count >= 2 else { continue }

            // Resolve every song to its Music.app library persistent ID up front. Any
            // song that can't be matched in the bulk export is dropped — without a
            // library ID, downstream metadata reads and AppleScript writes can't work.
            var rankedSongs: [(song: Song, libID: String, metadata: AppleScriptBridge.TrackMetadata, quality: String)] = []

            for song in group {
                guard let libID = await libraryIndex.resolve(
                    artist: song.artistName,
                    title: song.title,
                    album: song.albumTitle ?? "",
                    duration: song.duration
                ) else {
                    unresolvedSongs += 1
                    log.warning("No library match: \(song.artistName, privacy: .public) - \(song.title, privacy: .public)")
                    continue
                }

                let metadata = await AppleScriptBridge.getMetadata(persistentID: libID)
                let variants = song.audioVariants ?? []
                let quality: String
                if variants.contains(.highResolutionLossless) {
                    quality = "Hi-Res Lossless"
                } else if variants.contains(.lossless) {
                    quality = "Lossless"
                } else if variants.contains(.dolbyAtmos) {
                    quality = "Dolby Atmos"
                } else {
                    quality = "AAC"
                }
                rankedSongs.append((song, libID, metadata, quality))
            }

            // After resolution we may have fewer than 2 distinct library tracks left.
            let distinctLibIDs = Set(rankedSongs.map { $0.libID })
            guard distinctLibIDs.count >= 2 else { continue }

            // Sort: highest quality first, then non-compilation, then most plays
            rankedSongs.sort { a, b in
                let aQualityRank = qualityRank(a.quality)
                let bQualityRank = qualityRank(b.quality)
                if aQualityRank != bQualityRank { return aQualityRank > bQualityRank }

                let aComp = CatalogMatcher.looksLikeCompilation(a.song.albumTitle ?? "")
                let bComp = CatalogMatcher.looksLikeCompilation(b.song.albumTitle ?? "")
                if aComp != bComp { return !aComp }

                return a.metadata.playCount > b.metadata.playCount
            }

            let keep = rankedSongs[0]
            for remove in rankedSongs.dropFirst() {
                // Defensive: two MusicKit songs occasionally collapse to the same library
                // entry. Pairing a track with itself would corrupt its metadata.
                guard remove.libID != keep.libID else {
                    skippedSelfDupes += 1
                    continue
                }

                let mergedPlayCount = keep.metadata.playCount + remove.metadata.playCount
                let mergedRating = max(keep.metadata.rating, remove.metadata.rating)
                let mergedLoved = keep.metadata.loved || remove.metadata.loved

                let durationDelta = abs((keep.song.duration ?? 0) - (remove.song.duration ?? 0))
                // Anything beyond 3.5s is a different recording — flag for review.
                let confidence: MatchConfidence = durationDelta <= 3.5 ? .high : .low

                let removePlaylists = await playlistManager.playlistNames(
                    for: remove.song.id.rawValue,
                    in: playlistIdx
                )

                let match = DuplicateMatch(
                    artist: keep.song.artistName,
                    title: keep.song.title,
                    keepTrackID: keep.libID,
                    keepAlbum: keep.song.albumTitle ?? "Unknown",
                    keepPlayCount: keep.metadata.playCount,
                    keepRating: keep.metadata.rating,
                    keepLoved: keep.metadata.loved,
                    keepDuration: keep.song.duration ?? 0,
                    keepURL: keep.song.url,
                    keepQuality: keep.quality,
                    removeTrackID: remove.libID,
                    removeAlbum: remove.song.albumTitle ?? "Unknown",
                    removePlayCount: remove.metadata.playCount,
                    removeRating: remove.metadata.rating,
                    removeLoved: remove.metadata.loved,
                    removeDuration: remove.song.duration ?? 0,
                    removeURL: remove.song.url,
                    removeQuality: remove.quality,
                    mergedPlayCount: mergedPlayCount,
                    mergedRating: mergedRating,
                    mergedLoved: mergedLoved,
                    confidence: confidence,
                    action: confidence == .low ? .review : .replace,
                    playlists: removePlaylists,
                    durationDelta: durationDelta
                )
                matches.append(match)
            }
        }

        try exportToExcel(matches: matches, url: outputURL)
        log.info("De-dup scan complete: \(matches.count) pairs, \(unresolvedSongs) unresolved, \(skippedSelfDupes) self-dupes skipped")
        return matches
    }

    // MARK: - Execute

    func execute(inputURL: URL) async throws -> ExecutionReport {
        let (headers, rows) = try ExcelExporter.read(from: inputURL)

        guard let actionCol = headers.firstIndex(of: "action"),
              let keepIDCol = headers.firstIndex(of: "keep_track_id"),
              let removeIDCol = headers.firstIndex(of: "remove_track_id"),
              let artistCol = headers.firstIndex(of: "artist"),
              let titleCol = headers.firstIndex(of: "title"),
              let mergedPlayCountCol = headers.firstIndex(of: "merged_play_count"),
              let mergedRatingCol = headers.firstIndex(of: "merged_rating"),
              let mergedLovedCol = headers.firstIndex(of: "merged_loved"),
              let playlistsCol = headers.firstIndex(of: "playlists")
        else {
            throw ExecutionError.missingColumns
        }

        var report = ExecutionReport()

        for row in rows {
            guard row.count > max(actionCol, playlistsCol) else { continue }
            guard row[actionCol] == "replace" else {
                report.skipped += 1
                continue
            }

            let keepID = row[keepIDCol]
            let removeID = row[removeIDCol]
            let artist = row[artistCol]
            let title = row[titleCol]
            let mergedPlayCount = Int(row[mergedPlayCountCol]) ?? 0
            let mergedRating = Int(row[mergedRatingCol]) ?? 0
            let mergedLoved = row[mergedLovedCol].lowercased() == "true"
            let playlistNames = row[playlistsCol]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            // Step 1: Apply merged metadata to the kept track
            let success = await AppleScriptBridge.applyMetadata(
                persistentID: keepID,
                playCount: mergedPlayCount,
                rating: mergedRating,
                loved: mergedLoved
            )
            if success {
                report.metadataApplied += 1
            } else {
                report.errors.append("\(artist) - \(title): Failed to apply metadata to kept track")
            }

            // Step 2: Swap in playlists
            for playlist in playlistNames where !playlist.isEmpty {
                let swapped = await AppleScriptBridge.replaceInPlaylist(
                    oldPersistentID: removeID,
                    newPersistentID: keepID,
                    playlistName: playlist
                )
                if swapped {
                    report.playlistSwaps += 1
                }
            }

            // Step 3: Move duplicate to cleanup playlist
            let moved = await AppleScriptBridge.addToPlaylist(
                persistentID: removeID,
                playlistName: "AlbumLint — Track Dupes"
            )
            if moved {
                report.movedToCleanup += 1
            }
        }

        log.info("De-dup execution complete: \(report)")
        return report
    }

    // MARK: - Excel Export

    private func exportToExcel(matches: [DuplicateMatch], url: URL) throws {
        let headers = [
            "artist", "title",
            "keep_track_id", "keep_album", "keep_play_count", "keep_rating",
            "keep_loved", "keep_duration", "keep_link", "keep_quality",
            "remove_track_id", "remove_album", "remove_play_count", "remove_rating",
            "remove_loved", "remove_duration", "remove_link", "remove_quality",
            "merged_play_count", "merged_rating", "merged_loved",
            "confidence", "action", "playlists", "duration_diff"
        ]

        let rows: [[ExcelExporter.CellValue]] = matches.map { m in
            [
                .string(m.artist), .string(m.title),
                .string(m.keepTrackID), .string(m.keepAlbum),
                .number(Double(m.keepPlayCount)), .number(Double(m.keepRating)),
                .string(m.keepLoved ? "true" : "false"), .number(m.keepDuration),
                m.keepURL.map { .hyperlink(url: $0.absoluteString, display: "Play") } ?? .string(""),
                .string(m.keepQuality ?? ""),
                .string(m.removeTrackID), .string(m.removeAlbum),
                .number(Double(m.removePlayCount)), .number(Double(m.removeRating)),
                .string(m.removeLoved ? "true" : "false"), .number(m.removeDuration),
                m.removeURL.map { .hyperlink(url: $0.absoluteString, display: "Play") } ?? .string(""),
                .string(m.removeQuality ?? ""),
                .number(Double(m.mergedPlayCount)), .number(Double(m.mergedRating)),
                .string(m.mergedLoved ? "true" : "false"),
                .string(m.confidence.rawValue), .string(m.action.rawValue),
                .string(m.playlists.joined(separator: ", ")),
                .number(m.durationDelta)
            ]
        }

        try ExcelExporter.write(headers: headers, rows: rows, sheetName: "Duplicates", to: url)
    }

    // MARK: - Helpers

    private func qualityRank(_ quality: String) -> Int {
        switch quality {
        case "Hi-Res Lossless": return 4
        case "Lossless": return 3
        case "Dolby Atmos": return 2
        case "AAC": return 1
        default: return 0
        }
    }

    // MARK: - Types

    struct ExecutionReport: CustomStringConvertible {
        var metadataApplied = 0
        var playlistSwaps = 0
        var movedToCleanup = 0
        var skipped = 0
        var errors: [String] = []

        var description: String {
            "Metadata: \(metadataApplied), Playlist swaps: \(playlistSwaps), Cleanup: \(movedToCleanup), Skipped: \(skipped), Errors: \(errors.count)"
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
