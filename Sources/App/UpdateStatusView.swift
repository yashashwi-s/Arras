import SwiftUI

private struct FooterStarLink: View {
    var body: some View {
        Link(destination: Constants.repositoryURL) {
            Label("Star", systemImage: "star")
        }
        .font(.system(size: 10)).buttonStyle(.borderless).controlSize(.small)
        .accessibilityLabel("Star on GitHub")
        .accessibilityIdentifier("footer-star-on-github")
        .help("Star Arras on GitHub")
    }
}

#if ARRAS_APP_STORE
private struct SupporterThanks: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var gold: Color {
        colorScheme == .dark ? Color(red: 0.94, green: 0.79, blue: 0.48)
            : Color(red: 0.49, green: 0.32, blue: 0.08)
    }

    var body: some View {
        Label("Made possible by you", systemImage: "heart.fill")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(gold)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(gold.opacity(0.08), in: Capsule())
            .overlay { Capsule().strokeBorder(gold.opacity(contrast == .increased ? 0.7 : 0.25), lineWidth: 1) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Thank you for supporting Arras. Your purchase helps me keep building it. Yashashwi, Arras developer.")
            .accessibilityIdentifier("footer-supporter-thanks")
            .help("Thank you for supporting Arras. Your purchase helps me keep building it and sharing the free, open-source edition. Yashashwi")
    }
}

/// Library footer. Software updates belong in Preferences and the Mac App Store.
struct UpdateStatusView: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("v\(Constants.version)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.quaternary)
            SupporterThanks()
            FooterStarLink()
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

/// Stable footer actions; checking/installing still uses the shared verified updater.
struct UpdateStatusView: View {
    @ObservedObject private var updater = Updater.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text("v\(Constants.version)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.quaternary)
                .help(UpdateCheckPhrasing.lastChecked(updater.lastChecked))

            if updater.updatesAllowed {
                switch updater.phase {
                case .available(let version, _):
                    Button("Update") {
                        Task { await updater.installPendingUpdate() }
                    }
                    .font(.system(size: 10)).buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityLabel("Update to \(version)")
                    .accessibilityIdentifier("footer-check-for-updates")
                    .help("Install Arras \(version)")

                case .checking:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)

                case .downloading(let progress):
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                case .installing:
                    Text("installing")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                case .idle, .upToDate, .installed, .failed:
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
            } else {
                Label("Update", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .accessibilityLabel("Updates paused for this test build")
                    .accessibilityIdentifier("footer-update-paused")
                    .help("Updates are paused for this test build")
            }
            FooterStarLink()
            Link(destination: Constants.supportPurchaseURL) {
                Label("Support", systemImage: "heart")
            }
            .font(.system(size: 10)).buttonStyle(.borderless).controlSize(.small)
            .accessibilityLabel("Support Arras on the App Store")
            .accessibilityIdentifier("footer-support-arras")
            .help("Buying Arras Widgets supports development. Every feature stays available in the free edition.")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: updater.phase)
    }
}

#endif
