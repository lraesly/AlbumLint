import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.albumlint", category: "CompilationReplacer")

/// Scans for compilation tracks and relabels them in place to point at their
/// original studio albums. Preserves persistent ID, playlist memberships,
/// play count, rating, loved status, and date-added — only `album` and
/// `album artist` change. Artwork is cleared so Apple Music will re-fetch it
/// when the user manually refreshes (Apple won't replace existing artwork
/// just because metadata changed).
actor CompilationReplacer {

    private let scanner = LibraryScanner()
    private let matcher = CatalogMatcher()

    /// ±3s duration window for the auto-apply gate. Wider than typical mastering
    /// drift, narrower than fade/edit differences and live-vs-studio gaps.
    private static let durationToleranceSeconds: TimeInterval = 3

    // MARK: - Reports

    struct ScanReport {
        let matches: [CompilationMatch]
        let previewLogURL: URL
        /// Compilation tracks that LibraryIndex couldn't map to a Music.app
        /// persistent ID — dropped from the run because we have nothing to
        /// edit. Logged to os.log; usually means a metadata mismatch
        /// between MusicKit's view and Music.app's view of the same track.
        let unresolved: Int
        var total: Int { matches.count }
        var willApply: Int { matches.filter(\.autoApply).count }
        var needsReview: Int { matches.filter { !$0.autoApply && $0.originalAlbum != nil }.count }
        var unmatched: Int { matches.filter { $0.originalAlbum == nil }.count }
    }

    struct ExecutionReport: CustomStringConvertible {
        var applied = 0
        var verifyReverted = 0
        var notEligible = 0
        var errors: [String] = []
        var appliedLogURL: URL?

        var description: String {
            "Applied: \(applied), Verify reverted: \(verifyReverted), Not eligible: \(notEligible), Errors: \(errors.count)"
        }
    }

    // MARK: - Scan

    /// Scan the library for compilation tracks, score each one, and decide
    /// which can be auto-relabeled. Writes a JSONL preview log; the caller
    /// hands the returned matches to `execute()` to apply.
    func scan(outputDirectory: URL) async throws -> ScanReport {
        log.info("Starting compilation scan")
        let compilationSongs = try await scanner.compilationTracks()
        log.info("Found \(compilationSongs.count) compilation tracks")

        // MusicKit's Song.id.rawValue is a catalog ID, not a Music.app persistent ID
        // — they're disjoint namespaces. Build the index once so we can translate
        // each library Song to the persistent ID AppleScript actually accepts.
        let libraryIndex = try await LibraryIndex.build()
        var unresolved = 0

        var matches: [CompilationMatch] = []
        for song in compilationSongs {
            guard let persistentID = await libraryIndex.resolve(
                artist: song.artistName,
                title: song.title,
                album: song.albumTitle ?? "",
                duration: song.duration
            ) else {
                unresolved += 1
                log.warning("LibraryIndex could not resolve \(song.artistName, privacy: .public) — \(song.title, privacy: .public)")
                continue
            }
            let metadata = await AppleScriptBridge.getMetadata(persistentID: persistentID)
            let result = await matcher.findOriginal(
                artist: song.artistName,
                title: song.title,
                duration: song.duration ?? 0,
                isrc: song.isrc
            )

            var match = CompilationMatch(
                compilationAlbum: song.albumTitle ?? "Unknown Album",
                compilationTrackID: persistentID,
                artist: song.artistName,
                title: song.title,
                playCount: metadata.playCount,
                rating: metadata.rating,
                loved: metadata.loved,
                dateAdded: song.libraryAddedDate,
                compilationDuration: song.duration ?? 0,
                compilationURL: song.url,
                compilationISRC: song.isrc,
                originalAlbum: result.catalogSong?.albumTitle,
                originalAlbumArtist: result.albumArtist,
                originalCatalogID: result.catalogSong?.id.rawValue,
                originalDuration: result.catalogSong?.duration,
                originalURL: result.catalogSong?.url,
                originalISRC: result.catalogSong?.isrc,
                audioQualityAvailable: result.qualityAvailable,
                qualityWarning: nil,
                confidence: result.confidence,
                durationDelta: result.durationDelta
            )

            if let candidate = result.catalogSong,
               await matcher.isHigherQuality(song, candidate) {
                match.qualityWarning = "Compilation has higher quality available"
            }

            let (apply, reason) = applyGate(match: match, candidate: result.catalogSong)
            match.autoApply = apply
            match.gateReason = reason
            match.action = apply ? .replace : (result.catalogSong == nil ? .skip : .review)

            matches.append(match)
        }

        let previewURL = try writePreviewLog(matches: matches, outputDirectory: outputDirectory)
        log.info("Scan complete — resolved: \(matches.count), unresolved: \(unresolved), eligible: \(matches.filter(\.autoApply).count), needs review: \(matches.filter { !$0.autoApply && $0.originalAlbum != nil }.count)")
        return ScanReport(matches: matches, previewLogURL: previewURL, unresolved: unresolved)
    }

    // MARK: - Execute

    /// Apply the auto-applicable matches in place: edit `album` and `album artist`
    /// on the existing library track, clear its artwork, verify the writes stuck.
    /// Persistent ID and all other metadata (playlists, play count, rating,
    /// loved, date added) are preserved by virtue of not being touched.
    func execute(matches: [CompilationMatch], outputDirectory: URL) async throws -> ExecutionReport {
        let logURL = try createLogURL(outputDirectory: outputDirectory, prefix: "compilation-applied")
        var report = ExecutionReport(appliedLogURL: logURL)

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        for match in matches {
            guard match.autoApply else {
                report.notEligible += 1
                continue
            }
            guard let newAlbum = match.originalAlbum,
                  let newAlbumArtist = match.originalAlbumArtist else {
                report.errors.append("\(match.artist) — \(match.title): missing original album/artist")
                continue
            }

            let before = await AppleScriptBridge.getAlbumIdentity(persistentID: match.compilationTrackID)

            let setOK = await AppleScriptBridge.setAlbumIdentity(
                persistentID: match.compilationTrackID,
                album: newAlbum,
                albumArtist: newAlbumArtist
            )
            guard setOK else {
                report.errors.append("\(match.artist) — \(match.title): setAlbumIdentity failed")
                continue
            }

            _ = await AppleScriptBridge.clearArtwork(persistentID: match.compilationTrackID)

            let after = await AppleScriptBridge.getAlbumIdentity(persistentID: match.compilationTrackID)
            let verified = after?.album == newAlbum && after?.albumArtist == newAlbumArtist
            if !verified {
                report.verifyReverted += 1
                report.errors.append("\(match.artist) — \(match.title): write reverted (Sync Library may be overriding)")
                continue
            }

            appendLogLine(handle: handle, fields: [
                "ts": ISO8601DateFormatter().string(from: Date()),
                "persistent_id": match.compilationTrackID,
                "artist": match.artist,
                "title": match.title,
                "old_album": before?.album ?? "",
                "old_album_artist": before?.albumArtist ?? "",
                "new_album": newAlbum,
                "new_album_artist": newAlbumArtist,
                "duration_delta_seconds": match.durationDelta ?? 0,
                "gate_reason": match.gateReason ?? "",
            ])
            report.applied += 1
        }

        log.info("Execution complete — \(report)")
        return report
    }

    // MARK: - Auto-apply gate

    /// Decide whether a match is safe to auto-apply.
    ///
    /// Pass when ANY of:
    ///   - ISRC present on both AND identical (with comp/demos check on candidate)
    ///
    /// OR when ALL of:
    ///   - candidate title == library title (case-insensitive exact)
    ///   - candidate artist == library artist (case-insensitive exact)
    ///   - candidate duration within ±3s of library duration
    ///   - candidate album_artist == library artist (single-artist album, not Various Artists)
    ///   - candidate album does NOT match looksLikeCompilation
    ///   - candidate album does NOT match looksLikeDemoOrOuttakes
    ///   - live-status (live/unplugged/acoustic in either title or album) matches between current and candidate
    ///
    /// Hard skip when ISRCs are present on both but mismatch — different recording.
    private func applyGate(
        match: CompilationMatch,
        candidate: Song?
    ) -> (apply: Bool, reason: String) {
        guard let candidate = candidate else {
            return (false, "no candidate match found")
        }
        guard let candidateAlbumTitle = candidate.albumTitle else {
            return (false, "candidate has no album title")
        }

        if let trackISRC = match.compilationISRC, !trackISRC.isEmpty,
           let candidateISRC = candidate.isrc, !candidateISRC.isEmpty {
            if trackISRC == candidateISRC {
                if CatalogMatcher.looksLikeCompilation(candidateAlbumTitle) {
                    return (false, "ISRC matched but candidate album looks like a compilation")
                }
                if CatalogMatcher.looksLikeDemoOrOuttakes(candidateAlbumTitle) {
                    return (false, "ISRC matched but candidate album looks like demos/outtakes")
                }
                return (true, "ISRC match")
            } else {
                return (false, "ISRC mismatch — different recording")
            }
        }

        if candidate.title.localizedCaseInsensitiveCompare(match.title) != .orderedSame {
            return (false, "candidate title differs from library title")
        }
        if candidate.artistName.localizedCaseInsensitiveCompare(match.artist) != .orderedSame {
            return (false, "candidate artist differs from library artist")
        }
        let durDelta = abs((candidate.duration ?? 0) - match.compilationDuration)
        if durDelta > Self.durationToleranceSeconds {
            return (false, String(format: "duration delta %.1fs exceeds %.0fs tolerance", durDelta, Self.durationToleranceSeconds))
        }
        guard let albumArtist = match.originalAlbumArtist, !albumArtist.isEmpty else {
            return (false, "candidate album_artist could not be fetched (album lookup failed)")
        }
        if albumArtist.localizedCaseInsensitiveCompare(match.artist) != .orderedSame {
            return (false, "candidate album_artist '\(albumArtist)' is not the track artist (likely Various Artists)")
        }
        if CatalogMatcher.looksLikeCompilation(candidateAlbumTitle) {
            return (false, "candidate album name suggests compilation")
        }
        if CatalogMatcher.looksLikeDemoOrOuttakes(candidateAlbumTitle) {
            return (false, "candidate album name suggests demos/outtakes")
        }
        if CatalogMatcher.liveStatusMismatch(
            currentTitle: match.title, currentAlbum: match.compilationAlbum,
            candidateTitle: candidate.title, candidateAlbum: candidateAlbumTitle
        ) {
            return (false, "live/unplugged/acoustic status differs")
        }
        return (true, "exact name+artist, duration ±\(Int(Self.durationToleranceSeconds))s, single-artist album, no comp/demo/live signals")
    }

    // MARK: - Logs

    private func writePreviewLog(matches: [CompilationMatch], outputDirectory: URL) throws -> URL {
        let url = try createLogURL(outputDirectory: outputDirectory, prefix: "compilation-preview")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for match in matches {
            appendLogLine(handle: handle, fields: [
                "auto_apply": match.autoApply,
                "gate_reason": match.gateReason ?? "",
                "persistent_id": match.compilationTrackID,
                "artist": match.artist,
                "title": match.title,
                "current_album": match.compilationAlbum,
                "proposed_album": match.originalAlbum ?? "",
                "proposed_album_artist": match.originalAlbumArtist ?? "",
                "duration_delta_seconds": match.durationDelta ?? 0,
                "confidence": match.confidence.rawValue,
                "isrc_current": match.compilationISRC ?? "",
                "isrc_candidate": match.originalISRC ?? "",
            ])
        }
        return url
    }

    private func createLogURL(outputDirectory: URL, prefix: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = outputDirectory.appendingPathComponent("\(prefix)-\(timestamp).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func appendLogLine(handle: FileHandle, fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let bytes = line.data(using: .utf8) {
            try? handle.write(contentsOf: bytes)
        }
    }
}
