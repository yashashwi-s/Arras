import AppKit

/// Controls whether Tableau behaves as a background agent or as an ordinary app.
///
/// macOS ties Dock presence and ⌘Tab presence to the same switch: `.regular`
/// gives both, `.accessory` gives neither. There is no policy that appears in the
/// app switcher while staying out of the Dock, so this is necessarily one
/// setting rather than two.
@MainActor
final class AppActivation: ObservableObject {
    static let shared = AppActivation()

    private let key = "showInDock"

    private init() {}

    /// When true the app takes a Dock slot and appears in ⌘Tab.
    ///
    /// Defaults to true: once an app has a settings window worth returning to,
    /// being unreachable from the app switcher is more surprising than the Dock
    /// icon is intrusive.
    var showsInDock: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: key)
            apply()
        }
    }

    /// Applies the stored preference. Safe to call at launch and on change.
    func apply() {
        let wantsRegular = showsInDock
        let current = NSApp.activationPolicy()
        let target: NSApplication.ActivationPolicy = wantsRegular ? .regular : .accessory

        // Installing the main menu before switching means the menu bar is already
        // correct the moment the app becomes regular, rather than briefly empty.
        NSApp.mainMenu = wantsRegular ? Self.buildMainMenu() : nil

        guard current != target else { return }
        NSApp.setActivationPolicy(target)

        // Going accessory -> regular leaves the menu bar stale until the app
        // loses and regains focus; re-activating on the next turn of the run loop
        // forces AppKit to adopt the new menu immediately.
        if wantsRegular {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - Main menu

    /// A minimal but complete menu bar.
    ///
    /// An agent app has no main menu at all. Becoming `.regular` without one
    /// leaves a menu bar containing nothing but the Apple menu, which reads as a
    /// broken app — and, more practically, text fields in Settings lose ⌘C/⌘V,
    /// because those are driven by the Edit menu's key equivalents.
    private static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem(assigningTo: NSApp))

        return mainMenu
    }

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: Constants.appName)

        menu.addItem(
            withTitle: "About \(Constants.appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        // Targets the AppDelegate rather than the responder chain, so it works
        // even when no window is open.
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.showSettingsFromMenu),
            keyEquivalent: ","
        )
        settings.target = NSApp.delegate
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide \(Constants.appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )

        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)

        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(Constants.appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    private static func windowMenuItem(assigningTo app: NSApplication) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        item.submenu = menu
        // Lets AppKit keep the window list in this menu up to date for us.
        app.windowsMenu = menu
        return item
    }
}
