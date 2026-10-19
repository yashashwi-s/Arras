import AppKit
import SwiftUI
import QuartzCore

/// AppDelegate manages the menu bar status item and the settings window.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    /// SwiftUI installs its own NSApp.delegate; retain only a weak bridge to its adaptor.
    static weak var current: AppDelegate?
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    let settingsNavigation = SettingsNavigation()
    var collageEditor: CollageEditorWindowController?
    let manager: PhotoManager

    override convenience init() { self.init(manager: PhotoManager()) }

    init(manager: PhotoManager) {
        self.manager = manager
        super.init()
    }

    private var dropView: StatusItemDropView?
    private var pasteMonitor: Any?
    #if !ARRAS_APP_STORE
    private var telemetry: TelemetryRuntime?
    #endif

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        // Use this bundle's approved icon rather than a cached icon from an older preview.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        // Hosted unit tests load this executable too. Only explicit UI tests should launch
        // windows or register app-wide services; their storage is supplied by the harness.
        guard !PhotoManager.isUnitTestHost || isUITesting else { return }
        // Before anything shows UI, so the Dock icon and menu bar are correct on
        // the first frame rather than appearing a moment later.
        AppActivation.shared.apply()

        #if !ARRAS_APP_STORE
        // Let the swap helper know that this bundle reached its own startup before any update
        // UI or network work can delay it. A matching version is required by the helper's health
        // breadcrumb, so a rollback cannot accidentally acknowledge the replacement.
        Updater.markUpdateHealthyIfNeeded()

        // Before anything else can fail because of it: an app run from a disk image cannot
        // replace itself, and discovering that at update time is a dead end.
        if !isUITesting {
            InstallLocation.offerToInstallIfNeeded()
        }
        #endif

        setupStatusItem()
        setupGlobalHotKey()
        setupPasteMonitor()
        NotificationCenter.default.addObserver(forName: .openDesktopCollageSettings, object: nil, queue: .main) { [weak self] notification in
            guard let id = notification.object as? UUID else { return }
            MainActor.assumeIsolated { self?.showCollageEditor(id) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.manager.restoreCollageOrdering() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Restore only panels on the newly active Space after its transition.
            DispatchQueue.main.async { [weak self] in self?.manager.restoreCollageOrdering() }
        }

        #if ARRAS_APP_STORE
        if isUITesting {
            showSettingsWindow()
            presentUITestPreflightIfRequested()
        } else if manager.photos.isEmpty {
            showSettingsWindow()
        }
        #else
        // Show settings after an update attempt, so success or rollback is visible rather
        // than the app appearing to have closed and reopened for no reason.
        if isUITesting {
            showSettingsWindow()
            presentUITestPreflightIfRequested()
        } else if let installed = UserDefaults.standard.string(forKey: Updater.justUpdatedKey) {
            // The swap helper is launched before this process exits, so a failed helper can
            // leave the breadcrumb behind while the old bundle is opened again. Consume it in
            // both cases and let Updater distinguish a real install from a rollback.
            UserDefaults.standard.removeObject(forKey: Updater.justUpdatedKey)
            UserDefaults.standard.removeObject(forKey: Updater.updateHealthMarkerKey)
            showUpdateSettings()
            Updater.shared.announceInstallResult(expectedVersion: installed)
        } else if manager.photos.isEmpty {
            // First launch — there is nothing on the desktop yet to explain the app.
            showSettingsWindow()
        }

        // Polls the appcast on launch and at the configured cadence. Notification
        // permission is requested only if a notification is needed.
        if !isUITesting {
            Updater.shared.start()
            if let configuration = TelemetryConfiguration.current {
                telemetry = TelemetryRuntime(manager: manager, configuration: configuration)
            }
        }
        #endif
    }

    /// UI tests can request one isolated archive-preflight presentation without driving an
    /// Open Panel. The test supplies a temporary destination under its own storage directory;
    /// the app exports the first fixture widget there, then runs the same validated preflight
    /// and selection UI used by a user. This is deliberately unreachable without both the
    /// `--ui-testing` argument and the dedicated environment variable.
    private func presentUITestPreflightIfRequested() {
        guard let rawPath = ProcessInfo.processInfo.environment["ARRAS_UI_TEST_PREFLIGHT_ARCHIVE"],
              !rawPath.isEmpty else { return }

        let archiveURL = URL(fileURLWithPath: rawPath)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            do {
                if !FileManager.default.fileExists(atPath: archiveURL.path) {
                    guard let fixture = self.manager.photos.first(where: { !$0.filename.isEmpty }) else { return }
                    _ = try self.manager.exportWidget(fixture.id, to: archiveURL)
                }
                LayoutArchiveImportFlow.present(url: archiveURL, manager: self.manager)
            } catch {
                NSLog("Arras UI-test preflight fixture could not be generated: %@", error.localizedDescription)
            }
        }
    }

    /// When user re-opens the app (clicks .app again while running), show UI
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusItem()
        showSettingsWindow()
        return false
    }

    /// Finder-opened Arras backups stay in the menu-bar app's existing import flow. Arras does
    /// not adopt NSDocument; Finder simply delivers the URL and this delegate asks for the same
    /// merge/replace choice used by Settings before calling the validated archive importer.
    func application(_ application: NSApplication, open urls: [URL]) {
        let archives = urls.filter(BackupFormat.isArchiveURL)
        guard !archives.isEmpty else { return }

        showSettingsWindow()
        for archive in archives {
            LayoutArchiveImportFlow.present(
                url: archive,
                manager: manager,
                onMenuUpdate: { [weak self] in self?.rebuildMenu() }
            )
        }
    }

    /// Puts the gradient app wordmark in the title bar, level with the tab pill.
    ///
    /// Added straight into the title bar's own view hierarchy rather than through
    /// `addTitlebarAccessoryViewController`. Installing an accessory changes how AppKit lays
    /// the title bar out, and the SwiftUI tab control stopped rendering as a translucent pill
    /// and came out flat and squared off. A plain subview leaves that alone.
    private static func installWordmark(in window: NSWindow) {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }

        let size: CGFloat = 17
        let descriptor = NSFont.systemFont(ofSize: size, weight: .bold).fontDescriptor.withDesign(.rounded)
        let font = descriptor.flatMap { NSFont(descriptor: $0, size: size) }
            ?? .systemFont(ofSize: size, weight: .bold)

        let attributed = NSAttributedString(
            string: Constants.appName,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor, .kern: 0.6]
        )
        let textSize = attributed.size()
        let height: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: ceil(textSize.width) + 28, height: height))
        container.wantsLayer = true
        container.identifier = wordmarkID

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

        // The container carries 22pt of empty space to the right of the glyphs, which is the
        // trailing margin the titlebar accessory used to give it. Flush right reproduces it.
        container.frame.origin = NSPoint(
            x: titlebar.bounds.maxX - container.frame.width,
            y: (titlebar.bounds.height - height) / 2
        )
        container.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]

        titlebar.subviews.first { $0.identifier == wordmarkID }?.removeFromSuperview()
        titlebar.addSubview(container)
    }

    private static let wordmarkID = NSUserInterfaceItemIdentifier("ArrasWordmark")

    // MARK: - Status Item (Menu Bar Icon)

    /// Applies the persisted menu-bar icon choice to the live status item and refreshes its
    /// menu. Importing settings writes UserDefaults through PhotoManager, but AppDelegate owns
    /// the AppKit status item, so the UI callback must bridge the persisted choice to the live
    /// object instead of merely rebuilding a possibly hidden menu.
    func syncStatusItemVisibility() {
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            hideStatusItem()
        } else {
            showStatusItem()
            rebuildMenu()
        }
    }

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
            Task { @MainActor in
                let result = await self.manager.importPhotos(urls: urls)
                self.rebuildMenu()
                ImportBatchPresenter.present(result, title: "Status Item Drop")
            }
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
            guard self.settingsWindow?.isKeyWindow == true else { return event }
            // The settings window owns this monitor for list keyboard commands. Never steal
            // arrows or Command-C/V from a text field while a name/number is being edited.
            if self.settingsWindow?.firstResponder is NSTextView { return event }
            if self.manager.handleSelectionKey(event) { return nil }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }
            // Don't steal ⌘V from a text field the user is typing in.
            return self.pasteFromClipboard() ? nil : event
        }
    }

    /// - Returns: true if the pasteboard offered an image to process. The completed result is
    /// presented asynchronously so the key monitor can decide immediately whether to consume
    /// the shortcut.
    @discardableResult
    private func pasteFromClipboard() -> Bool {
        guard manager.pasteboardHasImage else { return false }
        Task { @MainActor in
            let result = await manager.importFromPasteboard()
            rebuildMenu()
            ImportBatchPresenter.present(result, title: "Clipboard Import")
        }
        return true
    }

    @objc func pasteAsWidget() {
        guard pasteFromClipboard() else {
            AppDialog.inform(title: "Nothing to Paste", message: "Copy an image or an image file first, then try again.")
            return
        }
    }

    // MARK: - NSMenuDelegate — rebuild menu every time the user clicks the icon

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in
            self.rebuildMenu()
        }
    }

    @objc private func createDesktopCollage() {
        _ = manager.addDesktopCollage()
        rebuildMenu()
    }

    // MARK: - Build Menu

    func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let addMenu = NSMenu(title: "Add")
        let addRoot = NSMenuItem(title: "Add", action: nil, keyEquivalent: "")
        addRoot.submenu = addMenu
        menu.addItem(addRoot)

        // Add Photo
        let addItem = NSMenuItem(title: "Add Photos or Videos…", action: #selector(addPhoto), keyEquivalent: "")
        addItem.target = self
        addMenu.addItem(addItem)

        let addPhotosCollectionItem = NSMenuItem(
            title: "From Photos Collection…",
            action: #selector(addPhotosLibraryCollection),
            keyEquivalent: ""
        )
        addPhotosCollectionItem.target = self
        addPhotosCollectionItem.toolTip = "Keep a managed snapshot synchronized with a Photos Album, Smart Album, or Shared Album"
        addMenu.addItem(addPhotosCollectionItem)

        addMenu.addItem(.separator())
        let collageItem = NSMenuItem(title: "Create Collage", action: #selector(createDesktopCollage), keyEquivalent: "")
        collageItem.target = self
        addMenu.addItem(collageItem)

        // Optional commands are opt-in from Preferences; the menu stays short by
        // default rather than growing a slot per feature.
        let visible = MenuBarCustomization.shared

        if visible.isVisible(.addSpace) {
            let addSpaceItem = NSMenuItem(title: "Create Slideshow…", action: #selector(addSpace), keyEquivalent: "")
            addSpaceItem.target = self
            addMenu.addItem(addSpaceItem)

            let addFolderSpaceItem = NSMenuItem(title: "Slideshow from Folder…", action: #selector(addFolderSpace), keyEquivalent: "")
            addFolderSpaceItem.target = self
            addFolderSpaceItem.toolTip = "Keep a managed snapshot in sync with a Finder folder"
            addMenu.addItem(addFolderSpaceItem)
        }

        if [.paste, .captureRegion, .pdfPage].contains(where: visible.isVisible) {
            addMenu.addItem(.separator())
        }
        if visible.isVisible(.paste) {
            // Greyed out unless the clipboard actually holds an image.
            let pasteItem = NSMenuItem(title: "Paste as Widget", action: #selector(pasteAsWidget), keyEquivalent: "v")
            pasteItem.target = self
            pasteItem.isEnabled = manager.pasteboardHasImage
            addMenu.addItem(pasteItem)
        }

        if visible.isVisible(.captureRegion) {
            let captureItem = NSMenuItem(title: "Capture Screen Region…", action: #selector(captureRegion), keyEquivalent: "")
            captureItem.target = self
            addMenu.addItem(captureItem)
        }

        if visible.isVisible(.pdfPage) {
            let pdfItem = NSMenuItem(title: "Add PDF Page…", action: #selector(addPDFPage), keyEquivalent: "")
            pdfItem.target = self
            addMenu.addItem(pdfItem)
        }

        if !manager.photos.isEmpty {
            let widgetsMenu = NSMenu(title: "Widgets")
            let widgetsRoot = NSMenuItem(title: "Widgets (\(manager.photos.count))", action: nil, keyEquivalent: "")
            widgetsRoot.submenu = widgetsMenu
            menu.addItem(widgetsRoot)

            for (index, item) in manager.photos.enumerated() {
                let submenu = NSMenu()

                // Float toggle
                let floating = manager.effectiveDepth(of: item) == .floating
                let grouped = item.collageParentID != nil
                let floatItem = NSMenuItem(
                    title: floating ? (grouped ? "Pin Collage to Desktop" : "Pin to Desktop") : (grouped ? "Float Collage Above Windows" : "Float Above Windows"),
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
                    title: manager.isLockedByCollage(item) ? "Unlock Collage" : (item.isLocked ? "Unlock Position" : "Lock Position"),
                    action: #selector(togglePhotoLock(_:)),
                    keyEquivalent: ""
                )
                lockItem.target = self
                lockItem.tag = index
                submenu.addItem(lockItem)

                submenu.addItem(.separator())

                // Rename
                let renameItem = NSMenuItem(title: "Rename in Settings…", action: #selector(renamePhoto(_:)), keyEquivalent: "")
                renameItem.target = self
                renameItem.tag = index
                submenu.addItem(renameItem)

                // Replace the primary image, or the currently selected slot in a Space. The
                // manager owns the durable slot update; keeping this in the status menu makes
                // replacement reachable even when a widget is hidden or its Settings row is
                // collapsed.
                let replaceTitle: String
                if item.media.kind.isVideoKind {
                    replaceTitle = "Replace Video…"
                } else if item.spaceImageFilenames.isEmpty {
                    replaceTitle = "Replace Image…"
                } else {
                    replaceTitle = "Replace Current Slideshow Image…"
                }
                let replaceItem = NSMenuItem(title: replaceTitle, action: #selector(replacePhoto(_:)), keyEquivalent: "")
                replaceItem.target = self
                replaceItem.tag = index
                if item.desktopCollage == nil && item.allowsManualMediaEditing { submenu.addItem(replaceItem) }

                // Duplicate
                let dupItem = NSMenuItem(title: "Duplicate", action: #selector(duplicatePhoto(_:)), keyEquivalent: "")
                dupItem.target = self
                dupItem.tag = index
                if item.desktopCollage == nil { submenu.addItem(dupItem) }

                let exportItem = NSMenuItem(title: "Export .arras…", action: #selector(exportPhoto(_:)), keyEquivalent: "")
                exportItem.target = self
                exportItem.tag = index
                submenu.addItem(exportItem)

                // Folder navigation
                if !item.spaceImageFilenames.isEmpty {
                    submenu.addItem(.separator())
                    let count = manager.folderImageCount(item.id)
                    let position = "\(item.folderImageIndex + 1) of \(count) images"
                    let posLabel = NSMenuItem(title: position, action: nil, keyEquivalent: "")
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
                    
                    if item.allowsManualMediaEditing {
                        submenu.addItem(.separator())

                        let appendItem = NSMenuItem(
                            title: "Add Photos to Slideshow…",
                            action: #selector(appendPhotosToSpaceMenu(_:)),
                            keyEquivalent: ""
                        )
                        appendItem.target = self
                        appendItem.tag = index
                        submenu.addItem(appendItem)
                    }
                }

                if item.liveFolderSource != nil {
                    let source = manager.liveFolderStatusDescription(for: item.id) ?? "Live folder"
                    let statusItem = NSMenuItem(title: source, action: nil, keyEquivalent: "")
                    statusItem.isEnabled = false
                    submenu.addItem(statusItem)

                    let relinkItem = NSMenuItem(
                        title: item.liveFolderSource?.status.needsRelink == true ? "Relink Folder…" : "Choose Different Folder…",
                        action: #selector(relinkLiveFolderMenu(_:)),
                        keyEquivalent: ""
                    )
                    relinkItem.target = self
                    relinkItem.tag = index
                    submenu.addItem(relinkItem)
                }

                if item.photosLibrarySource != nil {
                    let source = manager.photosLibraryStatusDescription(for: item.id) ?? "Photos collection"
                    let statusItem = NSMenuItem(title: source, action: nil, keyEquivalent: "")
                    statusItem.isEnabled = false
                    submenu.addItem(statusItem)

                    let refreshItem = NSMenuItem(
                        title: item.photosLibrarySource?.status.needsRelink == true ? "Choose Collection…" : "Refresh Photos Collection",
                        action: #selector(refreshPhotosLibraryCollectionMenu(_:)),
                        keyEquivalent: ""
                    )
                    refreshItem.target = self
                    refreshItem.tag = index
                    submenu.addItem(refreshItem)
                }

                submenu.addItem(.separator())

                let removeItem = NSMenuItem(title: item.desktopCollage != nil ? "Remove Collage, Keep Photos" : "Remove", action: #selector(removePhotoMenu(_:)), keyEquivalent: "")
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
                if manager.isLockedByCollage(item) { badges.append("locked by collage") } else if item.isLocked { badges.append("locked") }
                if floating { badges.append("floating") }
                if item.media.kind.isVideoKind { badges.append("\(item.media.kind.displayName.lowercased()) · muted") }
                else if let source = item.liveFolderSource {
                    badges.append("live folder · \(source.status.displayName.lowercased())")
                } else if let source = item.photosLibrarySource {
                    badges.append("Photos · \(source.status.displayName.lowercased())")
                } else if !item.spaceImageFilenames.isEmpty { badges.append("folder") }

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

                widgetsMenu.addItem(photoItem)
            }

            let removeAllItem = NSMenuItem(title: "Remove All Widgets", action: #selector(removeAllPhotos), keyEquivalent: "")
            removeAllItem.target = self
            widgetsMenu.addItem(.separator())
            widgetsMenu.addItem(removeAllItem)

            // Keep global visibility beside the widgets it affects.
            if visible.isVisible(.toggleAll) {
                let toggleAllItem = NSMenuItem(
                    title: manager.photos.contains { $0.isVisible } ? "Hide All Widgets" : "Show All Widgets",
                    action: #selector(toggleAllVisibility), keyEquivalent: ""
                )
                toggleAllItem.target = self
                if HotKeyManager.shared.isEnabled {
                    toggleAllItem.toolTip = "Global shortcut: \(HotKeyManager.shared.shortcut.displayString)"
                }
                menu.addItem(toggleAllItem)
            }
        }

        menu.addItem(.separator())
        menu.addItem(manager.makeArrangementMenuPalette())
        if manager.removedWidgetCount > 0 {
            let restore = NSMenuItem(title: "Restore Removed Widgets", action: #selector(restoreRemovedWidgets), keyEquivalent: "")
            restore.target = self
            menu.addItem(restore)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let optionsMenu = NSMenu(title: "Options")
        let optionsRoot = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        optionsRoot.submenu = optionsMenu
        menu.addItem(optionsRoot)

        // Launch at Login
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = manager.launchAtLogin ? .on : .off
        optionsMenu.addItem(loginItem)

        if visible.isVisible(.privacy) {
            optionsMenu.addItem(privacyMenuItem())
        }

        // Hide Menu Bar Icon
        let hideItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideMenuBarIcon), keyEquivalent: "")
        hideItem.target = self
        optionsMenu.addItem(hideItem)

        #if ARRAS_APP_STORE
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        optionsMenu.addItem(updateItem)
        #else
        if Updater.shared.updatesAllowed {
            let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
            optionsMenu.addItem(updateItem)
        } else {
            optionsMenu.addItem(NSMenuItem(title: "Updates Paused for Test Build", action: nil, keyEquivalent: ""))
        }
        #endif

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

    /// Routes updates through Preferences using the selected distribution's updater.
    @objc func checkForUpdates() {
        showUpdateSettings()
        #if ARRAS_APP_STORE
        AppStoreUpdates.checkForUpdates()
        #else
        Task { await Updater.shared.check(userInitiated: true) }
        #endif
    }

    func showUpdateSettings() {
        settingsNavigation.showUpdates()
        showSettingsWindow()
    }

    // MARK: - Settings Window

    @objc func showSettingsFromMenu() {
        showSettingsWindow()
    }

    @objc func starOnGitHub() {
        NSWorkspace.shared.open(Constants.repositoryURL)
    }

    /// Keeps the one managed Settings window visually native and attached to the Space where
    /// the user asked for it. Without `.moveToActiveSpace`, ordering an existing window brings
    /// the user to the window's old Space instead of bringing Settings to them.
    static func configureSettingsWindow(_ window: NSWindow) {
        // A raised level defaults to transient window management. Settings is
        // Arras's primary window even though the application remains an agent.
        window.level = .normal
        window.collectionBehavior = [.managed, .primary, .moveToActiveSpace, .fullScreenNone]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let window = settingsWindow, window.isVisible, !window.isMiniaturized else { return }
        manager.setSettingsWindowActive(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        manager.setSettingsWindowActive(false)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { manager.setSettingsWindowActive(false) }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { manager.setSettingsWindowActive(false) }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow, NSApp.isActive {
            manager.setSettingsWindowActive(true)
            settingsWindow?.orderFront(nil)
        }
    }

    func showSettingsWindow() {
        if let window = settingsWindow {
            Self.configureSettingsWindow(window)
            manager.setSettingsWindowActive(true)
            if !window.isOnActiveSpace {
                window.orderOut(nil)
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSCursor.arrow.set()
            return
        }

        let contentView = MainWindowView(manager: manager, navigation: settingsNavigation, onMenuUpdate: { [weak self] in
            self?.syncStatusItemVisibility()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Constants.appName
        window.center()
        window.minSize = NSSize(width: Constants.settingsMinimumWidth, height: Constants.settingsMinimumHeight)
        window.contentView = NSHostingView(rootView: contentView)
        Self.configureSettingsWindow(window)
        Self.installWordmark(in: window)
        window.delegate = self
        settingsWindow = window
        manager.setSettingsWindowActive(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.arrow.set()
    }

    // MARK: - Menu Actions

    func showCollageEditor(_ id: UUID) {
        guard manager.photos.contains(where: { $0.id == id && $0.desktopCollage != nil }) else { return }
        manager.restoreCollageOrdering()
        defer {
            manager.restoreCollageOrdering()
            DispatchQueue.main.async { [weak self] in self?.manager.restoreCollageOrdering() }
        }
        if let editor = collageEditor, editor.collageID == id {
            editor.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let editor = collageEditor {
            editor.requestClose(onClosed: { [weak self] in self?.showCollageEditor(id) })
            return
        }
        let editor = CollageEditorWindowController(manager: manager, id: id) { [weak self] in
            if self?.collageEditor?.collageID == id { self?.collageEditor = nil }
        }
        collageEditor = editor
        if let window = editor.window, let collage = manager.windows[id] {
            let screen = (collage.screen ?? NSScreen.main)?.visibleFrame ?? collage.photoFrame
            let size = window.frame.size
            let body = collage.photoFrame
            let left = body.minX - size.width - 20
            let right = body.maxX + 20
            let x = left >= screen.minX + 12 ? left : (right + size.width <= screen.maxX - 12 ? right : screen.minX + 12)
            let y = min(screen.maxY - size.height - 12, max(screen.minY + 12, body.maxY - size.height))
            window.setFrameOrigin(CGPoint(x: x, y: y))
        } else { editor.window?.center() }
        editor.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func addPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let result = await manager.importPhotos(urls: urls)
            rebuildMenu()
            ImportBatchPresenter.present(result, title: "Finder Import")
        }
    }

    @objc func addPhotosLibraryCollection() {
        PhotosLibraryCollectionPicker.present(
            manager: manager,
            onMenuUpdate: { [weak self] in self?.rebuildMenu() }
        )
    }

    @objc func addSpace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.prompt = "Add Images to Space"
        panel.message = "Choose multiple images to display as a rotating Space"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let result = await manager.addSpace(urls: urls)
            rebuildMenu()
            ImportBatchPresenter.present(result, title: "Slideshow Import")
        }
    }

    @objc func addFolderSpace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder Space"
        panel.message = "Choose a folder. Arras stores a managed snapshot and watches it for changes."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task { @MainActor in
            let result = await manager.addLiveFolderSpace(folderURL)
            rebuildMenu()
            ImportBatchPresenter.present(result, title: "Folder Slideshow Import")
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
        let current = manager.effectiveDepth(of: manager.photos[index])
        manager.setDepth(manager.photos[index].id, current == .floating ? .onDesktop : .floating)
    }

    /// Opens Settings so the name can be edited in the row itself.
    ///
    /// This used to put up a modal alert with a text field in it, which is a lot of ceremony
    /// for changing a label, and a second place renaming could happen.
    @objc func renamePhoto(_ sender: NSMenuItem) {
        showSettingsWindow()
    }

    @objc func replacePhoto(_ sender: NSMenuItem) {
        let index = sender.tag
        guard manager.photos.indices.contains(index), manager.photos[index].allowsManualMediaEditing else { return }
        let id = manager.photos[index].id

        let panel = NSOpenPanel()
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.allowsMultipleSelection = false
        panel.prompt = "Replace"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            let result = await manager.replacePhoto(id, with: url)
            ImportBatchPresenter.present(result, title: "Replace Media")
            rebuildMenu()
        }
    }

    @objc func duplicatePhoto(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        manager.duplicatePhoto(manager.photos[index].id)
    }

    @objc func exportPhoto(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        let item = manager.photos[index]
        let panel = NSSavePanel()
        panel.allowedContentTypes = [BackupFormat.exportType]
        let label = manager.label(for: item)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(label).\(BackupFormat.currentExtension)"
        panel.prompt = "Export"
        panel.message = "Export this widget and all of its stored media as an Arras archive"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = try manager.exportWidget(
                item.id,
                to: url,
                archivalQuality: UserDefaults.standard.bool(forKey: "backup.archivalQuality")
            )
            LayoutArchiveExportFlow.present(report, title: "Widget Export Complete")
        } catch {
            LayoutArchiveExportFlow.present(error: error, title: "Couldn't Export Widget")
        }
    }

    @objc func nextFolderImage(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        let item = manager.photos[index]
        manager.nextFolderImage(item.id)
    }

    @objc func prevFolderImage(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        let item = manager.photos[index]
        manager.prevFolderImage(item.id)
    }

    @objc func appendPhotosToSpaceMenu(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        let id = manager.photos[index].id
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.prompt = "Add to Slideshow"
        panel.message = "Choose multiple images to append to this slideshow"

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { @MainActor in
                let result = await manager.appendPhotosToSpace(id, urls: urls)
                rebuildMenu()
                ImportBatchPresenter.present(result, title: "Slideshow Import")
            }
        }
    }

    @objc func relinkLiveFolderMenu(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count, manager.photos[index].liveFolderSource != nil else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink Folder"
        panel.message = "Choose the folder to use for this live Space."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        let id = manager.photos[index].id
        Task { @MainActor in
            let result = await manager.relinkLiveFolder(id, to: folderURL)
            rebuildMenu()
            ImportBatchPresenter.present(result, title: "Folder Space Relink")
        }
    }

    @objc func refreshPhotosLibraryCollectionMenu(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count,
              let source = manager.photos[index].photosLibrarySource else { return }
        let id = manager.photos[index].id
        if source.status.needsRelink {
            PhotosLibraryCollectionPicker.present(
                manager: manager,
                existingWidgetID: id,
                onMenuUpdate: { [weak self] in self?.rebuildMenu() }
            )
            return
        }
        Task { @MainActor in
            let result = await manager.refreshPhotosLibraryCollection(id)
            rebuildMenu()
            ImportBatchPresenter.present(result, title: "Photos Collection Refresh", noun: "asset")
        }
    }

    @objc func removePhotoMenu(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < manager.photos.count else { return }
        let item = manager.photos[index]
        guard RemovalConfirmation.confirm(count: 1, name: manager.label(for: item), origin: .menuBar) else { return }
        manager.removePhoto(item.id)
        rebuildMenu()
    }

    @objc func removeAllPhotos() {
        guard !manager.photos.isEmpty else { return }

        guard RemovalConfirmation.confirm(count: manager.photos.count, all: true, origin: .menuBar) else { return }

        manager.removeAllPhotos()
        rebuildMenu()
    }

    @objc func restoreRemovedWidgets() {
        do {
            try manager.restoreRemovedWidgets()
            rebuildMenu()
        } catch {
            AppDialog.inform(title: "Couldn’t Restore Widgets", message: error.localizedDescription, style: .warning)
        }
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
            title: "Request Exclusion from Screen Captures",
            action: #selector(toggleExcludeFromScreenCapture),
            keyEquivalent: ""
        )
        exclude.target = self
        exclude.state = manager.excludeFromScreenCapture ? .on : .off
        exclude.toolTip = "Asks compatible screenshot and recording tools to omit visible widgets. Modern recorders may still capture them; hide widgets before sharing if they must stay private. AirPlay and HDMI mirroring are not covered."
        submenu.addItem(exclude)

        let conferencing = NSMenuItem(
            title: "Hide While Call or Recording Apps Run",
            action: #selector(toggleAutoHideForConferencing),
            keyEquivalent: ""
        )
        conferencing.target = self
        conferencing.state = manager.autoHideForConferencingApps ? .on : .off
        conferencing.toolTip = "Best effort: hides photos while Zoom, Teams, QuickTime, OBS or Screenshot are running. A running app isn't proof of an active share, and browser calls aren't detectable."
        submenu.addItem(conferencing)

        if manager.isConferencingAppDetected {
            let detected = NSMenuItem(title: "  Call or recording app running", action: nil, keyEquivalent: "")
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
        fullscreen.toolTip = "Hides widgets and pauses playback while a fullscreen-sized app is detected. Detection uses window size; some apps or desktop arrangements may not be recognized."
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
        let alert = AppDialog.make(title: "Choose a PDF Page", message: "This PDF has \(pageCount) pages.",
                                   actions: [.init(title: "Add Page"), .init(title: "Cancel", role: .cancel)])

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
        AppDialog.inform(title: title, message: body)
    }

    @objc func hideMenuBarIcon() {
        hideStatusItem()
        AppDialog.inform(title: "Menu Bar Icon Hidden",
                         message: "To bring it back, open \(Constants.appName) again from your Applications folder or Spotlight.")
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
