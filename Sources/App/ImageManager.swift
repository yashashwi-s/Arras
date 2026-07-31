import AppKit
import SwiftUI
import ServiceManagement

/// Manages multiple desktop photos, persistence, and settings.
@MainActor
class PhotoManager: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var launchAtLogin: Bool = false

    private var windows: [UUID: DesktopPhotoWindow] = [:]

    // v1.4 — Spaces (Internal rotation timers)
    private var spaceImages: [UUID: [URL]] = [:]
    private var rotationTimers: [UUID: DispatchSourceTimer] = [:]

    var storageDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("PhotoWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether this launch has already looked for data left in the sandbox
    /// container. Checked once rather than on every `storageDir` access.
    private static var didMigrateStorage = false

    private var dataFile: URL { storageDir.appendingPathComponent("photos.json") }

    init() {
        // Must run before anything reads photos.json: dropping the sandbox moved
        // the Application Support directory, and this carries older installs across.
        if !Self.didMigrateStorage {
            Self.didMigrateStorage = true
            StorageMigration.migrateIfNeeded(to: storageDir)
        }

        launchAtLogin = SMAppService.mainApp.status == .enabled

        // Listen for window moves
        NotificationCenter.default.addObserver(
            forName: .desktopPhotoMoved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? DesktopPhotoWindow,
                  let id = window.photoId else { return }
            Task { @MainActor [weak self] in
                self?.saveWindowPosition(for: id, frame: window.frame)
            }
        }

        // Save on quit
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveAllPositions()
                self?.persist()
            }
        }

        // v1.5 — Per-Display Profiles: hide/restore photos as monitors connect/disconnect
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }

        // v1.5 — Theme Adaptation: AppleInterfaceThemeChangedNotification is the reliable
        // public signal for Light/Dark switches; there is no KVO-observable AppKit property
        // that fires at the same moment without also firing for unrelated appearance churn.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleThemeChanged()
            }
        }

        // Load saved photos immediately
        loadSaved()
    }

    // MARK: - Persistence

    func loadSaved() {
        guard let data = try? Data(contentsOf: dataFile),
              let items = try? JSONDecoder().decode([PhotoItem].self, from: data) else { return }
        photos = items

        // A photo that was auto-hidden because its display was disconnected stays invisible
        // on relaunch until that display reconnects (window presence == isVisible && !isHiddenForDisplay).
        for item in photos where item.isVisible && !item.isHiddenForDisplay {
            guard let image = loadDisplayImage(for: item) else { continue }
            createWindow(for: item, image: image)
            if !item.spaceImageFilenames.isEmpty {
                setupRotationTimer(for: item)
            }
        }
    }

    /// Resolves the image currently due to be shown for `item` (single photo or the active
    /// frame of a Space), registering Space image URLs as a side effect. Shared by every path
    /// that brings a hidden photo back on screen: manual visibility toggle, load-on-launch, and
    /// display reconnect.
    private func loadDisplayImage(for item: PhotoItem) -> NSImage? {
        if !item.spaceImageFilenames.isEmpty {
            let urls = item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
            spaceImages[item.id] = urls
            if let imageURL = urls[safe: item.folderImageIndex], let image = NSImage(contentsOf: imageURL) {
                return image
            }
            return urls.first.flatMap { NSImage(contentsOf: $0) }
        } else {
            return NSImage(contentsOf: storageDir.appendingPathComponent(item.filename))
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(photos) else { return }
        try? data.write(to: dataFile, options: .atomic)
    }

    private func saveAllPositions() {
        for (id, window) in windows {
            saveWindowPosition(for: id, frame: window.frame)
        }
    }

    private func saveWindowPosition(for id: UUID, frame: NSRect) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].frameString = NSStringFromRect(frame)
        photos[index].widgetWidth = frame.width

        // Per-Display Profiles: whichever screen the window's center currently sits on becomes
        // its "home" display, and we remember the exact frame for that display independently
        // so restoring after a disconnect/reconnect doesn't depend on the (possibly stale)
        // top-level frameString if the photo was later moved to a different monitor.
        if let screen = windows[id]?.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            let displayId = DisplayManager.identifier(for: screen)
            photos[index].displayIdentifier = displayId
            photos[index].savedDisplayFrames[displayId] = NSStringFromRect(frame)
        }

        // Also save per-image config for space photos if in dynamic mode
        if !photos[index].spaceImageFilenames.isEmpty,
           photos[index].folderSizeMode == "dynamic",
           let images = spaceImages[id] {
            let currentImage = images[safe: photos[index].folderImageIndex]
            if let key = currentImage?.lastPathComponent {
                photos[index].folderImageConfigs[key] = FolderImageConfig(
                    frameString: NSStringFromRect(frame),
                    widgetWidth: frame.width
                )
            }
        }

        persist()
    }

    // MARK: - Add / Remove

    func addPhoto(_ image: NSImage) {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            return
        }

        let filename = UUID().uuidString + ".jpg"
        try? jpegData.write(to: storageDir.appendingPathComponent(filename))

        let item = PhotoItem(filename: filename)
        photos.append(item)
        createWindow(for: item, image: image)
        persist()
    }

    func addSpace(images: [NSImage]) {
        guard !images.isEmpty else { return }

        // Save all images to disk and collect filenames
        var filenames: [String] = []
        for image in images {
            if let tiffData = image.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                let filename = UUID().uuidString + ".jpg"
                let url = storageDir.appendingPathComponent(filename)
                do {
                    try jpegData.write(to: url)
                    filenames.append(filename)
                } catch {
                    print("Failed to save image: \(error)")
                }
            }
        }
        guard !filenames.isEmpty else { return }

        // Create one PhotoItem to represent the Space
        var item = PhotoItem(filename: "")
        item.customName = "Space"
        item.spaceImageFilenames = filenames
        item.rotationInterval = "30s"
        item.folderSizeMode = "dynamic" // Ensure default size mode is set
        photos.append(item)

        let urls = filenames.map { storageDir.appendingPathComponent($0) }
        spaceImages[item.id] = urls

        // Display the first image
        if let firstURL = urls.first, let firstImage = NSImage(contentsOf: firstURL) {
            createWindow(for: item, image: firstImage)
            setupRotationTimer(for: item)
        }
    }

    func appendPhotosToSpace(_ id: UUID, images: [NSImage]) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        guard !images.isEmpty else { return }

        var newFilenames: [String] = []
        for image in images {
            if let tiffData = image.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                let filename = UUID().uuidString + ".jpg"
                let url = storageDir.appendingPathComponent(filename)
                do {
                    try jpegData.write(to: url)
                    newFilenames.append(filename)
                } catch {
                    print("Failed to save image: \(error)")
                }
            }
        }
        guard !newFilenames.isEmpty else { return }

        photos[index].spaceImageFilenames.append(contentsOf: newFilenames)
        
        let newUrls = newFilenames.map { storageDir.appendingPathComponent($0) }
        var currentUrls = spaceImages[id] ?? []
        currentUrls.append(contentsOf: newUrls)
        spaceImages[id] = currentUrls
        
        persist()
    }

    func removePhoto(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let item = photos[index]

        windows[id]?.hidePhoto()
        windows.removeValue(forKey: id)

        spaceImages.removeValue(forKey: id)
        rotationTimers[id]?.cancel()
        rotationTimers.removeValue(forKey: id)

        // Delete all files
        if !item.spaceImageFilenames.isEmpty {
            for filename in item.spaceImageFilenames {
                try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(filename))
            }
        } else {
            try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(item.filename))
        }
        
        photos.remove(at: index)
        persist()
    }

    func removeAllPhotos() {
        let ids = photos.map { $0.id }
        for id in ids { removePhoto(id) }
    }

    /// Shows every photo, or hides every photo if any are currently showing.
    ///
    /// Biased toward hiding so the global hotkey behaves like a "get out of the
    /// way" key: one press always clears the desktop, the next restores it.
    /// - Returns: true if photos are visible after the toggle.
    @discardableResult
    func toggleAllVisibility() -> Bool {
        guard !photos.isEmpty else { return false }

        let anyVisible = photos.contains { $0.isVisible }
        let target = !anyVisible

        for photo in photos where photo.isVisible != target {
            toggleVisibility(photo.id)
        }
        return target
    }

    /// Appends a fully-formed item (e.g. from an imported `.tableau` layout bundle) and,
    /// if visible, creates its window. Image/space files must already be written into
    /// `storageDir` under the names in `item.filename` / `item.spaceImageFilenames`.
    /// Kept separate from `addPhoto`/`addSpace` since those synthesize a brand-new item
    /// from an `NSImage` rather than restoring one that already carries saved settings.
    func addImportedItem(_ item: PhotoItem) {
        photos.append(item)
        guard item.isVisible else { persist(); return }

        if !item.spaceImageFilenames.isEmpty {
            let urls = item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
            spaceImages[item.id] = urls
            if let imageURL = urls[safe: item.folderImageIndex] ?? urls.first,
               let image = NSImage(contentsOf: imageURL) {
                createWindow(for: item, image: image)
            }
            setupRotationTimer(for: item)
        } else if let image = NSImage(contentsOf: storageDir.appendingPathComponent(item.filename)) {
            createWindow(for: item, image: image)
        }
        persist()
    }

    // MARK: - Window Creation

    private func createWindow(for item: PhotoItem, image: NSImage) {
        let window = DesktopPhotoWindow()
        window.isReleasedWhenClosed = false
        window.photoId = item.id
        window.showPhoto(image, baseWidth: item.widgetWidth, locked: item.isLocked, settings: item)

        // Restore saved position
        var targetFrame: NSRect? = nil
        if item.folderSizeMode == "dynamic", !item.spaceImageFilenames.isEmpty, let images = spaceImages[item.id] {
            let currentImage = images[safe: item.folderImageIndex]
            if let key = currentImage?.lastPathComponent, let cfg = item.folderImageConfigs[key] {
                targetFrame = NSRectFromString(cfg.frameString)
            }
        }
        
        let fallbackRect = NSRectFromString(item.frameString)
        var rectToUse = targetFrame ?? fallbackRect
        if rectToUse.width > 0 {
            rectToUse = clampToVisibleScreens(rectToUse)
        }

        if rectToUse.width > 0 {
            window.setFrame(rectToUse, display: true)
            (window.contentView as? DraggablePhotoView)?.updateLayout(rectToUse.size)
        }

        window.setSpaceBound(item.isSpaceBound)

        // Per-Display Profiles: record which physical display this window landed on so it can
        // be hidden/restored correctly if that display is unplugged later. Runs on every
        // createWindow call (not just first-time placement) so a photo dragged onto a new
        // monitor picks up the new "home" the next time it needs to be re-created.
        if let idx = photos.firstIndex(where: { $0.id == item.id }),
           let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(rectToUse) }) ?? NSScreen.main {
            photos[idx].displayIdentifier = DisplayManager.identifier(for: screen)
        }

        if item.themeAdaptive {
            applyThemeAdaptation(item)
        }

        // Callbacks
        window.onLockToggle = { [weak self] in self?.toggleLock(item.id) }
        window.onRemove = { [weak self] in self?.removePhoto(item.id) }
        window.onResize = { [weak self] newWidth in
            guard let self, let i = self.photos.firstIndex(where: { $0.id == item.id }) else { return }
            self.photos[i].widgetWidth = newWidth
            self.persist()
        }
        window.onOpacityChanged = { [weak self] newOpacity in
            guard let self, let i = self.photos.firstIndex(where: { $0.id == item.id }) else { return }
            self.photos[i].opacity = newOpacity
            self.persist()
        }

        // Click-to-advance for folder photos
        window.onClickAdvance = { [weak self] in
            guard let self else { return }
            if let idx = self.photos.firstIndex(where: { $0.id == item.id }),
               !self.photos[idx].spaceImageFilenames.isEmpty,
               self.photos[idx].rotationInterval == "click" {
                self.nextFolderImage(item.id)
            }
        }
        // Also wire it on the view
        (window.contentView as? DraggablePhotoView)?.onClickAdvance = window.onClickAdvance

        windows[item.id] = window
    }

    // MARK: - v1.1 Controls

    func setFloating(_ id: UUID, _ floating: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].isFloating = floating
        windows[id]?.setFloating(floating)
        
        if !floating {
        }
        
        persist()
    }

    func setOpacity(_ id: UUID, _ value: CGFloat) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].opacity = max(0.1, min(1.0, value))
        windows[id]?.setPhotoOpacity(photos[index].opacity)
        persist()
    }

    func toggleLock(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].isLocked.toggle()
        let locked = photos[index].isLocked

        windows[id]?.setLocked(locked)
        (windows[id]?.contentView as? DraggablePhotoView)?.flashLockState(locked)
        persist()
    }

    func toggleVisibility(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].isVisible.toggle()

        if photos[index].isVisible {
            // A manual "Show" always wins over the display-disconnect auto-hide — otherwise a
            // photo whose monitor never comes back would be permanently unreachable from the UI.
            photos[index].isHiddenForDisplay = false
            let item = photos[index]
            if let image = loadDisplayImage(for: item) {
                createWindow(for: item, image: image)
            }
            if !item.spaceImageFilenames.isEmpty {
                setupRotationTimer(for: item)
            }
        } else {
            windows[id]?.hidePhoto()
            windows.removeValue(forKey: id)
            rotationTimers[id]?.cancel()
            rotationTimers.removeValue(forKey: id)
        }
        persist()
    }

    func resize(_ id: UUID, to width: CGFloat) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].widgetWidth = width
        windows[id]?.resizeTo(width: width)
        persist()
    }

    // MARK: - v1.2 Naming & Organization

    func renamePhoto(_ id: UUID, to name: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].customName = name.isEmpty ? nil : name
        persist()
    }

    func replacePhoto(_ id: UUID, with newImage: NSImage) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let item = photos[index]

        // Only replace file for single-image photos
        if item.spaceImageFilenames.isEmpty {
            guard let tiffData = newImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
            try? jpegData.write(to: storageDir.appendingPathComponent(item.filename))
        }

        // Refresh window with crossfade
        windows[id]?.swapImage(newImage, animate: true)
        persist()
    }

    func duplicatePhoto(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let original = photos[index]

        if !original.spaceImageFilenames.isEmpty {
            // Duplicate folder photo — just copy the settings
            var newItem = PhotoItem(filename: "")
            newItem.customName = (original.customName ?? "Photo") + " (Copy)"
            newItem.spaceImageFilenames = original.spaceImageFilenames
            newItem.rotationInterval = original.rotationInterval
            newItem.folderImageIndex = original.folderImageIndex
            newItem.widgetWidth = original.widgetWidth
            copyAppearanceSettings(from: original, to: &newItem)

            // Offset position
            if !original.frameString.isEmpty {
                var rect = NSRectFromString(original.frameString)
                rect.origin.x += 30
                rect.origin.y -= 30
                newItem.frameString = NSStringFromRect(rect)
            }

            photos.append(newItem)

            if let images = spaceImages[original.id],
               let imageURL = images[safe: newItem.folderImageIndex],
               let image = NSImage(contentsOf: imageURL) {
                spaceImages[newItem.id] = images
                createWindow(for: newItem, image: image)
                setupRotationTimer(for: newItem)
            }
        } else {
            // Copy the file
            let newFilename = UUID().uuidString + ".jpg"
            let srcURL = storageDir.appendingPathComponent(original.filename)
            let dstURL = storageDir.appendingPathComponent(newFilename)
            try? FileManager.default.copyItem(at: srcURL, to: dstURL)

            var newItem = PhotoItem(filename: newFilename, width: original.widgetWidth)
            newItem.customName = (original.customName ?? "Photo") + " (Copy)"
            copyAppearanceSettings(from: original, to: &newItem)

            // Offset position
            if !original.frameString.isEmpty {
                var rect = NSRectFromString(original.frameString)
                rect.origin.x += 30
                rect.origin.y -= 30
                newItem.frameString = NSStringFromRect(rect)
            }

            photos.append(newItem)

            if let image = NSImage(contentsOf: dstURL) {
                createWindow(for: newItem, image: image)
            }
        }

        persist()
    }

    func movePhoto(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < photos.count,
              destinationIndex >= 0, destinationIndex < photos.count else { return }
        let item = photos.remove(at: sourceIndex)
        photos.insert(item, at: destinationIndex)
        persist()
    }

    private func copyAppearanceSettings(from src: PhotoItem, to dst: inout PhotoItem) {
        dst.isFloating = src.isFloating
        dst.opacity = src.opacity
        dst.cornerRadius = src.cornerRadius
        dst.shadowEnabled = src.shadowEnabled
        dst.shadowBlur = src.shadowBlur
        dst.shadowOpacity = src.shadowOpacity
        dst.borderWidth = src.borderWidth
        dst.borderColorHex = src.borderColorHex
        dst.vignetteEnabled = src.vignetteEnabled
        dst.isSpaceBound = src.isSpaceBound
        dst.themeAdaptive = src.themeAdaptive
        // displayIdentifier / savedDisplayFrames / isHiddenForDisplay intentionally not copied —
        // the duplicate gets its own window and should pick up its own home display from
        // wherever createWindow actually places it.
    }

    // MARK: - v1.3 Aesthetic Controls

    func setCornerRadius(_ id: UUID, _ value: CGFloat) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].cornerRadius = value
        (windows[id]?.contentView as? DraggablePhotoView)?.setCornerRadius(value)
        persist()
    }

    func setShadow(_ id: UUID, enabled: Bool, blur: CGFloat, opacity: CGFloat) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].shadowEnabled = enabled
        photos[index].shadowBlur = blur
        photos[index].shadowOpacity = opacity
        windows[id]?.applyShadowSettings(enabled: enabled, blur: blur, opacity: opacity)
        persist()
    }

    func setBorder(_ id: UUID, width: CGFloat, colorHex: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].borderWidth = width
        photos[index].borderColorHex = colorHex
        let color = NSColor.fromHex(colorHex) ?? .white
        (windows[id]?.contentView as? DraggablePhotoView)?.applyBorder(width: width, color: color)
        persist()
    }

    func setVignette(_ id: UUID, enabled: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].vignetteEnabled = enabled
        if enabled {
            (windows[id]?.contentView as? DraggablePhotoView)?.applyVignette()
        } else {
            (windows[id]?.contentView as? DraggablePhotoView)?.removeVignette()
        }
        persist()
    }

    // MARK: - v1.4 Smart Canvas





    func nextFolderImage(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              photos[index].isVisible,
              let images = spaceImages[id], !images.isEmpty else { return }

        let item = photos[index]

        if item.folderSizeMode == "dynamic" {
            saveFolderImageConfig(for: id)
        }

        // Advance
        photos[index].folderImageIndex = (photos[index].folderImageIndex + 1) % images.count
        let imageURL = images[photos[index].folderImageIndex]

        if let image = NSImage(contentsOf: imageURL) {
            let key = imageURL.lastPathComponent
            let targetFrame = item.folderImageConfigs[key].map { NSRectFromString($0.frameString) }
            windows[id]?.swapImage(image, targetFrame: targetFrame, mode: item.folderSizeMode, animate: true)
        }
        persist()
    }

    func prevFolderImage(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              let images = spaceImages[id], !images.isEmpty else { return }

        let item = photos[index]

        if item.folderSizeMode == "dynamic" {
            saveFolderImageConfig(for: id)
        }

        // Go back
        let currentIndex = photos[index].folderImageIndex
        photos[index].folderImageIndex = currentIndex > 0 ? currentIndex - 1 : images.count - 1
        let imageURL = images[photos[index].folderImageIndex]

        if let image = NSImage(contentsOf: imageURL) {
            let key = imageURL.lastPathComponent
            let targetFrame = item.folderImageConfigs[key].map { NSRectFromString($0.frameString) }
            windows[id]?.swapImage(image, targetFrame: targetFrame, mode: item.folderSizeMode, animate: true)
        }
        persist()
    }

    func setRotationInterval(_ id: UUID, _ interval: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].rotationInterval = interval
        rotationTimers[id]?.cancel()
        rotationTimers.removeValue(forKey: id)
        setupRotationTimer(for: photos[index])
        persist()
    }

    func setCustomRotationSeconds(_ id: UUID, _ seconds: Int) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].customRotationSeconds = max(5, seconds)  // minimum 5 seconds
        // Restart timer if currently on custom
        if photos[index].rotationInterval == "custom" {
            rotationTimers[id]?.cancel()
            rotationTimers.removeValue(forKey: id)
            setupRotationTimer(for: photos[index])
        }
        persist()
    }

    func setFolderSizeMode(_ id: UUID, _ mode: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let oldMode = photos[index].folderSizeMode
        photos[index].folderSizeMode = mode

        if oldMode == "dynamic" && mode == "fixed" {
            // We just switched to fixed. Update the frameString to current frame so all images use it.
            if let window = windows[id] {
                photos[index].frameString = NSStringFromRect(window.frame)
                photos[index].widgetWidth = window.frame.width
            }
        }

        // Trigger an immediate swap so the window resizes or adapts to the new mode
        if let images = spaceImages[id], !images.isEmpty {
            let imageURL = images[photos[index].folderImageIndex]
            if let image = NSImage(contentsOf: imageURL) {
                let key = imageURL.lastPathComponent
                let targetFrame = photos[index].folderImageConfigs[key].map { NSRectFromString($0.frameString) }
                windows[id]?.swapImage(image, targetFrame: targetFrame, mode: mode, animate: true)
            }
        }
        persist()
    }

    func folderImageCount(_ id: UUID) -> Int {
        spaceImages[id]?.count ?? 0
    }



    private func setupRotationTimer(for item: PhotoItem) {
        let interval: TimeInterval?
        switch item.rotationInterval {
        case "30s":    interval = 30
        case "5m":     interval = 300
        case "hourly": interval = 3600
        case "daily":  interval = 86400
        case "custom": interval = TimeInterval(max(5, item.customRotationSeconds))
        default:       interval = nil   // "click" doesn't use timers
        }

        guard let seconds = interval else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in
            self?.nextFolderImage(item.id)
        }
        timer.resume()
        rotationTimers[item.id] = timer
    }

    /// Save the current window position/size for the currently displayed folder image.
    private func saveFolderImageConfig(for id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              let images = spaceImages[id],
              let window = windows[id] else { return }
        let currentImage = images[safe: photos[index].folderImageIndex]
        if let key = currentImage?.lastPathComponent {
            photos[index].folderImageConfigs[key] = FolderImageConfig(
                frameString: NSStringFromRect(window.frame),
                widgetWidth: window.frame.width
            )
        }
    }

    // MARK: - v1.5 Per-Display Profiles

    /// Ensures a saved frame is still reachable. Display geometry can shift between sessions
    /// (different arrangement, different resolution/scale), and a frame computed for a display
    /// that's since been swapped for a different physical unit sharing the same identifier
    /// fallback could in principle land fully off-screen — better to snap it back onto a
    /// visible screen than let the user lose track of a widget they can't see or drag back.
    private func clampToVisibleScreens(_ rect: NSRect) -> NSRect {
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(rect) }),
              let target = NSScreen.main ?? NSScreen.screens.first else { return rect }
        var clamped = rect
        clamped.origin.x = target.frame.midX - rect.width / 2
        clamped.origin.y = target.frame.midY - rect.height / 2
        return clamped
    }

    private func handleScreenParametersChanged() {
        let diff = DisplayManager.shared.diffScreens()
        guard !diff.connected.isEmpty || !diff.disconnected.isEmpty else { return }

        // Hide photos whose home display just vanished, remembering exactly where they were.
        if !diff.disconnected.isEmpty {
            for index in photos.indices {
                guard photos[index].isVisible, !photos[index].isHiddenForDisplay,
                      let displayId = photos[index].displayIdentifier,
                      diff.disconnected.contains(displayId) else { continue }

                let id = photos[index].id
                if let window = windows[id] {
                    photos[index].savedDisplayFrames[displayId] = NSStringFromRect(window.frame)
                    window.hidePhoto()
                    windows.removeValue(forKey: id)
                }
                rotationTimers[id]?.cancel()
                rotationTimers.removeValue(forKey: id)
                photos[index].isHiddenForDisplay = true
            }
        }

        // Restore photos whose home display just reappeared.
        if !diff.connected.isEmpty {
            for index in photos.indices {
                guard photos[index].isVisible, photos[index].isHiddenForDisplay,
                      let displayId = photos[index].displayIdentifier,
                      diff.connected.contains(displayId) else { continue }

                photos[index].isHiddenForDisplay = false
                if let savedFrame = photos[index].savedDisplayFrames[displayId] {
                    let rect = clampToVisibleScreens(NSRectFromString(savedFrame))
                    photos[index].frameString = NSStringFromRect(rect)
                }

                let item = photos[index]
                guard let image = loadDisplayImage(for: item) else { continue }
                createWindow(for: item, image: image)
                if !item.spaceImageFilenames.isEmpty {
                    setupRotationTimer(for: item)
                }
            }
        }

        persist()
    }

    // MARK: - v1.5 Space Binding

    /// Space binding is best-effort: see the comment on `DesktopPhotoWindow.setSpaceBound` —
    /// there's no public API to target a specific Space by identity, so this pins the photo to
    /// whichever Space it's on right now rather than a persistent Space #N.
    func setSpaceBound(_ id: UUID, _ bound: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].isSpaceBound = bound
        windows[id]?.setSpaceBound(bound)
        persist()
    }

    // MARK: - v1.5 Theme Adaptation

    private func isDarkMode() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Applies a contrast nudge on top of the photo's stored (light-mode-authored) appearance
    /// settings without mutating them, so switching back to Light Mode — or turning theme
    /// adaptation off — exactly restores what the user actually configured. Dark desktops tend
    /// to swallow soft shadows and pale borders, so Dark Mode gets a stronger shadow and a
    /// border blended toward white; Light Mode is a no-op pass-through of the stored values.
    private func applyThemeAdaptation(_ item: PhotoItem) {
        guard item.themeAdaptive, let window = windows[item.id] else { return }
        let dark = isDarkMode()
        let shadowOpacity = dark ? min(item.shadowOpacity + 0.15, 0.6) : item.shadowOpacity
        let borderColor = dark
            ? (item.borderColor.blended(withFraction: 0.25, of: .white) ?? item.borderColor)
            : item.borderColor

        window.applyShadowSettings(enabled: item.shadowEnabled, blur: item.shadowBlur, opacity: shadowOpacity)
        (window.contentView as? DraggablePhotoView)?.applyBorder(width: item.borderWidth, color: borderColor)
    }

    /// Reverts a window to exactly its stored (non-adapted) appearance settings.
    private func applyStoredAppearance(_ item: PhotoItem) {
        guard let window = windows[item.id] else { return }
        window.applyShadowSettings(enabled: item.shadowEnabled, blur: item.shadowBlur, opacity: item.shadowOpacity)
        (window.contentView as? DraggablePhotoView)?.applyBorder(width: item.borderWidth, color: item.borderColor)
    }

    func setThemeAdaptive(_ id: UUID, _ enabled: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].themeAdaptive = enabled
        if enabled {
            applyThemeAdaptation(photos[index])
        } else {
            applyStoredAppearance(photos[index])
        }
        persist()
    }

    private func handleThemeChanged() {
        for item in photos where item.themeAdaptive {
            applyThemeAdaptation(item)
        }
    }

    // MARK: - App Controls

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            print("Launch at login error: \(error)")
        }
    }

    /// Returns a small thumbnail for UI display.
    func thumbnail(for item: PhotoItem, size: CGFloat = 48) -> NSImage? {
        let image: NSImage?
        if !item.spaceImageFilenames.isEmpty {
            let images = spaceImages[item.id] ?? item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
            if let imageURL = images[safe: item.folderImageIndex] {
                image = NSImage(contentsOf: imageURL)
            } else {
                image = images.first.flatMap { NSImage(contentsOf: $0) }
            }
        } else {
            let url = storageDir.appendingPathComponent(item.filename)
            image = NSImage(contentsOf: url)
        }

        guard let sourceImage = image else { return nil }

        let thumb = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let ar = sourceImage.size.width / sourceImage.size.height
            let drawRect: NSRect
            if ar > 1 {
                let h = size / ar
                drawRect = NSRect(x: 0, y: (size - h) / 2, width: size, height: h)
            } else {
                let w = size * ar
                drawRect = NSRect(x: (size - w) / 2, y: 0, width: w, height: size)
            }
            sourceImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        return thumb
    }

    /// Label for a photo.
    func label(for item: PhotoItem) -> String {
        if let name = item.customName, !name.isEmpty {
            return name
        }
        guard let index = photos.firstIndex(where: { $0.id == item.id }) else { return "Photo" }
        return "Photo \(index + 1)"
    }
}

// MARK: - Safe Array Access

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
