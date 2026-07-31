import SwiftUI

/// Privacy and presence settings.
///
/// These get their own tab rather than a row in Preferences because each one
/// needs a sentence of explanation. Two of the three are best-effort, and a
/// privacy control that overstates what it does is worse than no control at all
/// — so the limits are on screen, not buried in a tooltip.
struct PrivacyView: View {
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                screenSharing
                fullscreen
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    // MARK: - Screen sharing

    private var screenSharing: some View {
        section("SCREEN SHARING & RECORDING") {
            setting(
                title: "Hide photos from screen sharing and recordings",
                detail: "Photos stay visible to you but are left out of screen shares, recordings and screenshots.",
                caveat: "Does not cover AirPlay or HDMI mirroring, which copy the whole display.",
                isReliable: true,
                isOn: Binding(
                    get: { manager.excludeFromScreenCapture },
                    set: { manager.setExcludeFromScreenCapture($0); onMenuUpdate?() }
                )
            )

            setting(
                title: "Also hide them completely during calls",
                detail: "Hides every photo while Zoom, Teams, QuickTime, OBS or Screenshot is running.",
                caveat: "Best effort. A running app is not proof of an active share, and calls in a browser — Google Meet, for instance — cannot be detected at all.",
                isReliable: false,
                isOn: Binding(
                    get: { manager.autoHideForConferencingApps },
                    set: { manager.setAutoHideForConferencingApps($0); onMenuUpdate?() }
                )
            )

            if manager.isConferencingAppDetected {
                Label("A call or recording app is running now", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Fullscreen

    private var fullscreen: some View {
        section("FULLSCREEN APPS") {
            setting(
                title: "Hide photos behind fullscreen apps",
                detail: "Photos are invisible behind a fullscreen app anyway. Tearing them down frees memory and stops rotation timers.",
                caveat: nil,
                isReliable: true,
                isOn: Binding(
                    get: { manager.hideWhenFullscreenActive },
                    set: { manager.setHideWhenFullscreenActive($0); onMenuUpdate?() }
                )
            )
        }
    }

    // MARK: - Building blocks

    /// One toggle with its explanation, and — where it matters — the limits of
    /// what it can promise.
    private func setting(
        title: String,
        detail: String,
        caveat: String?,
        isReliable: Bool,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)

            if let caveat {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: isReliable ? "info.circle" : "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(isReliable ? Color.secondary : Color.orange)
                    Text(caveat)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 18)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            content()
        }
    }
}
