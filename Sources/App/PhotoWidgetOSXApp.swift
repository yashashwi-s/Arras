import SwiftUI

@main
struct PhotoWidgetOSXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // AppDelegate owns the one real settings window. Mirroring MainWindowView here
        // creates a second window that misses the wordmark and can live on another Space.
        // The scene only satisfies App; every user-facing Settings command targets the
        // AppDelegate window.
        Settings {
            EmptyView()
        }
    }
}
