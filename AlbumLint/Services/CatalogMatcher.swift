import Foundation
import MusicKit
import os

private let log = Logger(subsystem: "com.albumlint", category: "CatalogMatcher")

/// Matches library tracks to original album versions in the Apple Music catalog.
actor CatalogMatcher {

    /// Result of attempting to match a track to its original album version.
    struct MatchResult {
        let catalogSong: Song?
        let confidence: MatchConfidence
        let durationDelta: TimeInterval?
        let matchMethod: String     // "isrc", "search", "none"
        let qualityAvailable: String?
    }

    // MARK: - Public API

    /// Find the original (non-compilation) album version of a song.
    func findOriginal(artist: String, title: String, duration: TimeInterval, isrc: String?) async -> MatchResult {
        // Priority 1: ISRC match
        if let isrc, let result = await matchByISRC(isrc: isrc, duration: duration) {
            return result
        }

        // Priority 2: Search by artist + title with fuzzy scoring
        if let result = await matchBySearch(artist: artist, title: title, duration: duration) {
            return result
        }

        return MatchResult(catalogSong: nil, confidence: .none, durationDelta: nil, matchMethod: "none", qualityAvailable: nil)
    }

    /// Find a studio version of a live track.
    func findStudioVersion(artist: String, liveTitle: String, duration: TimeInterval) async -> MatchResult {
        let cleanTitle = stripLiveQualifiers(from: liveTitle)
        if let result = await matchBySearch(artist: artist, title: cleanTitle, duration: duration, excludeLive: true) {
            return result
        }
        return MatchResult(catalogSong: nil, confidence: .none, durationDelta: nil, matchMethod: "none", qualityAvailable: nil)
    }

    // MARK: - ISRC Matching

    private func matchByISRC(isrc: String, duration: TimeInterval) async -> MatchResult? {
        do {
            var request = MusicCatalogSearchRequest(term: isrc, types: [Song.self])
            request.limit = 25
            let response = try await request.response()

            // Find non-compilation songs with matching ISRC
            // Song doesn't have isCompilation — filter by album name heuristic
            let candidates = response.songs.filter { song in
                song.isrc == isrc && !Self.looksLikeCompilation(song.albumTitle ?? "")
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
                qualityAvailable: quality
            )
        } catch {
            log.error("ISRC search failed for \(isrc): \(error)")
            return nil
        }
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
                qualityAvailable: quality
            )
        } catch {
            log.error("Catalog search failed for \(artist) - \(title): \(error)")
            return nil
        }
    }

    // MARK: - Scoring

    /// Score a candidate song against the target. Returns 0.0-1.0.
    private func score(candidate: Song, targetArtist: String, targetTitle: String, targetDuration: TimeInterval) -> Double {
        var total = 0.0

        // Artist match (0.3 weight)
        let artistSimilarity = stringSimilarity(candidate.artistName.lowercased(), targetArtist.lowercased())
        total += artistSimilarity * 0.3

        // Title match (0.3 weight)
        let titleSimilarity = stringSimilarity(candidate.title.lowercased(), targetTitle.lowercased())
        total += titleSimilarity * 0.3

        // Duration match (0.3 weight) — most important differentiator
        let candidateDuration = candidate.duration ?? 0
        if candidateDuration > 0 && targetDuration > 0 {
            let delta = abs(candidateDuration - targetDuration)
            if delta <= 2 {
                total += 0.3          // Near-exact duration
            } else if delta <= 5 {
                total += 0.25         // Close enough (fade differences)
            } else if delta <= 15 {
                total += 0.15         // Possibly different mix
            } else if delta <= 30 {
                total += 0.05         // Likely different version
            }
            // > 30s difference: 0 points
        }

        // Prefer earliest release year (0.1 weight) — original over reissue
        if let releaseDate = candidate.releaseDate {
            let year = Calendar.current.component(.year, from: releaseDate)
            if year < 1990 { total += 0.1 }
            else if year < 2000 { total += 0.08 }
            else if year < 2010 { total += 0.06 }
            else { total += 0.04 }
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

    /// Heuristic to detect compilation albums by name.
    static func looksLikeCompilation(_ albumName: String) -> Bool {
        let lower = albumName.lowercased()
        let patterns = [
            "greatest hits", "best of", "the essential",
            "the very best", "gold", "anthology",
            "collected", "the collection", "super hits",
            "number ones", "#1", "no. 1",
            "20 greatest", "the definitive", "the ultimate",
            "legends", "classic", "hits!", "biggest hits",
            "now that's what i call"
        ]
        return patterns.contains { lower.contains($0) }
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
