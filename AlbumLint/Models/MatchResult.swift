import Foundation
import MusicKit

/// Confidence level for a catalog match.
enum MatchConfidence: String, Codable {
    case high
    case medium
    case low
    case none
}

/// Action the user wants to take on a row (editable in spreadsheet).
enum RowAction: String, Codable {
    case replace
    case skip
    case review
}

/// A compilation track matched to an original album version.
struct CompilationMatch: Identifiable {
    let id = UUID()

    // Source (compilation) track — what we'll edit in place.
    let compilationAlbum: String
    let compilationTrackID: String     // Music.app persistent ID
    let artist: String
    let title: String
    let playCount: Int
    let rating: Int                     // 0-100 (AppleScript scale)
    let loved: Bool
    let dateAdded: Date?
    let compilationDuration: TimeInterval
    let compilationURL: URL?            // Apple Music link
    let compilationISRC: String?

    // Matched original track — the album we'll relabel toward.
    var originalAlbum: String?
    var originalAlbumArtist: String?    // Required by the auto-apply gate; nil if album fetch failed.
    var originalCatalogID: String?      // MusicItemID for catalog song
    var originalDuration: TimeInterval?
    var originalURL: URL?               // Apple Music link
    var originalISRC: String?
    var audioQualityAvailable: String?  // e.g. "Hi-Res Lossless", "Lossless", "AAC"
    var qualityWarning: String?         // set if replacement is lower quality

    // Match metadata
    var confidence: MatchConfidence = .none
    var durationDelta: TimeInterval?    // seconds difference
    var action: RowAction = .replace

    /// True when the match passes the auto-apply gate (set during scan).
    /// Drives whether `execute()` applies the relabel without further review.
    var autoApply: Bool = false
    /// Human-readable reason the gate did or didn't pass — written to logs
    /// so the user can audit (and so the needs-review entries explain themselves).
    var gateReason: String?

    // Playlists containing the compilation track (informational; not modified
    // by the new in-place edit flow — the persistent ID is preserved).
    var playlists: [String] = []
}

/// A pair of duplicate tracks.
struct DuplicateMatch: Identifiable {
    let id = UUID()

    let artist: String
    let title: String

    // Track to keep
    let keepTrackID: String
    let keepAlbum: String
    let keepPlayCount: Int
    let keepRating: Int
    let keepLoved: Bool
    let keepDuration: TimeInterval
    let keepURL: URL?
    let keepQuality: String?

    // Track to remove
    let removeTrackID: String
    let removeAlbum: String
    let removePlayCount: Int
    let removeRating: Int
    let removeLoved: Bool
    let removeDuration: TimeInterval
    let removeURL: URL?
    let removeQuality: String?

    // Merged values
    var mergedPlayCount: Int            // sum of both
    var mergedRating: Int               // max of both
    var mergedLoved: Bool               // OR of both

    var confidence: MatchConfidence = .high
    var action: RowAction = .replace
    var playlists: [String] = []        // playlists containing the removed track
    var durationDelta: TimeInterval = 0 // |keep - remove| in seconds
}

/// A live track matched to a studio version.
struct LiveMatch: Identifiable {
    let id = UUID()

    // Source (live) track
    let liveAlbum: String
    let liveTrackID: String
    let artist: String
    let title: String                   // cleaned title (without "Live at..." etc.)
    let rawTitle: String                // original title from library
    let playCount: Int
    let rating: Int
    let loved: Bool
    let liveDuration: TimeInterval
    let liveURL: URL?
    let matchedKeyword: String          // which keyword triggered detection

    // Matched studio track
    var studioAlbum: String?
    var studioCatalogID: String?
    var studioDuration: TimeInterval?
    var studioURL: URL?
    var studioISRC: String?

    var confidence: MatchConfidence = .none
    var durationDelta: TimeInterval?
    var action: RowAction = .replace
    var playlists: [String] = []
}
