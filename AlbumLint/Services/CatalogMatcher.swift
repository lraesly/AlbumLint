import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.albumlint", category: "CatalogMatcher")

/// Matches library tracks to original album versions in the Apple Music catalog.
actor CatalogMatcher {

    /// Hard filter for the song-search path: any candidate whose duration
    /// drifts more than this from the library track's duration is excluded
    /// before scoring. Aligned with CompilationReplacer's gate threshold so
    /// the matcher and the gate agree on what's acceptable.
    private static let songSearchDurationToleranceSeconds: TimeInterval = 3

    /// Result of attempting to match a track to its original album version.
    struct MatchResult {
        let catalogSong: Song?
        let confidence: MatchConfidence
        let durationDelta: TimeInterval?
        let matchMethod: String     // "isrc", "search", "none"
        let qualityAvailable: String?
        /// Album-artist of the matched candidate's release (NOT the track artist).
        /// Only populated by `findOriginal` — `findStudioVersion` leaves it nil.
        /// Required by the auto-apply gate to verify the candidate is a single-artist album
        /// (== track's artist) rather than a Various Artists release with a non-obvious title.
        let albumArtist: String?
        /// URL of the album's artwork (1500×1500). Populated by `findOriginal`
        /// alongside albumArtist via the same album fetch. Used by
        /// CompilationReplacer to push correct artwork onto the relabeled track —
        /// Apple Music won't re-fetch on its own when the album field changes.
        let albumArtworkURL: URL?
    }

    // MARK: - Public API

    /// Find the original (non-compilation) album version of a song.
    /// Populates `MatchResult.albumArtist` via a follow-up album fetch on the
    /// chosen candidate so callers can verify single-artist-album status
    /// before auto-applying.
    ///
    /// Resolution order:
    ///   1. ISRC match (if ISRC available on library track)
    ///   2. Song search → tier 1 (single-artist studio album, earliest)
    ///   3. Discography fallback (search artist's albums, find the track)
    ///   4. Song search → tier 2 (single-artist comp, earliest)
    ///   5. Song search → multi-artist fallback (gate likely rejects)
    ///
    /// `matchMethod` field reflects which path won so the caller can log it.
    func findOriginal(artist: String, title: String, duration: TimeInterval, isrc: String?) async -> MatchResult {
        if let isrc, let result = await matchByISRC(isrc: isrc, duration: duration) {
            return await populatingAlbumArtist(result)
        }

        let tiers = await searchSongTiers(artist: artist, title: title, duration: duration)

        if let chosen = earliestByReleaseDate(tiers.tier1Studio) {
            logChoice(tier: "song_tier1", artist: artist, title: title, chosen: chosen)
            return tagged(chosen, "song_tier1")
        }

        if let chosen = await findViaDiscography(artist: artist, title: title, duration: duration) {
            logChoice(tier: "discography", artist: artist, title: title, chosen: chosen)
            return tagged(chosen, "discography")
        }

        if let chosen = earliestByReleaseDate(tiers.tier2Comp) {
            logChoice(tier: "song_tier2", artist: artist, title: title, chosen: chosen)
            return tagged(chosen, "song_tier2")
        }

        if let fb = tiers.fallbackBest {
            return tagged(fb, "song_fallback")
        }

        return MatchResult(catalogSong: nil, confidence: .none, durationDelta: nil, matchMethod: "none", qualityAvailable: nil, albumArtist: nil, albumArtworkURL: nil)
    }

    /// Construct a copy of `r` with a different matchMethod label.
    private func tagged(_ r: MatchResult, _ method: String) -> MatchResult {
        MatchResult(
            catalogSong: r.catalogSong,
            confidence: r.confidence,
            durationDelta: r.durationDelta,
            matchMethod: method,
            qualityAvailable: r.qualityAvailable,
            albumArtist: r.albumArtist,
            albumArtworkURL: r.albumArtworkURL
        )
    }

    /// Find a studio version of a live track.
    func findStudioVersion(artist: String, liveTitle: String, duration: TimeInterval) async -> MatchResult {
        let cleanTitle = stripLiveQualifiers(from: liveTitle)
        if let result = await matchBySearch(artist: artist, title: cleanTitle, duration: duration, excludeLive: true) {
            return result
        }
        return MatchResult(catalogSong: nil, confidence: .none, durationDelta: nil, matchMethod: "none", qualityAvailable: nil, albumArtist: nil, albumArtworkURL: nil)
    }

    /// Fetch the catalog song's album relationship and rebuild the MatchResult
    /// with its album-artist and album-artwork URL. Returns the original
    /// result unchanged on fetch failure (network blip shouldn't blow away an
    /// otherwise-good match).
    private func populatingAlbumArtist(_ result: MatchResult) async -> MatchResult {
        guard let song = result.catalogSong else { return result }
        do {
            let detailed = try await song.with([.albums])
            let firstAlbum = detailed.albums?.first
            let albumArtist = firstAlbum?.artistName
            let artworkURL = firstAlbum?.artwork?.url(width: 1500, height: 1500)
            return MatchResult(
                catalogSong: result.catalogSong,
                confidence: result.confidence,
                durationDelta: result.durationDelta,
                matchMethod: result.matchMethod,
                qualityAvailable: result.qualityAvailable,
                albumArtist: albumArtist,
                albumArtworkURL: artworkURL
            )
        } catch {
            log.debug("Album fetch failed for \(song.id.rawValue): \(error)")
            return result
        }
    }

    // MARK: - ISRC Matching

    private func matchByISRC(isrc: String, duration: TimeInterval) async -> MatchResult? {
        do {
            var request = MusicCatalogSearchRequest(term: isrc, types: [Song.self])
            request.limit = 25
            let response = try await request.response()

            // Same recording can appear on multiple releases. Reject hard
            // non-album releases (singles / EPs / re-recordings) and demos.
            // Compilations are NOT rejected — they're an acceptable fallback
            // if no studio release is found. Within remaining candidates,
            // prefer the earliest release date.
            let usable = response.songs.filter { song in
                guard song.isrc == isrc else { return false }
                let title = song.albumTitle ?? ""
                return !Self.looksLikeNonAlbumRelease(title) && !Self.looksLikeDemoOrOuttakes(title)
            }

            // Tier 1 = studio album, Tier 2 = single-artist comp acceptable fallback.
            let tier1 = usable.filter { !Self.looksLikeCompilation($0.albumTitle ?? "") }
            let pool = tier1.isEmpty ? usable : tier1
            let candidates = pool.sorted { (a, b) in
                (a.releaseDate ?? .distantFuture) < (b.releaseDate ?? .distantFuture)
            }

            guard let best = candidates.first else { return nil }

            let durationDelta = abs((best.duration ?? 0) - duration)
            let confidence: MatchConfidence = durationDelta <= 5 ? .high : .medium
            let quality = describeAudioQuality(best)

            log.info("ISRC match for \(isrc): \(best.artistName) - \(best.title) (delta: \(durationDelta)s)")

            return MatchResult(
                catalogSong: best,
                confidence: confidence,
                durationDelta: durationDelta,
                matchMethod: "isrc",
                qualityAvailable: quality,
                albumArtist: nil,
                albumArtworkURL: nil
            )
        } catch {
            log.error("ISRC search failed for \(isrc): \(error)")
            return nil
        }
    }

    // MARK: - Search Matching with Single-Artist Iteration

    /// Tiered results from the catalog song search. `findOriginal` picks
    /// based on tier priority (tier1 first, then discography fallback, then
    /// tier2, then fallbackBest) so the caller can interleave a discography
    /// search between tier 1 and tier 2.
    private struct SongSearchTiers {
        let tier1Studio: [MatchResult]
        let tier2Comp: [MatchResult]
        let fallbackBest: MatchResult?
        static var empty: SongSearchTiers { .init(tier1Studio: [], tier2Comp: [], fallbackBest: nil) }
    }

    /// Search the catalog by "artist title" and classify each candidate into:
    ///
    ///   Tier 1: single-artist studio album (album_artist == queried artist
    ///           AND album NOT looksLikeCompilation)
    ///   Tier 2: single-artist compilation (album_artist == queried artist
    ///           AND album IS looksLikeCompilation)
    ///   Fallback: highest-scored candidate among any (gate may reject)
    ///
    /// Within iteration we hard-reject Various Artists, demos/outtakes, and
    /// non-album releases (singles, EPs, re-recordings). Iterates up to top
    /// 20 with smart-stop after collecting 3 tier-1 candidates — bounds the
    /// per-match album-fetch cost.
    private func searchSongTiers(
        artist: String, title: String, duration: TimeInterval
    ) async -> SongSearchTiers {
        do {
            let searchTerm = "\(artist) \(title)"
            var request = MusicCatalogSearchRequest(term: searchTerm, types: [Song.self])
            request.limit = 25
            let response = try await request.response()

            // Hard pre-filter aligned with the gate: any candidate that the
            // gate would later reject on duration or title is filtered out
            // BEFORE scoring. Without this, the year-weighted score would
            // happily rank an old wrong-duration candidate above a recent
            // right-duration one, the matcher would pick the old one, and
            // the gate would reject it — losing a relabel that should have
            // landed on the right candidate further down.
            let queryTitleClean = Self.cleanTitle(title)
            let qualified = response.songs.filter { song in
                let durationDelta = abs((song.duration ?? 0) - duration)
                guard durationDelta <= Self.songSearchDurationToleranceSeconds else { return false }
                let songTitleClean = Self.cleanTitle(song.title)
                return songTitleClean.localizedCaseInsensitiveCompare(queryTitleClean) == .orderedSame
            }

            let scored = qualified
                .map { song -> (song: Song, score: Double) in
                    let s = self.score(
                        candidate: song,
                        targetArtist: artist,
                        targetTitle: title,
                        targetDuration: duration
                    )
                    return (song, s)
                }
                .sorted { $0.score > $1.score }
                .prefix(20)

            guard !scored.isEmpty else { return .empty }

            var tier1Studio: [MatchResult] = []
            var tier2Comp: [MatchResult] = []
            var fallbackBest: MatchResult? = nil

            for scoredCandidate in scored {
                let (song, score) = scoredCandidate
                guard score > 0.3 else { break }
                let albumTitle = song.albumTitle ?? ""

                if Self.looksLikeNonAlbumRelease(albumTitle) { continue }
                if Self.looksLikeDemoOrOuttakes(albumTitle) { continue }

                let durationDelta = abs((song.duration ?? 0) - duration)
                let result = MatchResult(
                    catalogSong: song,
                    confidence: confidenceFromScore(score, durationDelta: durationDelta),
                    durationDelta: durationDelta,
                    matchMethod: "search",
                    qualityAvailable: describeAudioQuality(song),
                    albumArtist: nil,
                    albumArtworkURL: nil
                )
                let withAlbum = await populatingAlbumArtist(result)
                if fallbackBest == nil { fallbackBest = withAlbum }

                guard let aa = withAlbum.albumArtist,
                      aa.localizedCaseInsensitiveCompare(artist) == .orderedSame,
                      aa.localizedCaseInsensitiveCompare("Various Artists") != .orderedSame
                else { continue }

                if Self.looksLikeCompilation(albumTitle) {
                    tier2Comp.append(withAlbum)
                } else {
                    tier1Studio.append(withAlbum)
                    if tier1Studio.count >= 3 { break }
                }
            }

            return SongSearchTiers(
                tier1Studio: tier1Studio,
                tier2Comp: tier2Comp,
                fallbackBest: fallbackBest
            )
        } catch {
            log.error("Catalog song search failed for \(artist) - \(title): \(error)")
            return .empty
        }
    }

    /// Discography fallback: when the song search didn't surface a single-
    /// artist studio album in its top 20 (common for famous tracks dominated
    /// by comps in catalog ranking), search for the artist's albums directly,
    /// walk earliest-first, and find the album that contains a track matching
    /// our title. Lands on the original studio release rather than whatever
    /// recent comp happens to outrank it in the song-level search.
    ///
    /// Bounded cost: 1 album search + up to 15 track fetches (early stop on
    /// first hit). Only fires when song-search tier 1 is empty.
    private func findViaDiscography(
        artist: String, title: String, duration: TimeInterval
    ) async -> MatchResult? {
        do {
            var request = MusicCatalogSearchRequest(term: artist, types: [Album.self])
            request.limit = 25
            let response = try await request.response()

            // Filter to albums matching the queried artist; reject obvious
            // comps, demos, non-album releases. We want studio releases.
            let candidateAlbums = response.albums
                .filter { album in
                    album.artistName.localizedCaseInsensitiveCompare(artist) == .orderedSame
                        && !Self.looksLikeCompilation(album.title)
                        && !Self.looksLikeDemoOrOuttakes(album.title)
                        && !Self.looksLikeNonAlbumRelease(album.title)
                }
                .sorted { (a, b) in
                    (a.releaseDate ?? .distantFuture) < (b.releaseDate ?? .distantFuture)
                }
                .prefix(15)

            guard !candidateAlbums.isEmpty else { return nil }

            let queryTitleClean = Self.cleanTitle(title)

            for album in candidateAlbums {
                let detailed: Album
                do {
                    detailed = try await album.with([.tracks])
                } catch {
                    continue
                }
                guard let tracks = detailed.tracks else { continue }

                for track in tracks {
                    guard case .song(let song) = track else { continue }
                    let songTitleClean = Self.cleanTitle(song.title)
                    guard songTitleClean.localizedCaseInsensitiveCompare(queryTitleClean) == .orderedSame else { continue }
                    let durationDelta = abs((song.duration ?? 0) - duration)
                    // Wider tolerance for discography path — the album may
                    // host a slightly different mix or master of the same
                    // recording. Anything under 5s is the same recording.
                    guard durationDelta <= 5 else { continue }

                    let confidence: MatchConfidence = durationDelta <= 3 ? .high : .medium
                    let artworkURL = album.artwork?.url(width: 1500, height: 1500)
                    return MatchResult(
                        catalogSong: song,
                        confidence: confidence,
                        durationDelta: durationDelta,
                        matchMethod: "discography",
                        qualityAvailable: describeAudioQuality(song),
                        albumArtist: album.artistName,
                        albumArtworkURL: artworkURL
                    )
                }
            }

            return nil
        } catch {
            log.error("Discography search failed for \(artist): \(error)")
            return nil
        }
    }

    private func earliestByReleaseDate(_ matches: [MatchResult]) -> MatchResult? {
        matches.min { a, b in
            (a.catalogSong?.releaseDate ?? .distantFuture)
                < (b.catalogSong?.releaseDate ?? .distantFuture)
        }
    }

    private func logChoice(tier: String, artist: String, title: String, chosen: MatchResult) {
        let year: String
        if let d = chosen.catalogSong?.releaseDate {
            year = "\(Calendar.current.component(.year, from: d))"
        } else {
            year = "no date"
        }
        log.info("\(tier, privacy: .public) match for \(artist, privacy: .public) — \(title, privacy: .public): \(chosen.catalogSong?.albumTitle ?? "?", privacy: .public) (\(year, privacy: .public))")
    }

    // MARK: - Search Matching

    private func matchBySearch(artist: String, title: String, duration: TimeInterval, excludeLive: Bool = false) async -> MatchResult? {
        do {
            let searchTerm = "\(artist) \(title)"
            var request = MusicCatalogSearchRequest(term: searchTerm, types: [Song.self])
            request.limit = 25
            let response = try await request.response()

            let scored = response.songs
                .filter { song in
                    // Exclude compilations by album name heuristic
                    if Self.looksLikeCompilation(song.albumTitle ?? "") { return false }
                    // Optionally exclude live albums
                    if excludeLive, isLiveAlbum(song.albumTitle ?? "") { return false }
                    return true
                }
                .map { song -> (song: Song, score: Double) in
                    let score = self.score(
                        candidate: song,
                        targetArtist: artist,
                        targetTitle: title,
                        targetDuration: duration
                    )
                    return (song, score)
                }
                .sorted { $0.score > $1.score }

            guard let best = scored.first, best.score > 0.3 else { return nil }

            let durationDelta = abs((best.song.duration ?? 0) - duration)
            let confidence = confidenceFromScore(best.score, durationDelta: durationDelta)
            let quality = describeAudioQuality(best.song)

            log.info("Search match for \(artist) - \(title): \(best.song.albumTitle ?? "?") (score: \(String(format: "%.2f", best.score)), delta: \(durationDelta)s)")

            return MatchResult(
                catalogSong: best.song,
                confidence: confidence,
                durationDelta: durationDelta,
                matchMethod: "search",
                qualityAvailable: quality,
                albumArtist: nil,
                albumArtworkURL: nil
            )
        } catch {
            log.error("Catalog search failed for \(artist) - \(title): \(error)")
            return nil
        }
    }

    // MARK: - Scoring

    /// Score a candidate song against the target. Returns 0.0-1.0.
    /// Year preference is rebalanced from 0.1 to 0.25 weight so older
    /// originals rise high enough to enter the matcher's iteration window
    /// rather than getting buried below recent compilations.
    private func score(candidate: Song, targetArtist: String, targetTitle: String, targetDuration: TimeInterval) -> Double {
        var total = 0.0

        // Artist match (0.25 weight)
        let artistSimilarity = stringSimilarity(candidate.artistName.lowercased(), targetArtist.lowercased())
        total += artistSimilarity * 0.25

        // Title match (0.25 weight)
        let titleSimilarity = stringSimilarity(candidate.title.lowercased(), targetTitle.lowercased())
        total += titleSimilarity * 0.25

        // Duration match (0.25 weight)
        let candidateDuration = candidate.duration ?? 0
        if candidateDuration > 0 && targetDuration > 0 {
            let delta = abs(candidateDuration - targetDuration)
            if delta <= 2 {
                total += 0.25
            } else if delta <= 5 {
                total += 0.20
            } else if delta <= 15 {
                total += 0.10
            } else if delta <= 30 {
                total += 0.04
            }
        }

        // Year preference (0.25 weight) — strongly prefer original-era releases
        // so famous tracks' studio originals rise above their many later comps.
        if let releaseDate = candidate.releaseDate {
            let year = Calendar.current.component(.year, from: releaseDate)
            if year < 1970 { total += 0.25 }
            else if year < 1980 { total += 0.21 }
            else if year < 1990 { total += 0.17 }
            else if year < 2000 { total += 0.13 }
            else if year < 2010 { total += 0.08 }
            else { total += 0.03 }
        }

        return min(total, 1.0)
    }

    private func confidenceFromScore(_ score: Double, durationDelta: TimeInterval) -> MatchConfidence {
        if score >= 0.8 && durationDelta <= 5 {
            return .high
        } else if score >= 0.6 && durationDelta <= 15 {
            return .medium
        } else {
            return .low
        }
    }

    // MARK: - String Similarity (Levenshtein-based)

    private func stringSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let maxLen = max(a.count, b.count)
        if maxLen == 0 { return 1.0 }
        let distance = levenshteinDistance(a, b)
        return 1.0 - (Double(distance) / Double(maxLen))
    }

    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        if m == 0 { return n }
        if n == 0 { return m }

        var matrix = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,       // deletion
                    matrix[i][j - 1] + 1,        // insertion
                    matrix[i - 1][j - 1] + cost  // substitution
                )
            }
        }
        return matrix[m][n]
    }

    // MARK: - Audio Quality

    private func describeAudioQuality(_ song: Song) -> String {
        let variants = song.audioVariants ?? []
        if variants.contains(.highResolutionLossless) {
            return "Hi-Res Lossless"
        } else if variants.contains(.lossless) {
            return "Lossless"
        } else if variants.contains(.dolbyAtmos) {
            return "Dolby Atmos"
        } else {
            return "AAC"
        }
    }

    /// Compare quality between two songs. Returns true if `a` is higher quality than `b`.
    func isHigherQuality(_ a: Song, _ b: Song) -> Bool {
        let order: [AudioVariant] = [.highResolutionLossless, .lossless, .dolbyAtmos]
        let aVariants = a.audioVariants ?? []
        let bVariants = b.audioVariants ?? []
        for variant in order {
            let aHas = aVariants.contains(variant)
            let bHas = bVariants.contains(variant)
            if aHas && !bHas { return true }
            if bHas && !aHas { return false }
        }
        return false
    }

    /// Heuristic to detect compilation albums by name. Single-artist comps
    /// (like "Greatest Hits", "The Complete Mercury Recordings") are NOT
    /// hard-rejected by the matcher — they're an acceptable fallback when no
    /// studio album is found. The matcher uses this to *classify* candidates
    /// into tier 1 (studio album) vs tier 2 (single-artist comp); the gate
    /// no longer hard-rejects on it.
    static func looksLikeCompilation(_ albumName: String) -> Bool {
        let lower = albumName.lowercased()
        let patterns = [
            "greatest hits", "best of", "the essential",
            "the very best", "gold", "anthology",
            "collected", "the collection", "super hits",
            "number ones", "#1", "no. 1",
            "20 greatest", "the definitive", "the ultimate",
            "legends", "classic", "hits!", "biggest hits",
            "now that's what i call",
            "the complete", "compilation", "boxed set", "box set",
            "album collection"
        ]
        return patterns.contains { lower.contains($0) }
    }

    /// Detect demos / outtakes / bootleg-series albums. Important for the
    /// auto-apply gate: an artist's earliest-by-release-date catalog entry
    /// can be a "Bootleg Series" or "Early Demos" release that's single-artist
    /// but not the studio album we want to relabel toward.
    static func looksLikeDemoOrOuttakes(_ albumName: String) -> Bool {
        guard !albumName.isEmpty else { return false }
        return albumName.range(
            of: #"\b(?:demos?|outtakes?|bootleg|sessions|home\s+recordings?|rehearsals?|alternate\s+takes?)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Detect releases that aren't an "album" in the studio-or-comp sense:
    /// singles (`...  - Single`), EPs (`...  - EP`), and re-recordings
    /// (`(Rerecorded)` / `Re-Recorded`). These are the wrong target for a
    /// relabel — the user wants the original studio release, not a one-off
    /// single drop or a later re-recording with different timbre.
    static func looksLikeNonAlbumRelease(_ albumName: String) -> Bool {
        guard !albumName.isEmpty else { return false }
        return albumName.range(
            of: #"(\s+-\s+(?:single|ep)\b|\bre-?recorded\b)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Strip parenthetical and bracketed qualifiers from a title and collapse
    /// whitespace. Used by the auto-apply gate to match titles whose parens
    /// content differs (e.g., "Maggie May" vs "Maggie May (2009 Remaster)" vs
    /// "Maggie May [Mono]"), which the matcher already considers the same
    /// recording but a strict equality check would reject.
    static func cleanTitle(_ title: String) -> String {
        let stripped = title.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*[\)\]]"#,
            with: "",
            options: .regularExpression
        )
        return stripped.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    /// True when one of the two tracks is a live/unplugged/acoustic rendition
    /// and the other isn't — strong signal that they're different recordings
    /// even when title and duration agree.
    static func liveStatusMismatch(
        currentTitle: String, currentAlbum: String,
        candidateTitle: String, candidateAlbum: String
    ) -> Bool {
        let pattern = #"\b(?:live|unplugged|acoustic)\b"#
        func hasLive(_ s: String) -> Bool {
            s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let currentLive = hasLive(currentTitle) || hasLive(currentAlbum)
        let candidateLive = hasLive(candidateTitle) || hasLive(candidateAlbum)
        return currentLive != candidateLive
    }

    // MARK: - Live Detection Helpers

    private func isLiveAlbum(_ albumName: String) -> Bool {
        let lower = albumName.lowercased()
        return LibraryScanner.liveKeywords.contains { lower.contains($0) }
    }

    private func stripLiveQualifiers(from title: String) -> String {
        var cleaned = title
        // Remove common live suffixes/qualifiers from title
        let patterns = [
            "\\s*\\(live[^)]*\\)",       // (Live at ...), (Live)
            "\\s*\\[live[^]]*\\]",       // [Live at ...], [Live]
            "\\s*-\\s*live.*$",          // - Live at ..., - Live
            "\\s*\\(unplugged[^)]*\\)",  // (Unplugged)
            "\\s*\\[unplugged[^]]*\\]",  // [Unplugged]
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
