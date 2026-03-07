import Foundation
import SwiftUI

@MainActor
class LiveToStudioViewModel: ObservableObject {
    @Published var isScanning = false
    @Published var isExecuting = false
    @Published var hasResults = false
    @Published var hasExecuted = false
    @Published var status = "Ready"

    private let tool = LiveToStudioReplacer()

    private var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AlbumLint")
    }

    func scan() async {
        isScanning = true
        status = "Scanning for live tracks..."

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = outputDirectory.appendingPathComponent("live-tracks-\(timestamp).xlsx")

            let matches = try await tool.scan(outputURL: url)
            hasResults = true

            let matched = matches.filter { $0.confidence != .none }.count
            status = "Found \(matches.count) live tracks, \(matched) matched. Saved to \(url.lastPathComponent)"

            NSWorkspace.shared.open(url)
        } catch {
            status = "Scan failed: \(error.localizedDescription)"
        }

        isScanning = false
    }

    func execute() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "xlsx")!]
        panel.directoryURL = outputDirectory
        panel.message = "Select the reviewed live tracks spreadsheet"

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Execution cancelled"
            return
        }

        isExecuting = true
        status = "Adding studio versions..."

        do {
            let report = try await tool.execute(inputURL: url)
            hasExecuted = true
            status = "Done: \(report)"
        } catch {
            status = "Execute failed: \(error.localizedDescription)"
        }

        isExecuting = false
    }

    func playlistSwap() async {
        // First scan playlists for proposed swaps
        isScanning = true
        status = "Scanning playlists for live tracks..."

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = outputDirectory.appendingPathComponent("playlist-swaps-\(timestamp).xlsx")

            let swaps = try await tool.playlistSwapScan(outputURL: url)
            status = "Found \(swaps.count) playlist swaps. Review spreadsheet, then run Execute."
            isScanning = false

            NSWorkspace.shared.open(url)

            // Wait for user to review, then prompt for the file
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.init(filenameExtension: "xlsx")!]
            panel.directoryURL = outputDirectory
            panel.message = "Select the reviewed playlist swaps spreadsheet"

            guard panel.runModal() == .OK, let reviewedURL = panel.url else {
                status = "Playlist swap cancelled"
                return
            }

            isExecuting = true
            status = "Executing playlist swaps..."

            let count = try await tool.playlistSwapExecute(inputURL: reviewedURL)
            status = "Playlist swap complete: \(count) tracks swapped"
        } catch {
            status = "Playlist swap failed: \(error.localizedDescription)"
        }

        isScanning = false
        isExecuting = false
    }
}
