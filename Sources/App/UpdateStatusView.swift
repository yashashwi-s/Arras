import SwiftUI

/// The existing Store link style is shared by both editions.
private struct FooterStarLink: View {
    var body: some View {
        Link(destination: Constants.repositoryURL) {
            Label("Star", systemImage: "star")
        }
        .font(.system(size: 10)).buttonStyle(.borderless).controlSize(.small)
        .accessibilityIdentifier("footer-star-on-github")
        .accessibilityHint("Opens the Arras repository in your browser")
    }
}

#if ARRAS_APP_STORE

/// Library footer. Software updates belong in Preferences and the Mac App Store.
struct UpdateStatusView: View {
    var body: some View {
        HStack(spacing: 8) {
            FooterStarLink()
            Label {
                Text("Supported").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "heart.fill").foregroundStyle(.red)
            }
            .font(.system(size: 10))
            .accessibilityIdentifier("footer-supported")
            .help("Thank you for supporting Arras.")
        }
    }
}
#else

/// Human phrasing for "when did we last look".
///
/// `RelativeDateTimeFormatter` alone produced "in 0 seconds" for a check that had just
/// finished: the timestamp is written a hair after `Date()` is sampled, so the formatter reads
/// it as the future and uses future tense. Anything inside a minute is just "just now".
enum UpdateCheckPhrasing {
    static func lastChecked(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never checked for updates." }
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 60 else { return "Checked just now." }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: date, relativeTo: now))."
    }
}

/// Readable, testable wording for an available update. Keep the release statement in the same
/// status line as the version so Settings exposes useful context to VoiceOver as one value.
enum UpdateStatusPhrasing {
    static func availableUpdate(version: String, notes: String?, currentVersion: String) -> String {
        let prefix = "Version \(version) is available. You have \(currentVersion)."
        guard let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else {
            return prefix
        }
        return "\(prefix) \(notes)"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: updater.phase)
    }
}

/// One line of plain text under the control, saying where things stand.
struct UpdateStatusLine: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let text = text(at: timeline.date)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(text)
        }
    }

    private func text(at now: Date) -> String {
        switch updater.phase {
        case .available(let version, let notes):
            return UpdateStatusPhrasing.availableUpdate(
                version: version,
                notes: notes,
                currentVersion: Constants.version
            )
        case .installed(let version):
            return "Updated to \(version)."
        case .failed(let reason):
            return reason
        case .upToDate:
            return "\(Constants.appName) is up to date."
        case .checking:
            return "Checking for updates…"
        case .downloading(let progress):
            return "Downloading update (\(Int(progress * 100))%)…"
        case .installing:
            return "Verifying and installing update…"
        case .idle:
            return UpdateCheckPhrasing.lastChecked(updater.lastChecked, now: now)
        }
    }
}

/// Compact footer actions. Version information remains in Preferences.
struct UpdateStatusView: View {
    @ObservedObject var updater: Updater = Updater.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if updater.updatesAllowed {
                switch updater.phase {
                case .available(let version, _):
                    Button("Update to \(version)") {
                        Task { await updater.installPendingUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                case .checking:
                    HStack(spacing: 5) {
                        ProgressView().progressViewStyle(.circular).controlSize(.mini)
                            .frame(width: 12, height: 12)
                        Text("Checking…").font(.system(size: 10))
                    }
                    .foregroundStyle(Color.accentColor)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Checking for updates")
                    .accessibilityIdentifier("footer-update-status")

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
                    Button {
                        Task { await updater.check(userInitiated: true) }
                    } label: {
                        Label("Update", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Check for Updates")
                    .accessibilityIdentifier("footer-check-for-updates")
                    .help(UpdateCheckPhrasing.lastChecked(updater.lastChecked))
                }
            }
            FooterStarLink()
            Link(destination: Constants.supportPurchaseURL) {
                Label("Support", systemImage: "heart")
            }
            .font(.system(size: 10)).buttonStyle(.borderless).controlSize(.small)
            .accessibilityIdentifier("footer-support-arras")
            .accessibilityHint("Opens the optional App Store purchase to support development. All free features remain available.")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: updater.phase)
    }
}

#endif
