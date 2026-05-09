import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.albumlint", category: "CompilationReplacer")

/// Scans for compilation tracks and relabels them in place to point at their
/// original studio albums. Preserves persistent ID, playlist memberships,
/// play count, rating, favorited status, and date-added — only `album` and
/// `album artist` change. Artwork is cleared so Apple Music will re-fetch it
/// when the user manually refreshes (Apple won't replace existing artwork
/// just because metadata changed).
///
/// Single-pass: each track is matched, gated, and applied in one loop iteration.
/// Every track produces one line in the run log with a `result` field
/// (applied / skipped / verify_reverted / error / unresolved / unmatched) so the
/// log doubles as both audit trail and reversibility record.
actor CompilationReplacer {

    private let scanner = LibraryScanner()
    private let matcher = CatalogMatcher()

    /// ±3s duration window for the auto-apply gate. Wider than typical mastering
    /// drift, narrower than fade/edit differences and live-vs-studio gaps.
    private static let durationToleranceSeconds: TimeInterval = 3

    /// Persistent Music.app playlist that mirrors the *most recent* run's
    /// applied changes. Wiped at the start of every run so it always shows
    /// just-now activity; the JSONL log files keep the durable history.
    private static let recentChangesPlaylist = "AlbumLint — Recently Relabeled"

    // MARK: - Report

    struct RunReport: CustomStringConvertible {
        var applied = 0
        var skipped = 0           // matched but failed the auto-apply gate
        var verifyReverted = 0    // write succeeded but readback differed (Sync Library override)
        var unmatched = 0         // matcher found no candidate
        var unresolved = 0        // LibraryIndex couldn't map to a persistent ID
        var errors: [String] = []
        var logURL: URL?
        /// Name of the Music.app playlist accumulating this run's applied
        /// changes. Populated when applied > 0 so the ViewModel can surface it.
        var playlistName: String?

        var total: Int { applied + skipped + verifyReverted + unmatched + unresolved + errors.count }

        var description: String {
            var parts = ["Applied: \(applied)"]
            if skipped > 0 { parts.append("skipped: \(skipped)") }
            if verifyReverted > 0 { parts.append("reverted: \(verifyReverted)") }
            if unmatched > 0 { parts.append("unmatched: \(unmatched)") }
            if unresolved > 0 { parts.append("unresolved: \(unresolved)") }
            if !errors.isEmpty { parts.append("errors: \(errors.count)") }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Run

    /// Scan and apply in one pass. Each compilation track is matched, gated,
    /// and (when eligible) relabeled in place. The single JSONL log captures
    /// every track's outcome — applied entries record old + new values for
    /// reversibility; non-applied entries record the gate reason for audit.
    func run(outputDirectory: URL) async throws -> RunReport {
        log.info("Starting compilation run")
        let compilationSongs = try await scanner.compilationTracks()
        log.info("Found \(compilationSongs.count) compilation tracks")

        // MusicKit's Song.id.rawValue is a catalog ID, not a Music.app persistent ID
        // — they're disjoint namespaces. Build the index once so we can translate
        // each library Song to the persistent ID AppleScript actually accepts.
        let libraryIndex = try await LibraryIndex.build()

        let logURL = try createLogURL(outputDirectory: outputDirectory, prefix: "compilation-run")
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        // Reset the accumulator playlist so it reflects only this run's changes.
        // Durable history lives in the JSONL log; this playlist is the at-a-glance
        // browsable view inside Music.app.
        _ = await AppleScriptBridge.deletePlaylist(name: Self.recentChangesPlaylist)

        var report = RunReport(logURL: logURL)

        for song in compilationSongs {
            guard let persistentID = await libraryIndex.resolve(
                artist: song.artistName,
                title: song.title,
                album: song.albumTitle ?? "",
                duration: song.duration
            ) else {
                report.unresolved += 1
                appendLogLine(handle: handle, fields: songFields(song, result: "unresolved", reason: "LibraryIndex could not map this track to a Music.app persistent ID"))
                log.warning("Unresolved: \(song.artistName, privacy: .public) — \(song.title, privacy: .public)")
                continue
            }

            let match = await matcher.findOriginal(
                artist: song.artistName,
                title: song.title,
                duration: song.duration ?? 0,
                isrc: song.isrc
            )

            guard let candidate = match.catalogSong else {
                report.unmatched += 1
                appendLogLine(handle: handle, fields: songFields(song, result: "unmatched", reason: "matcher found no candidate", persistentID: persistentID))
                continue
            }

            let (apply, reason) = applyGate(
                song: song,
                persistentID: persistentID,
                candidate: candidate,
                candidateAlbumArtist: match.albumArtist,
                durationDelta: match.durationDelta
            )

            guard apply,
                  let newAlbum = candidate.albumTitle,
                  let newAlbumArtist = match.albumArtist else {
                report.skipped += 1
                appendLogLine(handle: handle, fields: songFields(song, result: "skipped", reason: reason, persistentID: persistentID, candidate: candidate, candidateAlbumArtist: match.albumArtist))
                continue
            }

            let before = await AppleScriptBridge.getAlbumIdentity(persistentID: persistentID)

            let setOK = await AppleScriptBridge.setAlbumIdentity(
                persistentID: persistentID,
                album: newAlbum,
                albumArtist: newAlbumArtist
            )
            guard setOK else {
                let msg = "\(song.artistName) — \(song.title): setAlbumIdentity failed"
                report.errors.append(msg)
                appendLogLine(handle: handle, fields: songFields(song, result: "error", reason: "setAlbumIdentity AppleScript failed", persistentID: persistentID, candidate: candidate, candidateAlbumArtist: match.albumArtist))
                continue
            }

            // Push the new album's artwork directly. Apple's `Get Album Artwork`
            // and Sync Library auto-restore both fail to fetch art for the
            // new album on a relabeled track — Apple's artwork cache is keyed
            // to persistent ID, not to the album field. Overwriting the existing
            // artwork slot in place sticks (delete + re-add does not).
            // Best-effort: artwork failure does not block the relabel.
            if let artworkURL = match.albumArtworkURL,
               let tempPath = await downloadArtwork(from: artworkURL) {
                _ = await AppleScriptBridge.setArtwork(persistentID: persistentID, imagePath: tempPath)
                try? FileManager.default.removeItem(atPath: tempPath)
            }

            let after = await AppleScriptBridge.getAlbumIdentity(persistentID: persistentID)
            let verified = after?.album == newAlbum && after?.albumArtist == newAlbumArtist
            if !verified {
                report.verifyReverted += 1
                appendLogLine(handle: handle, fields: songFields(song, result: "verify_reverted", reason: "write reverted (likely iCloud Music Library override)", persistentID: persistentID, candidate: candidate, candidateAlbumArtist: match.albumArtist, before: before))
                continue
            }

            report.applied += 1
            appendLogLine(handle: handle, fields: songFields(song, result: "applied", reason: reason, persistentID: persistentID, candidate: candidate, candidateAlbumArtist: match.albumArtist, before: before))
            _ = await AppleScriptBridge.addToPlaylist(persistentID: persistentID, playlistName: Self.recentChangesPlaylist)
        }

        if report.applied > 0 {
            report.playlistName = Self.recentChangesPlaylist
        }
        log.info("Run complete — \(report)")
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
    ///   - live/unplugged/acoustic status matches between current and candidate
    ///
    /// Hard skip when ISRCs are present on both but mismatch — different recording.
    private func applyGate(
        song: Song,
        persistentID: String,
        candidate: Song,
        candidateAlbumArtist: String?,
        durationDelta: TimeInterval?
    ) -> (apply: Bool, reason: String) {
        guard let candidateAlbumTitle = candidate.albumTitle else {
            return (false, "candidate has no album title")
        }

        // Hard reject: when the library track itself has no specific artist
        // ("Various Artists" appears as the song-level artistName for some
        // classical/holiday tracks), there's no single artist to bias toward.
        // Relabeling moves the track from one compilation to another, which
        // is meaningless and pollutes the library.
        if song.artistName.localizedCaseInsensitiveCompare("Various Artists") == .orderedSame {
            return (false, "track artist is 'Various Artists' — no single artist to relabel toward")
        }

        if let trackISRC = song.isrc, !trackISRC.isEmpty,
           let candidateISRC = candidate.isrc, !candidateISRC.isEmpty {
            if trackISRC == candidateISRC {
                if CatalogMatcher.looksLikeCompilation(candidateAlbumTitle) {
                    return (false, "ISRC matched but candidate album looks like a compilation")
                }
                if CatalogMatcher.looksLikeDemoOrOuttakes(candidateAlbumTitle) {
                    return (false, "ISRC matched but candidate album looks like demos/outtakes")
                }
                if let aa = candidateAlbumArtist,
                   aa.localizedCaseInsensitiveCompare("Various Artists") == .orderedSame {
                    return (false, "ISRC matched but candidate album_artist is 'Various Artists' (another compilation)")
                }
                return (true, "ISRC match")
            } else {
                return (false, "ISRC mismatch — different recording")
            }
        }

        // Compare titles after stripping parenthetical / bracketed qualifiers
        // so "Maggie May" matches "Maggie May (2009 Remaster)" and similar.
        // The matcher already considers these the same recording; the gate
        // shouldn't reject on cosmetic suffix differences.
        let songTitleClean = CatalogMatcher.cleanTitle(song.title)
        let candidateTitleClean = CatalogMatcher.cleanTitle(candidate.title)
        if candidateTitleClean.localizedCaseInsensitiveCompare(songTitleClean) != .orderedSame {
            return (false, "candidate title differs from library title")
        }
        if candidate.artistName.localizedCaseInsensitiveCompare(song.artistName) != .orderedSame {
            return (false, "candidate artist differs from library artist")
        }
        let durDelta = abs((candidate.duration ?? 0) - (song.duration ?? 0))
        if durDelta > Self.durationToleranceSeconds {
            return (false, String(format: "duration delta %.1fs exceeds %.0fs tolerance", durDelta, Self.durationToleranceSeconds))
        }
        guard let albumArtist = candidateAlbumArtist, !albumArtist.isEmpty else {
            return (false, "candidate album_artist could not be fetched (album lookup failed)")
        }
        if albumArtist.localizedCaseInsensitiveCompare("Various Artists") == .orderedSame {
            return (false, "candidate album_artist is 'Various Artists' (another compilation)")
        }
        if albumArtist.localizedCaseInsensitiveCompare(song.artistName) != .orderedSame {
            return (false, "candidate album_artist '\(albumArtist)' is not the track artist")
        }
        if CatalogMatcher.looksLikeCompilation(candidateAlbumTitle) {
            return (false, "candidate album name suggests compilation")
        }
        if CatalogMatcher.looksLikeDemoOrOuttakes(candidateAlbumTitle) {
            return (false, "candidate album name suggests demos/outtakes")
        }
        if CatalogMatcher.liveStatusMismatch(
            currentTitle: song.title, currentAlbum: song.albumTitle ?? "",
            candidateTitle: candidate.title, candidateAlbum: candidateAlbumTitle
        ) {
            return (false, "live/unplugged/acoustic status differs")
        }
        return (true, "exact name+artist, duration ±\(Int(Self.durationToleranceSeconds))s, single-artist album, no comp/demo/live signals")
    }

    // MARK: - Artwork

    /// Download an album artwork image from `url` to a temporary file.
    /// Returns the temp file path on success, nil on any failure (network,
    /// non-image content, etc.). Caller is responsible for cleanup.
    private func downloadArtwork(from url: URL) async -> String? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                log.debug("Artwork download non-2xx for \(url.absoluteString, privacy: .public)")
                return nil
            }
            let tempPath = NSTemporaryDirectory() + "albumlint-artwork-\(UUID().uuidString).jpg"
            try data.write(to: URL(fileURLWithPath: tempPath))
            return tempPath
        } catch {
            log.debug("Artwork download failed: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Logs

    private func songFields(
        _ song: Song,
        result: String,
        reason: String,
        persistentID: String? = nil,
        candidate: Song? = nil,
        candidateAlbumArtist: String? = nil,
        before: (album: String, albumArtist: String)? = nil
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "result": result,
            "reason": reason,
            "artist": song.artistName,
            "title": song.title,
            "current_album": song.albumTitle ?? "",
            "current_isrc": song.isrc ?? "",
            "current_duration": song.duration ?? 0,
        ]
        if let pid = persistentID { fields["persistent_id"] = pid }
        if let candidate {
            fields["proposed_title"] = candidate.title
            fields["proposed_album"] = candidate.albumTitle ?? ""
            fields["proposed_album_artist"] = candidateAlbumArtist ?? ""
            fields["proposed_isrc"] = candidate.isrc ?? ""
            fields["proposed_duration"] = candidate.duration ?? 0
        }
        if let before {
            fields["old_album"] = before.album
            fields["old_album_artist"] = before.albumArtist
        }
        return fields
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
