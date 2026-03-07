import Foundation
import SwiftUI

@MainActor
class CompilationReplacerViewModel: ObservableObject {
    @Published var isScanning = false
    @Published var isExecuting = false
    @Published var hasResults = false
    @Published var status = "Ready"

    private let tool = CompilationReplacer()
    private var lastOutputURL: URL?

    private var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AlbumLint")
    }

    func scan() async {
        isScanning = true
        status = "Scanning compilation tracks..."

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = outputDirectory.appendingPathComponent("compilations-\(timestamp).xlsx")

            let matches = try await tool.scan(outputURL: url)
            lastOutputURL = url
            hasResults = true

            let matched = matches.filter { $0.confidence != .none }.count
            status = "Found \(matches.count) tracks, \(matched) matched. Saved to \(url.lastPathComponent)"

            // Open in default app (Excel/Numbers)
            NSWorkspace.shared.open(url)
        } catch {
            status = "Scan failed: \(error.localizedDescription)"
        }

        isScanning = false
    }

    func execute() async {
        // Let user pick the reviewed spreadsheet
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "xlsx")!]
        panel.directoryURL = outputDirectory
        panel.message = "Select the reviewed compilation spreadsheet"

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Execution cancelled"
            return
        }

        isExecuting = true
        status = "Executing replacements..."

        do {
            let report = try await tool.execute(inputURL: url)
            status = "Done: \(report)"
        } catch {
            status = "Execute failed: \(error.localizedDescription)"
        }

        isExecuting = false
    }
}
