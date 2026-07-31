#if !MAS

import SwiftUI

/// The version label and update control that sit at the bottom of Settings.
///
/// Lives in its own file so the App Store target, which has no updater at all,
/// simply drops it rather than threading `#if` through the settings layout.
struct UpdateStatusView: View {
    @ObservedObject private var updater = Updater.shared
    @State private var showingNotes = false

    var body: some View {
        HStack(spacing: 6) {
            statusText
            actionControl
        }
        .animation(.easeInOut(duration: 0.2), value: updater.phase)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusText: some View {
        switch updater.phase {
        case .idle:
            versionLabel

        case .checking:
            Text("Checking…")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)

        case .upToDate:
            Text("v\(Constants.version) — up to date")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)

        case .available(let version, _):
            Text("v\(version) available")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accentColor)

        case .downloading(let progress):
            HStack(spacing: 5) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

        case .installing:
            Text("Installing…")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)

        case .failed(let reason):
            Text(reason)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(reason)
        }
    }

    private var versionLabel: some View {
        Text("v\(Constants.version)")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.quaternary)
            .help(lastCheckedDescription)
    }

    private var lastCheckedDescription: String {
        guard let date = updater.lastChecked else { return "Never checked for updates" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    // MARK: - Action

    @ViewBuilder
    private var actionControl: some View {
        switch updater.phase {
        case .downloading, .installing:
            EmptyView()

        case .available(let version, let notes):
            Button("Update to \(version)") {
                Task { await updater.installPendingUpdate() }
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(notes ?? "Download and install this update, then relaunch")

        default:
            Button("Check for Updates") {
                Task { await updater.check(userInitiated: true) }
            }
            .font(.system(size: 10))
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(Color.accentColor)
        }
    }
}

#endif
