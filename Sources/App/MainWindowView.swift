import SwiftUI

/// Root of the settings window.
///
/// The app outgrew a single scrolling panel: per-photo controls, app-wide
/// switches, update settings and privacy were all competing for the same footer.
/// Tabs keep the photo list — the thing people open this window for — free of
/// everything else.
struct MainWindowView: View {
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?

    @State private var selection: Tab = .photos

    enum Tab: Hashable {
        case photos, preferences, privacy
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                ContentView(manager: manager, onMenuUpdate: onMenuUpdate)
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                    .tag(Tab.photos)

                PreferencesView(manager: manager, onMenuUpdate: onMenuUpdate)
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
