import Foundation
import SwiftUI

@MainActor
class TrackDeDuperViewModel: ObservableObject {
    @Published var isScanning = false
    @Published var isExecuting = false
    @Published var hasResults = false
    @Published var status = "Ready"

    private let tool = TrackDeDuper()

    private var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AlbumLint")
    }

    func scan() async {
        isScanning = true
        status = "Scanning for duplicates..."

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = outputDirectory.appendingPathComponent("duplicates-\(timestamp).xlsx")

            let matches = try await tool.scan(outputURL: url)
            hasResults = true

            let high = matches.filter { $0.confidence == .high }.count
            status = "Found \(matches.count) duplicate pairs (\(high) high confidence). Saved to \(url.lastPathComponent)"

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
        panel.message = "Select the reviewed duplicates spreadsheet"

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Execution cancelled"
            return
        }

        isExecuting = true
        status = "Executing de-duplication..."

        do {
            let report = try await tool.execute(inputURL: url)
            status = "Done: \(report)"
        } catch {
            status = "Execute failed: \(error.localizedDescription)"
        }

        isExecuting = false
    }
}
