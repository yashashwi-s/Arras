import AppKit
import SwiftUI

/// AppDelegate manages the menu bar status item and the settings window.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    let manager = PhotoManager()

    private var dropView: StatusItemDropView?
    private var pasteMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything shows UI, so the Dock icon and menu bar are correct on
        // the first frame rather than appearing a moment later.
        AppActivation.shared.apply()

        // Before anything else can fail because of it: an app run from a disk image cannot
        // replace itself, and discovering that at update time is a dead end.
        InstallLocation.offerToInstallIfNeeded()

        setupStatusItem()
        setupGlobalHotKey()
        setupPasteMonitor()

        // Asks for notification permission, then polls the appcast on launch and
        // weekly, so updates and announcements reach existing users.
        Updater.shared.start()

        // Show settings after an update landed, so the new version is visible rather
        // than the app appearing to have closed and reopened for no reason.
        if let installed = UserDefaults.standard.string(forKey: Updater.justUpdatedKey) {
            UserDefaults.standard.removeObject(forKey: Updater.justUpdatedKey)
            showSettingsWindow()
            Updater.shared.announceInstalled(version: installed)
        } else if manager.photos.isEmpty {
            // First launch — there is nothing on the desktop yet to explain the app.
            showSettingsWindow()
        }
    }

    /// When user re-opens the app (clicks .app again while running), show UI
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusItem()
        showSettingsWindow()
        return false
    }

    /// The app name, sitting in the titlebar to the right of the tab pill.
    ///
    /// A titlebar accessory rather than a row inside the content: level with the tabs is where
    /// it reads as the window's identity, and anywhere in the content area it reads as a
    /// heading for whatever sits under it.
    private static func wordmarkAccessory() -> NSTitlebarAccessoryViewController {
        let size: CGFloat = 17
        let rounded = NSFont.systemFont(ofSize: size, weight: .bold).fontDescriptor.withDesign(.rounded)
        let font = rounded.flatMap { NSFont(descriptor: $0, size: size) }
            ?? .systemFont(ofSize: size, weight: .bold)

        let attributed = NSAttributedString(
            string: Constants.appName,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor, .kern: 0.6]
        )
        let textSize = attributed.size()
        // 28pt is the standard titlebar height. A taller accessory makes AppKit grow the
        // whole title bar, which pushed the tab pill down and off-centre.
        let height: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: ceil(textSize.width) + 28, height: height))
        container.wantsLayer = true

        // The wordmark is a gradient masked by the glyphs, rather than flat text: it falls off
        // toward the baseline so it reads as a mark instead of another label in the title bar.
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        let glyphs = CATextLayer()
        glyphs.string = attributed
        glyphs.contentsScale = scale
        glyphs.frame = CGRect(x: 0, y: 0, width: ceil(textSize.width) + 2, height: ceil(textSize.height))

        let gradient = CAGradientLayer()
        gradient.frame = glyphs.frame
        gradient.contentsScale = scale
        gradient.colors = [
            NSColor.labelColor.cgColor,
            NSColor.labelColor.withAlphaComponent(0.55).cgColor
        ]
        // CALayer geometry is not flipped here, so (0.5, 1) is the top edge.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.mask = glyphs

        gradient.frame.origin = CGPoint(x: 4, y: (height - gradient.frame.height) / 2)
        container.layer?.addSublayer(gradient)

        container.setAccessibilityRole(.staticText)
        container.setAccessibilityLabel(Constants.appName)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = container
        return accessory
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
        statusItem?.button?.toolTip = "\(Constants.appName). drop images here to add them"
        statusItem?.button?.image?.size = NSSize(width: 18, height: 18)

        attachDropTarget()

        UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")

        // Create the menu with a delegate so it rebuilds every time it opens
        let menu = NSMenu()
        menu.delegate = self
        // We decide enablement ourselves (e.g. Paste depends on the clipboard);
        // AppKit's automatic pass would just re-enable anything with a target.
        menu.autoenablesItems = false
        statusItem?.menu = menu
        rebuildMenu()
    }

    func hideStatusItem() {
        statusItem?.statusBar?.removeStatusItem(statusItem!)
        statusItem = nil
        dropView = nil
        UserDefaults.standard.set(true, forKey: "hideMenuBarIcon")
    }

    // MARK: - Drag & Drop onto the menu bar icon

    /// Overlays the status button with a drop target sized to track it.
    private func attachDropTarget() {
        guard let button = statusItem?.button else { return }

        let view = StatusItemDropView(frame: button.bounds)
        view.autoresizingMask = [.width, .height]
        view.onDrop = { [weak self] urls in
            guard let self else { return }
            let added = self.manager.addImages(from: urls)
            if added > 0 { self.rebuildMenu() }
        }
        button.addSubview(view)
        dropView = view
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotKey() {
        HotKeyManager.shared.onTrigger = { [weak self] in
            guard let self else { return }
            self.manager.toggleAllVisibility()
            self.rebuildMenu()
        }
        HotKeyManager.shared.start()
    }

    // MARK: - Paste (⌘V)

    /// A menu bar agent has no main menu to hang ⌘V off, so the shortcut is
    /// caught locally while one of our own windows is key. The status menu item
    /// covers the case where no window is open.
    private func setupPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }
            // Don't steal ⌘V from a text field the user is typing in.
            if self.settingsWindow?.firstResponder is NSTextView { return event }

            return self.pasteFromClipboard() ? nil : event
        }
    }

    /// - Returns: true if at least one widget was created.
    @discardableResult
    private func pasteFromClipboard() -> Bool {
        let added = manager.addFromPasteboard()
        guard added > 0 else { return false }
        rebuildMenu()
        return true
    }

    @objc func pasteAsWidget() {
        guard pasteFromClipboard() else {
            let alert = NSAlert()
            alert.messageText = "Nothing to paste"
            alert.informativeText = "Copy an image or an image file first, then try again."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
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

        // Optional commands are opt-in from Preferences; the menu stays short by
        // default rather than growing a slot per feature.
        let visible = MenuBarCustomization.shared

        if visible.isVisible(.addSpace) {
            let addSpaceItem = NSMenuItem(title: "Add Space…", action: #selector(addSpace), keyEquivalent: "")
            addSpaceItem.target = self
            menu.addItem(addSpaceItem)
        }

        if visible.isVisible(.paste) {
            // Greyed out unless the clipboard actually holds an image.
            let pasteItem = NSMenuItem(title: "Paste as Widget", action: #selector(pasteAsWidget), keyEquivalent: "v")
            pasteItem.target = self
            pasteItem.isEnabled = manager.pasteboardHasImage
            menu.addItem(pasteItem)
        }

        if visible.isVisible(.captureRegion) {
            let captureItem = NSMenuItem(title: "Capture Screen Region…", action: #selector(captureRegion), keyEquivalent: "")
            captureItem.target = self
            menu.addItem(captureItem)
        }

        if visible.isVisible(.pdfPage) {
            let pdfItem = NSMenuItem(title: "Add PDF Page…", action: #selector(addPDFPage), keyEquivalent: "")
            pdfItem.target = self
            menu.addItem(pdfItem)
        }

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if !manager.photos.isEmpty {
            menu.addItem(.separator())

            // Show/Hide All — mirrors the global hotkey, and advertises it.
            let anyVisible = manager.photos.contains { $0.isVisible }
            if visible.isVisible(.toggleAll) {
            let toggleAllItem = NSMenuItem(
                title: anyVisible ? "Hide All Photos" : "Show All Photos",
                action: #selector(toggleAllVisibility),
                keyEquivalent: ""
            )
            toggleAllItem.target = self
            if HotKeyManager.shared.isEnabled {
                toggleAllItem.toolTip = "Global shortcut: \(HotKeyManager.shared.shortcut.displayString)"
            }
            menu.addItem(toggleAllItem)
            menu.addItem(.separator())
            }

            for (index, item) in manager.photos.enumerated() {
                let submenu = NSMenu()

                // Float toggle
                let floatItem = NSMenuItem(
                    title: item.depth == .floating ? "Pin to Desktop" : "Float Above Windows",
                    action: #selector(toggleFloating(_:)),
                    keyEquivalent: ""
                )
                floatItem.target = self
                floatItem.tag = index
                submenu.addItem(floatItem)

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

                // Clean status badges
                var badges: [String] = []
                if !item.isVisible { badges.append("hidden") }
                if item.isLocked { badges.append("locked") }
                if item.depth == .floating { badges.append("floating") }
                if !item.spaceImageFilenames.isEmpty { badges.append("folder") }

                let label = badges.isEmpty ? title : "\(title). \(badges.joined(separator: ", "))"
                photoItem.title = label   // plain text still backs VoiceOver and menu search

                // The thumbnail rides in the title as a text attachment rather than
                // going through `NSMenuItem.image`, which macOS 27 no longer draws in a
                // status bar menu — verified by setting a plain SF Symbol on several
                // items and getting nothing. Text rendering still works, and this keeps
                // native highlight and submenu behaviour that a custom item view
                // would force us to reimplement.
                if let thumb = manager.thumbnail(for: item, size: 16) {
                    photoItem.attributedTitle = Self.attributedLabel(label, thumbnail: thumb)
                }

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

        if visible.isVisible(.privacy) {
            menu.addItem(privacyMenuItem())
        }

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

    /// Builds a menu label with the photo's thumbnail inlined ahead of the text.
    ///
    /// The attachment is nudged below the baseline so a 16pt image sits centred on a
    /// standard menu row instead of riding high on it.
    private static func attributedLabel(_ text: String, thumbnail: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = thumbnail
        attachment.bounds = NSRect(x: 0, y: -4, width: 16, height: 16)

        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(
            string: "  " + text,
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        ))
        return result
    }

    // MARK: - Updates

    /// Opens Settings and runs a check there, so the result lands in the same
    /// place the user would look for it rather than in a modal they dismiss.
    @objc func checkForUpdates() {
        showSettingsWindow()
        Task { await Updater.shared.check(userInitiated: true) }
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

        let contentView = MainWindowView(manager: manager, onMenuUpdate: { [weak self] in
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
        window.addTitlebarAccessoryViewController(Self.wordmarkAccessory())
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
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            await manager.addPhotos(urls: urls)
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

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            await manager.addSpace(urls: urls)
            rebuildMenu()
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
        // The menu keeps the old two-state flip: desktop <-> floating. The four-way depth
        // control lives in Settings, where its one non-obvious mode can carry its caveat.
        let current = manager.photos[index].depth
        manager.setDepth(manager.photos[index].id, current == .floating ? .onDesktop : .floating)
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
            manager.appendPhotosToSpace(id, urls: panel.urls)
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

    @objc func toggleAllVisibility() {
        manager.toggleAllVisibility()
        rebuildMenu()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = sender.state == .off
        manager.setLaunchAtLogin(newState)
    }

    /// Privacy submenu. These are app-wide rather than per-photo, so they live in
    /// the menu bar next to the other global switches.
    private func privacyMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Privacy", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let exclude = NSMenuItem(
            title: "Hide from Screen Sharing & Recording",
            action: #selector(toggleExcludeFromScreenCapture),
            keyEquivalent: ""
        )
        exclude.target = self
        exclude.state = manager.excludeFromScreenCapture ? .on : .off
        // Worth stating plainly: this one is a real guarantee, not a guess.
        exclude.toolTip = "Photos stay visible to you but are excluded from screen shares and recordings. Does not cover AirPlay or HDMI mirroring."
        submenu.addItem(exclude)

        let conferencing = NSMenuItem(
            title: "Auto-Hide During Calls",
            action: #selector(toggleAutoHideForConferencing),
            keyEquivalent: ""
        )
        conferencing.target = self
        conferencing.state = manager.autoHideForConferencingApps ? .on : .off
        conferencing.toolTip = "Best effort: hides photos while Zoom, Teams, QuickTime, OBS or Screenshot are running. A running app isn't proof of an active share, and browser calls aren't detectable."
        submenu.addItem(conferencing)

        if manager.isConferencingAppDetected {
            let detected = NSMenuItem(title: "  Call app detected", action: nil, keyEquivalent: "")
            detected.isEnabled = false
            submenu.addItem(detected)
        }

        submenu.addItem(.separator())

        let fullscreen = NSMenuItem(
            title: "Hide Behind Fullscreen Apps",
            action: #selector(toggleHideWhenFullscreen),
            keyEquivalent: ""
        )
        fullscreen.target = self
        fullscreen.state = manager.hideWhenFullscreenActive ? .on : .off
        fullscreen.toolTip = "Photos are invisible behind a fullscreen app anyway; hiding them frees memory and stops rotation timers."
        submenu.addItem(fullscreen)

        item.submenu = submenu
        return item
    }

    @objc func toggleExcludeFromScreenCapture() {
        manager.setExcludeFromScreenCapture(!manager.excludeFromScreenCapture)
        rebuildMenu()
    }

    @objc func toggleAutoHideForConferencing() {
        manager.setAutoHideForConferencingApps(!manager.autoHideForConferencingApps)
        rebuildMenu()
    }

    @objc func toggleHideWhenFullscreen() {
        manager.setHideWhenFullscreenActive(!manager.hideWhenFullscreenActive)
        rebuildMenu()
    }

    @objc func captureRegion() {
        // screencapture -i is interactive; the menu has already closed by the
        // time the crosshair appears, so nothing needs to be held open here.
        manager.captureScreenshotRegion()
    }

    @objc func addPDFPage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Pick a PDF to place a page on your desktop"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let pageCount = manager.pdfPageCount(at: url)
        guard pageCount > 0 else {
            presentSimpleAlert(title: "Couldn't Read That PDF", body: "The file didn't contain any pages.")
            return
        }

        var pageIndex = 0
        if pageCount > 1 {
            guard let chosen = promptForPage(max: pageCount) else { return }
            pageIndex = chosen - 1
        }

        if manager.addPDFPage(at: url, pageIndex: pageIndex) {
            rebuildMenu()
        } else {
            presentSimpleAlert(title: "Couldn't Add That Page", body: "The page couldn't be rendered.")
        }
    }

    /// Asks which page to place. Only shown for multi-page documents.
    private func promptForPage(max pageCount: Int) -> Int? {
        let alert = NSAlert()
        alert.messageText = "Which page?"
        alert.informativeText = "This PDF has \(pageCount) pages."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        field.stringValue = "1"
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        // Clamp rather than reject: a typo shouldn't throw away the whole action.
        return min(max(Int(field.stringValue) ?? 1, 1), pageCount)
    }

    private func presentSimpleAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
