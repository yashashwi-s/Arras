import Foundation

struct Constants {
    static let appName = "Arras"

    /// Keep the SwiftUI root, its tab content, and the AppKit window constraint aligned so the
    /// window cannot be resized below the layout's actual minimum.
    static let settingsMinimumWidth: CGFloat = 460
    static let settingsMinimumHeight: CGFloat = 480

    /// The bundle identifier deliberately still says "tableau". It is what the updater
    /// checks a downloaded build against, and what every UserDefaults key is scoped to —
    /// changing it on a rename would reject the next update and silently reset everyone's
    /// settings. Same reasoning keeps the Application Support directory named PhotoWidget.

    /// Marketing version from the bundle. Read rather than hardcoded so the UI
    /// can never drift from what was actually built.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
