import AppKit

/// Keeps Arras a menu bar agent and gives it a main menu anyway.
///
/// There was briefly a setting that flipped the activation policy to `.regular`, putting
/// Arras in the Dock and in ⌘Tab. It was removed: a desktop ornament that also occupies a
/// Dock slot and an app-switcher card is asking for attention it never needs, and the app has
/// exactly one window worth returning to, reachable from the status item in a click.
///
/// The main menu stays. An agent's menu bar is only ever shown while the app is frontmost —
/// which now only happens when its Settings window is open — so it costs nothing, and without
/// it there is no ⌘Q, no ⌘W, and no ⌘C/⌘V in the settings text fields, because those are all
/// driven by menu key equivalents.
@MainActor
final class AppActivation {
    static let shared = AppActivation()

    private init() {}

    /// Installs the menu bar. Safe to call more than once.
    func apply() {
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = Self.buildMainMenu()
        }
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
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
