import AppKit

/// The store owns update discovery and installation. This app never downloads executable code.
enum AppStoreUpdates {
    static let updatesURL = URL(string: "macappstore://showUpdatesPage")!

    @MainActor
    static func checkForUpdates(
        open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        recover: @MainActor () -> Void = {
            AppDialog.inform(title: "Open the App Store", message: "Open the Mac App Store and choose Updates to check for a newer version of Arras.")
        }
    ) {
        if !open(updatesURL) { recover() }
    }
}
