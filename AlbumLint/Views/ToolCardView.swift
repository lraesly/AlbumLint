import SwiftUI

struct ToolCardView: View {
    let title: String
    let description: String
    let icon: String
    var scanLabel: String = "Scan"
    let scanAction: () async -> Void
    /// Optional second-step button. Pass nil for tools that scan and apply
    /// in one pass — the button is hidden in that case.
    var executeAction: (() async -> Void)? = nil
    var extraButtonLabel: String? = nil
    var extraButtonAction: (() async -> Void)? = nil
    var canExecute: Bool = false
    var canRunExtra: Bool = false
    let isScanning: Bool
    var isExecuting: Bool = false
    let status: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.accentColor)

            Text(title)
                .font(.headline)

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Spacer()

            if isScanning || isExecuting {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(height: 24)
            }

            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 16)

            VStack(spacing: 8) {
                Button(scanLabel) {
                    Task { await scanAction() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning || isExecuting)

                if let executeAction {
                    Button("Execute") {
                        Task { await executeAction() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canExecute || isScanning || isExecuting)
                }

                if let label = extraButtonLabel, let action = extraButtonAction {
                    Button(label) {
                        Task { await action() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canRunExtra || isScanning || isExecuting)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
}
