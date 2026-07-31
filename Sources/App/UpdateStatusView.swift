import SwiftUI

/// Prominent card shown above the footer when the updater needs the user's
/// attention — an update is ready, downloading, or something failed.
///
/// Separate from the footer's compact control because these states are
/// actionable: an available update rendered as 9pt grey text beside the version
/// number reads as decoration and gets ignored.
struct UpdateBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Group {
            switch updater.phase {
            case .available(let version, let notes):
                // Naming both versions matters. The previous design put the *available*
                // version in the footer's version slot, so the one place that tells you
                // which build you are running read "v2.2.0" while you were on 2.1.0.
                banner(
                    icon: "arrow.down.circle.fill",
                    tint: Color.accentColor,
                    title: "Update available — \(Constants.version) → \(version)",
                    detail: notes
                ) {
                    Button("Update Now") {
                        Task { await updater.installPendingUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

            case .downloading(let progress):
                banner(
                    icon: "arrow.down.circle.fill",
                    tint: Color.accentColor,
                    title: "Downloading update…",
                    detail: nil
                ) {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 90)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

            case .installing:
                banner(
                    icon: "shippingbox.fill",
                    tint: Color.accentColor,
                    title: "Installing…",
                    detail: "\(Constants.appName) will relaunch in a moment."
                ) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }

            case .installed(let version):
                banner(
                    icon: "checkmark.circle.fill",
                    tint: .green,
                    title: "Updated to version \(version)",
                    detail: "You're running the latest release."
                ) {
                    EmptyView()
                }

            case .failed(let reason):
                banner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "Update failed",
                    detail: reason
                ) {
                    Button("Try Again") {
                        Task { await updater.check(userInitiated: true) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

            case .idle, .checking, .upToDate:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: updater.phase)
    }

    // MARK: - Card

    private func banner<Trailing: View>(
        icon: String,
        tint: Color,
        title: String,
        detail: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tint.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// The compact version label and check control that live in the settings footer.
///
/// Deliberately quiet: anything the user needs to act on is promoted to
/// `UpdateBanner` rather than competing for space down here.
struct UpdateStatusView: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 6) {
            Text("v\(Constants.version)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.quaternary)
                .help(lastCheckedDescription)

            switch updater.phase {
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

            case .idle:
                Button("Check for Updates") {
                    Task { await updater.check(userInitiated: true) }
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Color.accentColor)

            // Everything actionable is already showing in the banner.
            case .available, .downloading, .installing, .installed, .failed:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updater.phase)
    }

    private var lastCheckedDescription: String {
        guard let date = updater.lastChecked else { return "Never checked for updates" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}
