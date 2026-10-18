import AppKit

/// One removal flow for Settings and the menu bar. Only Settings may remember consent.
@MainActor
enum RemovalConfirmation {
    enum Origin { case settings, menuBar }
    static let skipSettingsKey = "removal.skipSettingsConfirmation"
    static var preferenceStore: UserDefaults {
        if let path = ProcessInfo.processInfo.environment["ARRAS_UI_TEST_STORAGE_DIR"] {
            return UserDefaults(suiteName: "arras.removal-tests." + URL(fileURLWithPath: path).lastPathComponent)!
        }
        return .standard
    }

    static func requiresConfirmation(origin: Origin, defaults: UserDefaults? = nil) -> Bool {
        origin == .menuBar || !(defaults ?? preferenceStore).bool(forKey: skipSettingsKey)
    }

    static func confirm(count: Int, name: String? = nil, all: Bool = false,
                        origin: Origin, defaults: UserDefaults? = nil) -> Bool {
        let defaults = defaults ?? preferenceStore
        guard count > 0 else { return false }
        guard requiresConfirmation(origin: origin, defaults: defaults) else { return true }
        let subject = count == 1 ? (name ?? "this widget") : all ? "all \(count) widgets" : "these \(count) widgets"
        let alert = AppDialog.make(
            title: all ? "Remove All Widgets?" : count == 1 ? "Remove Widget?" : "Remove \(count) Widgets?",
            message: "Remove \(subject) from this desktop? Original files and your Photos library are not affected. You can restore this removal until you remove something else, including after reopening Arras.",
            style: .warning,
            actions: [.init(title: all ? "Remove All" : "Remove", role: .destructive), .init(title: "Cancel", role: .cancel)]
        )
        if origin == .settings {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t ask again in Settings"
        }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if origin == .settings, alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: skipSettingsKey)
        }
        return true
    }
}
