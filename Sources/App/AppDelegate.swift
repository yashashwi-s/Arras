import AppKit
import SwiftUI

/// AppDelegate manages the menu bar status item and the settings window.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    let manager = PhotoManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        // Asks for notification permission, then polls the appcast on launch and
        // every few hours so updates and announcements reach existing users.
        UpdateChecker.shared.start()

        // If first launch (no photos yet), show settings
        if manager.photos.isEmpty {
            showSettingsWindow()
        }
    }

    /// When user re-opens the app (clicks .app again while running), show UI
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusItem()
        showSettingsWindow()
        return false
    }

    // MARK: - Status Item (Menu Bar Icon)

    func setupStatusItem() {
        guard UserDefaults.standard.object(forKey: "hideMenuBarIcon") == nil ||
              !UserDefaults.standard.bool(forKey: "hideMenuBarIcon") else {
            return  // User chose to hide it
        }
        showStatusItem()
    }

    func showStatusItem() {
        if statusItem != nil { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.autosaveName = "TableauStatusItem"
        statusItem?.button?.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: Constants.appName)
        statusItem?.button?.toolTip = Constants.appName
        statusItem?.button?.image?.size = NSSize(width: 18, height: 18)

        UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")

        // Create the menu with a delegate so it rebuilds every time it opens
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        rebuildMenu()
    }

    func hideStatusItem() {
        statusItem?.statusBar?.removeStatusItem(statusItem!)
        statusItem = nil
        UserDefaults.standard.set(true, forKey: "hideMenuBarIcon")
    }

    // MARK: - NSMenuDelegate — rebuild menu every time the user clicks the icon

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in
            self.rebuildMenu()
        }
    }

    // MARK: - Build Menu

    func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        // Add Photo
        let addItem = NSMenuItem(title: "Add Photo…", action: #selector(addPhoto), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        // Add Space
        let addSpaceItem = NSMenuItem(title: "Add Space…", action: #selector(addSpace), keyEquivalent: "")
        addSpaceItem.target = self
        menu.addItem(addSpaceItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if !manager.photos.isEmpty {
            menu.addItem(.separator())

            for (index, item) in manager.photos.enumerated() {
                let submenu = NSMenu()

                // Float toggle
                let floatItem = NSMenuItem(
                    title: item.isFloating ? "Pin to Desktop" : "Float Above Windows",
                    action: #selector(toggleFloating(_:)),
                    keyEquivalent: ""
                )
                floatItem.target = self
                floatItem.tag = index
                submenu.addItem(floatItem)

                // Click-through toggle
                if item.isFloating {
                }

                submenu.addItem(.separator())

                // Visibility
                let visItem = NSMenuItem(
                    title: item.isVisible ? "Hide" : "Show",
                    action: #selector(togglePhotoVisibility(_:)),
                    keyEquivalent: ""
                )
                visItem.target = self
                visItem.tag = index
                submenu.addItem(visItem)

                // Lock
                let lockItem = NSMenuItem(
                    title: item.isLocked ? "Unlock Position" : "Lock Position",
                    action: #selector(togglePhotoLock(_:)),
                    keyEquivalent: ""
                )
                lockItem.target = self
                lockItem.tag = index
                submenu.addItem(lockItem)

                submenu.addItem(.separator())

                // Rename
                let renameItem = NSMenuItem(title: "Rename…", action: #selector(renamePhoto(_:)), keyEquivalent: "")
                renameItem.target = self
                renameItem.tag = index
                submenu.addItem(renameItem)

                // Replace (only for single images)
                if item.spaceImageFilenames.isEmpty {
                    let replaceItem = NSMenuItem(title: "Replace Image…", action: #selector(replacePhoto(_:)), keyEquivalent: "")
                    replaceItem.target = self
                    replaceItem.tag = index
                    submenu.addItem(replaceItem)
                }

                // Duplicate
                let dupItem = NSMenuItem(title: "Duplicate", action: #selector(duplicatePhoto(_:)), keyEquivalent: "")
                dupItem.target = self
                dupItem.tag = index
                submenu.addItem(dupItem)

                // Folder navigation
                if !item.spaceImageFilenames.isEmpty {
                    submenu.addItem(.separator())
                    let count = manager.folderImageCount(item.id)
                    let posLabel = NSMenuItem(title: "\(item.folderImageIndex + 1) of \(count) images", action: nil, keyEquivalent: "")
                    posLabel.isEnabled = false
                    submenu.addItem(posLabel)

                    let prevItem = NSMenuItem(title: "← Previous", action: #selector(prevFolderImage(_:)), keyEquivalent: "")
                    prevItem.target = self
                    prevItem.tag = index
                    submenu.addItem(prevItem)

                    let nextItem = NSMenuItem(title: "Next →", action: #selector(nextFolderImage(_:)), keyEquivalent: "")
                    nextItem.target = self
                    nextItem.tag = index
                    submenu.addItem(nextItem)
                    
                    submenu.addItem(.separator())
                    
                    let appendItem = NSMenuItem(title: "Add Photos to Space...", action: #selector(appendPhotosToSpaceMenu(_:)), keyEquivalent: "")
                    appendItem.target = self
                    appendItem.tag = index
                    submenu.addItem(appendItem)
                }

                submenu.addItem(.separator())

                let removeItem = NSMenuItem(title: "Remove", action: #selector(removePhotoMenu(_:)), keyEquivalent: "")
                removeItem.target = self
                removeItem.tag = index
                submenu.addItem(removeItem)

                // Photo menu item with thumbnail
                let photoItem = NSMenuItem()
                photoItem.submenu = submenu

                let title = manager.label(for: item)
                if let thumb = manager.thumbnail(for: item, size: 20) {
                    photoItem.image = thumb
                    photoItem.image?.size = NSSize(width: 20, height: 20)
                }

                // Clean status badges
                var badges: [String] = []
                if !item.isVisible { badges.append("hidden") }
                if item.isLocked { badges.append("locked") }
                if item.isFloating { badges.append("floating") }
                if !item.spaceImageFilenames.isEmpty { badges.append("folder") }

                photoItem.title = badges.isEmpty ? title : "\(title) — \(badges.joined(separator: ", "))"

                menu.addItem(photoItem)
            }

            menu.addItem(.separator())

            let removeAllItem = NSMenuItem(title: "Remove All Photos", action: #selector(removeAllPhotos), keyEquivalent: "")
            removeAllItem.target = self
            menu.addItem(removeAllItem)
        }

        menu.addItem(.separator())

        // Launch at Login
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = manager.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        // Hide Menu Bar Icon
        let hideItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideMenuBarIcon), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit \(Constants.appName)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Updates

    @objc func checkForUpdates() {
        Task { await UpdateChecker.shared.check(userInitiated: true) }
    }

    // MARK: - Settings Window

    @objc func showSettingsFromMenu() {
        showSettingsWindow()
    }

    func showSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = ContentView(manager: manager, onMenuUpdate: { [weak self] in
            self?.rebuildMenu()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Constants.appName
        window.center()
        window.minSize = NSSize(width: 420, height: 400)
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    // MARK: - Menu Actions

    @objc func addPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let img = NSImage(contentsOf: url) {
                    manager.addPhoto(img)
                }
            }
            rebuildMenu()
        }
    }

    @objc func addSpace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add Images to Space"
        panel.message = "Choose multiple images to display as a rotating Space"

        if panel.runModal() == .OK {
            let images = panel.urls.compactMap { NSImage(contentsOf: $0) }
            manager.addSpace(images: images)
        }
    }

    @objc func togglePhotoVisibility(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        manager.toggleVisibility(manager.photos[index].id)
    }

    @objc func togglePhotoLock(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        manager.toggleLock(manager.photos[index].id)
    }

    @objc func toggleFloating(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        let current = manager.photos[index].isFloating
        manager.setFloating(manager.photos[index].id, !current)
    }

    @objc func renamePhoto(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        let item = manager.photos[index]

        let alert = NSAlert()
        alert.messageText = "Rename Photo"
        alert.informativeText = "Enter a new name for this widget."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = manager.label(for: item)
        textField.isEditable = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        alert.accessoryView = textField

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            manager.renamePhoto(item.id, to: textField.stringValue)
        }
    }

    @objc func replacePhoto(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.prompt = "Replace"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            manager.replacePhoto(manager.photos[index].id, with: img)
        }
    }

    @objc func duplicatePhoto(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        manager.duplicatePhoto(manager.photos[index].id)
    }

    @objc func nextFolderImage(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        manager.nextFolderImage(manager.photos[index].id)
    }

    @objc func prevFolderImage(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        manager.prevFolderImage(manager.photos[index].id)
    }

    @objc func appendPhotosToSpaceMenu(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        let id = manager.photos[index].id
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add to Space"
        panel.message = "Choose multiple images to append to this rotating space"

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            let images = panel.urls.compactMap { NSImage(contentsOf: $0) }
            manager.appendPhotosToSpace(id, images: images)
        }
    }

    @objc func removePhotoMenu(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        manager.removePhoto(manager.photos[index].id)
    }

    @objc func removeAllPhotos() {
        manager.removeAllPhotos()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = sender.state == .off
        manager.setLaunchAtLogin(newState)
    }

    @objc func hideMenuBarIcon() {
        hideStatusItem()
        let alert = NSAlert()
        alert.messageText = "Menu Bar Icon Hidden"
        alert.informativeText = "To bring it back, just open \(Constants.appName) again from your Applications folder or Spotlight."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
