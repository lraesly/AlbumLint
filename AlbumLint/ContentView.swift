import SwiftUI
import MusicKit

struct ContentView: View {
    @State private var musicAuthStatus: MusicAuthorization.Status = .notDetermined
    @StateObject private var compilationTool = CompilationReplacerViewModel()
    @StateObject private var deDuperTool = TrackDeDuperViewModel()
    @StateObject private var liveTool = LiveToStudioViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if musicAuthStatus == .authorized {
                toolGrid
            } else {
                authorizationView
            }
        }
        .frame(width: 720, height: 480)
        .task {
            musicAuthStatus = MusicAuthorization.currentStatus
            if musicAuthStatus == .notDetermined {
                musicAuthStatus = await MusicAuthorization.request()
            }
        }
    }

    private var authorizationView: some View {
        VStack(spacing: 16) {
            Text("AlbumLint")
                .font(.largeTitle.bold())
            Text("Apple Music library access is required.")
                .foregroundStyle(.secondary)
            Button("Request Access") {
                Task {
                    musicAuthStatus = await MusicAuthorization.request()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolGrid: some View {
        VStack(spacing: 20) {
            Text("AlbumLint")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            HStack(spacing: 20) {
                ToolCardView(
                    title: "Compilation Replacer",
                    description: "Replace compilation tracks with original album versions",
                    icon: "opticaldisc",
                    scanAction: { await compilationTool.scan() },
                    executeAction: { await compilationTool.execute() },
                    canExecute: compilationTool.hasResults,
                    isScanning: compilationTool.isScanning,
                    isExecuting: compilationTool.isExecuting,
                    status: compilationTool.status
                )

                ToolCardView(
                    title: "Track De-Duper",
                    description: "Find and merge duplicate tracks in your library",
                    icon: "doc.on.doc",
                    scanAction: { await deDuperTool.scan() },
                    executeAction: { await deDuperTool.execute() },
                    canExecute: deDuperTool.hasResults,
                    isScanning: deDuperTool.isScanning,
                    isExecuting: deDuperTool.isExecuting,
                    status: deDuperTool.status
                )

                ToolCardView(
                    title: "Live \u{2192} Studio",
                    description: "Replace live recordings with studio versions",
                    icon: "music.mic",
                    scanAction: { await liveTool.scan() },
                    executeAction: { await liveTool.execute() },
                    extraButtonLabel: "Playlist Swap",
                    extraButtonAction: { await liveTool.playlistSwap() },
                    canExecute: liveTool.hasResults,
                    canRunExtra: liveTool.hasExecuted,
                    isScanning: liveTool.isScanning,
                    isExecuting: liveTool.isExecuting,
                    status: liveTool.status
                )
            }
            .padding(.horizontal, 20)

            Spacer()
        }
    }
}
