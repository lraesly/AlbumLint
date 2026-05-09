import Foundation
import SwiftUI

@MainActor
class CompilationReplacerViewModel: ObservableObject {
    @Published var isScanning = false
    @Published var isExecuting = false
    @Published var hasResults = false
    @Published var status = "Ready"

    private let tool = CompilationReplacer()
    private var lastMatches: [CompilationMatch]?
    private var lastPreviewURL: URL?

    private var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AlbumLint")
    }

    /// Scan the library, decide which compilation tracks can be auto-relabeled,
    /// and write a preview log. The matches are cached in memory so `execute()`
    /// can apply them without re-scanning.
    func scan() async {
        isScanning = true
        status = "Scanning compilation tracks..."

        do {
            let report = try await tool.scan(outputDirectory: outputDirectory)
            lastMatches = report.matches
            lastPreviewURL = report.previewLogURL
            hasResults = report.willApply > 0

            var parts = ["\(report.total) compilation tracks", "\(report.willApply) ready to apply", "\(report.needsReview) need review", "\(report.unmatched) unmatched"]
            if report.unresolved > 0 {
                parts.append("\(report.unresolved) unresolved (no persistent ID)")
            }
            status = parts.joined(separator: " · ") + ". Preview: \(report.previewLogURL.lastPathComponent)"

            NSWorkspace.shared.activateFileViewerSelecting([report.previewLogURL])
        } catch {
            status = "Scan failed: \(error.localizedDescription)"
        }

        isScanning = false
    }

    /// Apply the cached scan results in place. Requires a prior `scan()`.
    func execute() async {
        guard let matches = lastMatches else {
            status = "No scan results — run Scan first"
            return
        }

        isExecuting = true
        status = "Applying replacements..."

        do {
            let report = try await tool.execute(matches: matches, outputDirectory: outputDirectory)
            var summary = "\(report)"
            if let logURL = report.appliedLogURL {
                summary += " · Log: \(logURL.lastPathComponent)"
            }
            status = summary
            // Re-scan would be wasteful; clear cache so a stale apply can't re-fire.
            lastMatches = nil
            hasResults = false
        } catch {
            status = "Execute failed: \(error.localizedDescription)"
        }

        isExecuting = false
    }
}
