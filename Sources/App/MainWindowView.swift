import SwiftUI

/// The Settings window keeps its selected tab when reused. Explicit update
/// actions can reveal Preferences without rebuilding the window or its views.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: MainWindowView.Tab = .photos
    @Published var updatesRequest: UUID?

    func showUpdates() {
        selection = .preferences
        updatesRequest = UUID()
    }
}

/// Root of the settings window.
///
/// The app outgrew a single scrolling panel: per-photo controls, app-wide
/// switches, update settings and privacy were all competing for the same footer.
/// Tabs keep the photo list — the thing people open this window for — free of
/// everything else.
struct MainWindowView: View {
    @ObservedObject var manager: PhotoManager
    @ObservedObject var navigation: SettingsNavigation
    var onMenuUpdate: (() -> Void)?

    enum Tab: Hashable {
        case photos, preferences, privacy
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $navigation.selection) {
                ContentView(manager: manager, onMenuUpdate: onMenuUpdate)
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                    .tag(Tab.photos)

                PreferencesView(manager: manager, navigation: navigation, onMenuUpdate: onMenuUpdate)
                    .tabItem { Label("Preferences", systemImage: "gearshape") }
                    .tag(Tab.preferences)

                PrivacyView(manager: manager, onMenuUpdate: onMenuUpdate)
                    .tabItem { Label("Privacy", systemImage: "hand.raised") }
                    .tag(Tab.privacy)
            }
        }
        .frame(minWidth: Constants.settingsMinimumWidth, minHeight: Constants.settingsMinimumHeight)
    }
}

// MARK: - Settings sections

/// System control backgrounds can match the window in dark mode. Give every
/// Settings section a visible surface without adding blur or animated effects.
private struct SettingsSectionSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.015))
                    }
            }
            .overlay {
                shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.3 : 0.1), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func settingsSectionSurface() -> some View {
        modifier(SettingsSectionSurface())
    }
}
