import Foundation

struct Constants {
    static let appName = "Tableau"

    /// Marketing version from the bundle. Read rather than hardcoded so the UI
    /// can never drift from what was actually built.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
