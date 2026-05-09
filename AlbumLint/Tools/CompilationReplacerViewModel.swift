import Foundation
import SwiftUI

@MainActor
class CompilationReplacerViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var status = "Ready"

    private let tool = CompilationReplacer()

    private var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AlbumLint")
    }

    /// Scan, gate, and apply in a single pass. The run log opens in Finder
    /// when complete; every track's outcome (applied / skipped / unmatched /
    /// unresolved / verify_reverted / error) is one line in that log.
    func run() async {
        isRunning = true
        status = "Running..."

        do {
            let report = try await tool.run(outputDirectory: outputDirectory)
            var summary = "\(report)"
            if let playlistName = report.playlistName {
                summary += " · Playlist: \(playlistName)"
            }
            if let logURL = report.logURL {
                summary += " · Log: \(logURL.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([logURL])
            }
            status = summary
        } catch {
            status = "Run failed: \(error.localizedDescription)"
        }

        isRunning = false
    }
}
