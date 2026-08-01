import SwiftUI

/// Human phrasing for "when did we last look".
///
/// `RelativeDateTimeFormatter` alone produced "in 0 seconds" for a check that had just
/// finished: the timestamp is written a hair after `Date()` is sampled, so the formatter reads
/// it as the future and uses future tense. Anything inside a minute is just "just now".
enum UpdateCheckPhrasing {
    static func lastChecked(_ date: Date?) -> String {
        guard let date else { return "Never checked for updates." }
        let elapsed = Date().timeIntervalSince(date)
        guard elapsed >= 60 else { return "Checked just now." }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: date, relativeTo: Date()))."
    }
}

/// The one control that both checks for updates and installs one.
///
/// There used to be a separate card that slid in above the footer when an update was waiting.
/// It was a second place to look, in a different visual language to everything around it. This
/// is the Software Update shape instead: the button you already press to check turns into the
/// button you press to install, in the same spot.
struct UpdateActionButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Group {
            switch updater.phase {
            case .available(let version, _):
                Button("Update to \(version)") {
                    Task { await updater.installPendingUpdate() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            case .downloading(let progress):
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Installing").font(.system(size: 11)).foregroundStyle(.secondary)
                }

            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Checking").font(.system(size: 11)).foregroundStyle(.secondary)
                }

            case .failed:
                Button("Try Again") {
                    Task { await updater.check(userInitiated: true) }
                }
                .controlSize(.small)

            case .idle, .upToDate, .installed:
                Button("Check Now") {
                    Task { await updater.check(userInitiated: true) }
                }
                .controlSize(.small)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updater.phase)
    }
}

/// One line of plain text under the control, saying where things stand.
struct UpdateStatusLine: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        switch updater.phase {
        case .available(let version, _):
            return "Version \(version) is available. You have \(Constants.version)."
        case .installed(let version):
            return "Updated to \(version)."
        case .failed(let reason):
            return reason
        case .upToDate:
            return "\(Constants.appName) is up to date."
        case .idle, .checking, .downloading, .installing:
            return UpdateCheckPhrasing.lastChecked(updater.lastChecked)
        }
    }
}

/// The compact version label and update control in the settings footer.
struct UpdateStatusView: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("v\(Constants.version)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.quaternary)
                .help(UpdateCheckPhrasing.lastChecked(updater.lastChecked))

            switch updater.phase {
            case .available(let version, _):
                Button("Update to \(version)") {
                    Task { await updater.installPendingUpdate() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            case .checking:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)

            case .upToDate:
                Text("up to date")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)

            case .downloading(let progress):
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

            case .installing:
                Text("installing")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)

            case .idle, .installed, .failed:
                // The cadence setting lives in Preferences; burying a picker in a footer menu
                // made a one-click action into a two-level decision for no benefit.
                Button("Check for Updates") {
                    Task { await updater.check(userInitiated: true) }
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Color.accentColor)
                .help(UpdateCheckPhrasing.lastChecked(updater.lastChecked))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updater.phase)
    }
}
