import SwiftUI

/// App-wide visibility protections, permission recovery and data disclosure.
struct PrivacyView: View {
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Control what others can see").font(.title3.weight(.semibold))
                    caption("Choose when widgets stay visible and how Arras uses permissions and data.")
                }
                screenSharing
                fullscreen
                systemPermissions
                usageStatistics
                HStack(spacing: 16) {
                    Link("Security & Privacy", destination: URL(string: "https://tryarras.tech/security")!)
                    Link("Contact & Support", destination: URL(string: "mailto:yashashwi.singhania.bce23@itbhu.ac.in")!)
                        .help("Email yashashwi.singhania.bce23@itbhu.ac.in")
                        .accessibilityHint("Opens your email app to contact support")
                }
                .font(.system(size: 11))
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    // MARK: - Screen sharing

    private var screenSharing: some View {
        section("Screen sharing & recording", icon: "rectangle.on.rectangle.slash") {
            setting(
                title: "Request exclusion from screen captures",
                detail: "Asks compatible screenshot and recording tools to omit visible widgets.",
                caveat: "Modern screen recorders may still capture widgets. Hide widgets before sharing if they must stay private. AirPlay and HDMI mirroring are not covered.",
                warning: true,
                isOn: Binding(
                    get: { manager.excludeFromScreenCapture },
                    set: { manager.setExcludeFromScreenCapture($0); onMenuUpdate?() }
                )
            )

            Divider().padding(.vertical, 2)
            setting(
                title: "Hide widgets while call or recording apps run",
                detail: "Removes widgets from your desktop while Zoom, Teams, QuickTime, OBS or Screenshot is running.",
                caveat: "Best effort. A running app is not proof of an active share. Browser calls, such as Google Meet, cannot be detected.",
                warning: true,
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
        section("Fullscreen behavior", icon: "arrow.up.left.and.arrow.down.right") {
            setting(
                title: "Hide widgets behind fullscreen apps",
                detail: "Pauses hidden photo widgets while a fullscreen app covers them, reducing memory and background activity.",
                caveat: "Detection uses window size. Some fullscreen apps or desktop arrangements may not be recognized.",
                warning: false,
                isOn: Binding(
                    get: { manager.hideWhenFullscreenActive },
                    set: { manager.setHideWhenFullscreenActive($0); onMenuUpdate?() }
                )
            )
        }
    }

    // MARK: - Building blocks

    private var systemPermissions: some View {
        section("macOS permissions", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Photos").font(.subheadline.weight(.medium))
                caption("Allows album sync and importing from your Photos library. Arras asks when you choose a Photos feature.")
                Button("Photos Settings…") { PrivacySettingsPane.photos.open() }
            }
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Capture a screen region").font(.subheadline.weight(.medium))
                caption("Pins a one-time screenshot of an area you select. macOS calls this permission Screen Recording; Arras does not continuously record your screen. Enable Capture Screen Region in Preferences → Menu bar, then choose it from Add. Ordinary photos and hiding widgets from capture do not need this permission.")
                Button("Screen Recording Settings…") { PrivacySettingsPane.screenRecording.open() }
            }
            caption("Opens System Settings → Privacy & Security. After changing access, return to Arras and try the feature again.")
        }
    }

    private var usageStatisticsDescription: String {
        #if ARRAS_APP_STORE
        return "This App Store build does not collect or send usage statistics. Photos, filenames, paths, captions and personal content stay local."
        #else
        let localContent = " Photos, filenames, paths, captions and personal content stay local."
        guard let configuration = TelemetryConfiguration.current else {
            return "Usage statistics are disabled in this build." + localContent
        }
        if configuration.dryRun {
            return "This development build inspects usage statistics locally without uploading them." + localContent
        }
        if configuration.environment == .development {
            return "This development build sends test statistics to a local test server." + localContent
        }
        let cadence = configuration.cadence == .weekly ? "weekly" : "daily"
        return "This build sends limited usage and \(cadence) configuration statistics linked by a random installation ID to improve Arras." + localContent
        #endif
    }

    private var usageStatistics: some View {
        section("Usage statistics", icon: "chart.bar") {
            Text(usageStatisticsDescription)
                .accessibilityIdentifier("privacy-usage-statistics")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if !ARRAS_APP_STORE
            Link("What is collected and how long it is kept →", destination: URL(string: "https://tryarras.tech/security")!)
                .font(.caption)
            #endif
            caption("Preferences can read the public GitHub star count. This request contains no photo library or installation ID.")
        }
    }

    /// One toggle with its explanation, and — where it matters — the limits of
    /// what it can promise.
    private func setting(
        title: String,
        detail: String,
        caveat: String?,
        warning: Bool,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)

            if let caveat {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: warning ? "exclamationmark.triangle" : "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(warning ? Color.orange : Color.secondary)
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 18)
            }
        }
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsSectionSurface()
        .font(.system(size: 12))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
