import AppKit
import Photos
import UniformTypeIdentifiers

// Acquisition, authorization, native chooser, and reconciliation live here.
// Codable metadata and snapshot policy live in PhotosLibraryModels.swift.

enum PhotosLibraryAuthorization {
    static var status: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestIfNeeded(
        allowPrompt: Bool = true,
        currentStatus: () -> PHAuthorizationStatus = { status },
        request: () async -> PHAuthorizationStatus = { await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
    ) async -> PHAuthorizationStatus {
        let current = currentStatus()
        guard current == .notDetermined, allowPrompt else { return current }
        // PhotoKit exposes this callback as a native async API on macOS 11+. Keeping the
        // authorization hop async avoids retaining a continuation across an arbitrary callback
        // queue and keeps the chooser's explicit request on the main actor's structured path.
        return await request()
    }

    static func isUsable(_ status: PHAuthorizationStatus) -> Bool {
        // macOS exposes read/write authorization as authorized, denied, or restricted. The
        // limited status is an iOS-only PhotoKit case and is intentionally not referenced here so
        // the macOS target remains available across the supported SDKs.
        status == .authorized
    }
}

enum PhotosPermissionRecovery {
    enum Action: Equatable {
        case openSettings
        case explainRestriction
        case none
    }

    static func action(for status: PHAuthorizationStatus) -> Action {
        switch status {
        case .denied: return .openSettings
        case .restricted: return .explainRestriction
        default: return .none
        }
    }

    @MainActor
    static func present(for status: PHAuthorizationStatus) {
        switch action(for: status) {
        case .openSettings:
            let alert = AppDialog.make(
                title: "Photos Access Unavailable",
                message: "macOS reports no Photos access for this copy of \(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent). Allow this app in Privacy & Security → Photos, then try again. If access is already on, quit and reopen this same copy. Saved photos stay available.",
                actions: [.init(title: "Open Photos Settings"), .init(title: "Cancel", role: .cancel)]
            )
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                openSystemSettings()
            }
        case .explainRestriction:
            AppDialog.inform(title: "Photos Access Is Restricted",
                             message: "An administrator or Screen Time setting must allow Photos access on this Mac. Your saved photos stay available.", style: .warning)
        case .none:
            return
        }
    }

    @MainActor
    static func openSystemSettings(open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        PrivacySettingsPane.photos.open(using: open)
    }
}

enum PhotosLibraryAssetExportError: LocalizedError {
    case noResource
    case unavailable(String)
    case sizeLimit(Int64)

    var errorDescription: String? {
        switch self {
        case .noResource: return "Photos did not provide a downloadable resource for this asset."
        case .unavailable(let detail): return detail
        case .sizeLimit(let bytes):
            return "This Photos asset exceeds the \(bytes / (1024 * 1024)) MB managed snapshot limit."
        }
    }
}

@MainActor
private final class PhotosDownloadProgressLease {
    var isActive = true
}

private struct ExportedPhotosAsset: Sendable {
    let descriptor: PhotosAssetDescriptor
    let originalName: String
    let stillData: Data?
    let pairedVideoData: Data?
    let videoData: Data?
    let videoExtension: String?
    let resourceTypes: [Int]
}

enum PhotosLibraryResourcePolicy {
    static func photoIndex(in types: [PHAssetResourceType]) -> Int? {
        types.firstIndex(of: .fullSizePhoto) ?? types.firstIndex(of: .photo) ?? types.firstIndex(of: .alternatePhoto)
    }

    static func videoIndex(in types: [PHAssetResourceType]) -> Int? {
        types.firstIndex(of: .fullSizeVideo) ?? types.firstIndex(of: .video)
    }

    static func pairedVideoIndex(in types: [PHAssetResourceType]) -> Int? {
        types.firstIndex(of: .fullSizePairedVideo) ?? types.firstIndex(of: .adjustmentBasePairedVideo)
    }

    static func selectedTypes(for kind: PhotoMediaKind, in types: [PHAssetResourceType]) -> [Int]? {
        if kind == .livePhoto {
            guard let still = photoIndex(in: types), let paired = pairedVideoIndex(in: types) else { return nil }
            return [types[still].rawValue, types[paired].rawValue]
        }
        guard let primary = kind == .video ? videoIndex(in: types) : photoIndex(in: types) else { return nil }
        return [types[primary].rawValue]
    }
}

/// Public-API-only Photos bridge. It prefers Photos' edited resources when provided,
/// with network access enabled for iCloud assets, without introducing PHLivePhotoView or a
/// Photos UI dependency into the renderer.
private enum PhotosLibraryAssetExporter {
    static func descriptor(for asset: PHAsset) -> PhotosAssetDescriptor {
        // `photoLive` is iOS-only in the macOS PhotoKit SDK. On macOS, the public paired-resource
        // API exposes a Live Photo's movie as a full-size paired video instead.
        let isLive = asset.mediaType == .image && PHAssetResource.assetResources(for: asset).contains {
            $0.type == .fullSizePairedVideo || $0.type == .adjustmentBasePairedVideo
        }
        let kind: PhotoMediaKind
        if isLive {
            kind = .livePhoto
        } else if asset.mediaType == .video {
            kind = .video
        } else {
            kind = .still
        }
        let name = asset.localIdentifier.isEmpty ? "Photos asset" : asset.localIdentifier
        return PhotosAssetDescriptor(
            localIdentifier: asset.localIdentifier,
            displayName: name,
            mediaKind: kind,
            modificationDate: asset.modificationDate,
            estimatedBytes: 0
        )
    }

    static func export(
        asset: PHAsset,
        allowNetwork: Bool,
        maxBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportedPhotosAsset {
        let descriptor = descriptor(for: asset)
        let resources = PHAssetResource.assetResources(for: asset)
        let resourceTypes = resources.map(\.type)
        guard !resources.isEmpty else { throw PhotosLibraryAssetExportError.noResource }

        if descriptor.mediaKind == .livePhoto {
            guard let stillIndex = PhotosLibraryResourcePolicy.photoIndex(in: resourceTypes),
                  let pairedIndex = PhotosLibraryResourcePolicy.pairedVideoIndex(in: resourceTypes) else {
                throw PhotosLibraryAssetExportError.unavailable("This Live Photo has no still or paired movie resource.")
            }
            let still = resources[stillIndex]
            let paired = resources[pairedIndex]
            let stillData = try await data(
                for: still,
                allowNetwork: allowNetwork,
                maxBytes: maxBytes,
                progress: { progress($0 * 0.5) }
            )
            let remainingBytes = maxBytes - Int64(stillData.count)
            guard remainingBytes > 0 else { throw PhotosLibraryAssetExportError.sizeLimit(maxBytes) }
            let pairedData = try await data(
                for: paired,
                allowNetwork: allowNetwork,
                maxBytes: remainingBytes,
                progress: { progress(0.5 + $0 * 0.5) }
            )
            return ExportedPhotosAsset(
                descriptor: descriptor,
                originalName: still.originalFilename,
                stillData: stillData,
                pairedVideoData: pairedData,
                videoData: nil,
                videoExtension: nil,
                resourceTypes: [still.type.rawValue, paired.type.rawValue]
            )
        }

        if descriptor.mediaKind == .video {
            guard PhotosLibraryCollectionPolicy.allowMutedVideoAssets,
                  let videoIndex = PhotosLibraryResourcePolicy.videoIndex(in: resourceTypes) else {
                throw PhotosLibraryAssetExportError.unavailable("This video asset has no playable movie resource.")
            }
            let video = resources[videoIndex]
            let data = try await data(
                for: video,
                allowNetwork: allowNetwork,
                maxBytes: maxBytes,
                progress: progress
            )
            let extensionFromResource = UTType(video.uniformTypeIdentifier)?.preferredFilenameExtension
                ?? (video.originalFilename as NSString).pathExtension
            return ExportedPhotosAsset(
                descriptor: descriptor,
                originalName: video.originalFilename,
                stillData: nil,
                pairedVideoData: nil,
                videoData: data,
                videoExtension: extensionFromResource.isEmpty ? "mov" : extensionFromResource,
                resourceTypes: [video.type.rawValue]
            )
        }

        guard let stillIndex = PhotosLibraryResourcePolicy.photoIndex(in: resourceTypes) else {
            throw PhotosLibraryAssetExportError.noResource
        }
        let still = resources[stillIndex]
        let data = try await data(
            for: still,
            allowNetwork: allowNetwork,
            maxBytes: maxBytes,
            progress: progress
        )
        return ExportedPhotosAsset(
            descriptor: descriptor,
            originalName: still.originalFilename,
            stillData: data,
            pairedVideoData: nil,
            videoData: nil,
            videoExtension: nil,
            resourceTypes: [still.type.rawValue]
        )
    }

    private static func data(
        for resource: PHAssetResource,
        allowNetwork: Bool,
        maxBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        guard maxBytes > 0 else { throw PhotosLibraryAssetExportError.sizeLimit(maxBytes) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.progressHandler = { value in
            progress(max(0, min(1, Double(value))))
        }

        return try await PhotosResourceTransfer.read(maxBytes: maxBytes) { receive, finish in
            let manager = PHAssetResourceManager.default()
            let requestID = manager.requestData(for: resource, options: options,
                                                dataReceivedHandler: receive, completionHandler: finish)
            return { manager.cancelDataRequest(requestID) }
        }
    }
}

// MARK: - Accessible native collection chooser

final class PhotosLibraryCollectionChooserView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let collections: [PhotosLibraryCollectionSelection]
    private let table = NSTableView()
    private let search = NSSearchField()
    private var filtered: [PhotosLibraryCollectionSelection]
    var onSelectionChange: ((Bool) -> Void)?
    private(set) var selectedCollection: PhotosLibraryCollectionSelection?

    init(collections: [PhotosLibraryCollectionSelection]) {
        self.collections = collections
        self.filtered = collections
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 300))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("photos-collection-column"))
        column.title = "Photos collection"
        column.width = 430
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 40
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.identifier = NSUserInterfaceItemIdentifier("photos-collection-table")
        table.setAccessibilityLabel("Photos collections")
        table.setAccessibilityHelp("Select an album, smart album, or shared album to keep synchronized")

        let scroll = NSScrollView(frame: bounds)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.hasHorizontalScroller = false
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Find an album"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Find a Photos album")
        search.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: leadingAnchor),
            search.trailingAnchor.constraint(equalTo: trailingAnchor),
            search.topAnchor.constraint(equalTo: topAnchor),
            search.heightAnchor.constraint(equalToConstant: 26),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if !collections.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selectedCollection = collections[0]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func controlTextDidChange(_ notification: Notification) {
        filterAlbums(search.stringValue)
    }

    func filterAlbums(_ query: String) {
        let previousID = selectedCollection?.id
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = collections.filter { query.isEmpty || $0.displayName.localizedStandardContains(query) }
        table.reloadData()
        if let index = filtered.firstIndex(where: { $0.id == previousID }) ?? (filtered.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            selectedCollection = filtered[index]
        } else {
            selectedCollection = nil
        }
        onSelectionChange?(selectedCollection != nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let collection = filtered[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: collection.displayName)
        let detail = NSTextField(labelWithString: "\(collection.collectionType.displayName) · \(collection.assetCount) items")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for field in [title, detail] {
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
        }
        cell.textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        ])
        cell.setAccessibilityElement(true)
        cell.setAccessibilityLabel("\(collection.displayName), \(collection.collectionType.displayName), \(collection.assetCount) items")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        selectedCollection = filtered.indices.contains(row) ? filtered[row] : nil
        onSelectionChange?(selectedCollection != nil)
    }

}

@MainActor
private final class PhotosAlbumPickerController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let chooser: PhotosLibraryCollectionChooserView
    private(set) var acceptedSelection: PhotosLibraryCollectionSelection?

    init(collections: [PhotosLibraryCollectionSelection], relinking: Bool) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 410),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        chooser = PhotosLibraryCollectionChooserView(collections: collections)
        super.init()
        panel.title = relinking ? "Relink Photos Album" : "Choose a Photos Album"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let content = NSView()
        panel.contentView = content
        let explanation = NSTextField(wrappingLabelWithString: "Choose an album for a slideshow that stays in sync with Photos.")
        explanation.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        cancel.keyEquivalent = "\u{1b}"
        let sync = NSButton(title: "Sync Album", target: self, action: #selector(syncSelection))
        sync.keyEquivalent = "\r"
        sync.isEnabled = chooser.selectedCollection != nil
        chooser.onSelectionChange = { [weak sync] valid in sync?.isEnabled = valid }
        for button in [cancel, sync] { button.bezelStyle = .rounded }
        for view in [explanation, chooser, cancel, sync] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            explanation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            explanation.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            chooser.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 14),
            chooser.leadingAnchor.constraint(equalTo: explanation.leadingAnchor),
            chooser.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            chooser.bottomAnchor.constraint(equalTo: sync.topAnchor, constant: -18),
            sync.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            sync.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: sync.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: sync.centerYAnchor)
        ])
    }

    @objc private func syncSelection() {
        guard let selection = chooser.selectedCollection else { return }
        // Freeze the action's value before ending modal tracking. Table/view
        // callbacks can change selection before runModal returns to its caller.
        acceptedSelection = selection
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
    }
    @objc private func cancelSelection() {
        acceptedSelection = nil
        NSApp.stopModal(withCode: .alertSecondButtonReturn)
    }
    func windowWillClose(_ notification: Notification) { cancelSelection() }
}

@MainActor
enum PhotosLibraryCollectionPicker {
    static func present(
        manager: PhotoManager,
        existingWidgetID: UUID? = nil,
        onMenuUpdate: (() -> Void)? = nil
    ) {
        Task { @MainActor in
            manager.beginMediaImport()
            defer { manager.endMediaImport() }
            let status = await PhotosLibraryAuthorization.requestIfNeeded()
            guard PhotosLibraryAuthorization.isUsable(status) else {
                PhotosPermissionRecovery.present(for: status)
                return
            }

            let collections = availableCollections()
            guard !collections.isEmpty else {
                presentAlert(
                    title: "No Photos Collections",
                    message: "Photos did not return any Albums, Smart Albums, or Shared Albums to choose.",
                    style: .informational
                )
                return
            }

            guard let selection = chooseCollection(collections, relinking: existingWidgetID != nil) else { return }

            let progress = PhotosLibraryProgressPanel(collectionName: selection.displayName)
            defer { progress.close() }
            let sync = Task { @MainActor in
                if let existingWidgetID {
                    return await manager.relinkPhotosLibraryCollection(
                        existingWidgetID,
                        to: selection,
                        progress: progress.update
                    )
                }
                return await manager.addPhotosLibraryCollection(
                    selection, progress: progress.update
                )
            }
            progress.onCancel = { sync.cancel() }
            progress.show()
            let result = await sync.value
            progress.close()
            onMenuUpdate?()
            guard !sync.isCancelled else { return }
            ImportBatchPresenter.present(result, title: existingWidgetID == nil ? "Photos Collection Import" : "Photos Collection Refresh", noun: "asset")
        }
    }

    /// Finish the modal view lifecycle before suspending for a PhotoKit download.
    /// Returning only value data prevents the chooser's key-view chain from being
    /// torn down by a later async task's autorelease pool.
    static func chooseCollection(_ collections: [PhotosLibraryCollectionSelection], relinking: Bool,
                                 run: @MainActor (NSPanel) -> NSApplication.ModalResponse = { NSApp.runModal(for: $0) }) -> PhotosLibraryCollectionSelection? {
        autoreleasepool {
            let controller = PhotosAlbumPickerController(collections: collections, relinking: relinking)
            let panel = controller.panel
            defer {
                panel.makeFirstResponder(nil)
                panel.orderOut(nil)
                panel.contentView = nil
                panel.delegate = nil
                panel.close()
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            guard run(panel) == .alertFirstButtonReturn else { return nil }
            return controller.acceptedSelection
        }
    }

    private static func availableCollections() -> [PhotosLibraryCollectionSelection] {
        var values: [PhotosLibraryCollectionSelection] = []
        var identifiers = Set<String>()

        func append(_ result: PHFetchResult<PHAssetCollection>, type: PhotosLibraryCollectionType) {
            result.enumerateObjects { collection, _, _ in
                guard !identifiers.contains(collection.localIdentifier) else { return }
                identifiers.insert(collection.localIdentifier)
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                guard type != .smartAlbum || assets.count > 0 else { return }
                values.append(
                    PhotosLibraryCollectionSelection(
                        localIdentifier: collection.localIdentifier,
                        collectionType: collection.assetCollectionSubtype == .albumCloudShared ? .sharedAlbum : type,
                        displayName: collection.localizedTitle ?? type.displayName,
                        assetCount: assets.count
                    )
                )
            }
        }

        append(
            PHAssetCollection.fetchAssetCollections(
                with: .album,
                subtype: .any,
                options: nil
            ),
            type: .userAlbum
        )
        append(
            PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: .any,
                options: nil
            ),
            type: .smartAlbum
        )
        append(
            PHAssetCollection.fetchAssetCollections(
                with: .album,
                subtype: .albumCloudShared,
                options: nil
            ),
            type: .sharedAlbum
        )

        return values.sorted {
            if $0.collectionType == $1.collectionType {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.collectionType.displayName < $1.collectionType.displayName
        }
    }

    private static func presentAlert(title: String, message: String, style: NSAlert.Style) {
        AppDialog.inform(title: title, message: message, style: style)
    }
}

@MainActor
final class PhotosLibraryProgressPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let label: NSTextField
    private let progress: NSProgressIndicator
    private var closed = false
    var onCancel: (() -> Void)?

    init(collectionName: String) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 156),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Syncing Photos"
        // This object owns the panel even if its close button is used mid-download.
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        label = NSTextField(labelWithString: "Preparing \(collectionName)…")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityLabel("Photos sync status")

        progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.setAccessibilityLabel("Photos sync progress")

        super.init()
        panel.delegate = self
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSync))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, progress])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        panel.contentView?.addSubview(cancel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24),
            cancel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            cancel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            cancel.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16)
        ])
    }

    func show() {
        guard !closed else { return }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ state: PhotosLibrarySyncState) {
        guard !closed else { return }
        switch state {
        case .authorizing:
            label.stringValue = "Requesting Photos access…"
            progress.doubleValue = 0
        case .syncing(_, let completed, let total, let fraction, let message):
            label.stringValue = total > 0 ? "\(message) \(completed) of \(total)" : message
            progress.doubleValue = max(0, min(1, (Double(completed) + fraction) / max(1, Double(total))))
        case .failed(let message):
            label.stringValue = message
        case .idle:
            break
        }
        label.setAccessibilityValue(label.stringValue)
        progress.setAccessibilityValue("\(Int(progress.doubleValue * 100)) percent")
    }

    func close() {
        guard !closed else { return }
        closed = true
        onCancel = nil
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        // Tear down focus links while this owner still retains both controls.
        panel.contentView = nil
        panel.close()
    }

    @objc private func cancelSync() {
        guard !closed else { return }
        let cancel = onCancel
        close()
        cancel?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelSync()
        return false
    }
}

// MARK: - PhotoManager Photos integration

struct PhotosRefreshSnapshot {
    let generation: UUID
    let item: PhotoItem

    @MainActor
    func currentIndex(in manager: PhotoManager) -> Int? {
        guard manager.desktopGeneration == generation,
              let index = manager.photos.firstIndex(where: { $0.id == item.id }) else { return nil }
        let current = manager.photos[index]
        guard current.photosLibrarySource == item.photosLibrarySource,
              current.photosLibraryAssets == item.photosLibraryAssets,
              current.spaceImageFilenames == item.spaceImageFilenames else { return nil }
        return index
    }

    /// Keep one completed refresh pending while its own scene is being edited.
    /// Sleeping happens only for that pending work; cancellation or a changed
    /// source/desktop invalidates it before it can touch the current snapshot.
    @MainActor
    func readyIndex(in manager: PhotoManager, onWait: () -> Void = {}) async -> Int? {
        await manager.waitForMediaReplacement({ currentIndex(in: manager) }, onWait: onWait)
    }
}

extension PhotoManager {
    /// Installs one public PhotoKit observer for the app lifetime. The observer only schedules a
    /// main-actor reconciliation; it never reads assets or touches the renderer on PhotoKit's
    /// background callback queue.
    func installPhotosLibraryObserver() {
        guard photos.contains(where: { $0.photosLibrarySource?.localIdentifier.isEmpty == false }) else { return }
        guard PhotosLibraryAuthorization.isUsable(PhotosLibraryAuthorization.status) else { return }
        guard photosLibraryObserver == nil else { return }
        let observer = PhotosLibraryObserver(manager: self)
        photosLibraryObserver = observer
        PHPhotoLibrary.shared().register(observer)
    }

    /// Creates a live Photos-backed Space after explicit authorization and a validated initial
    /// snapshot. All media is copied to the managed store before the widget is committed.
    @discardableResult
    func addPhotosLibraryCollection(
        _ selection: PhotosLibraryCollectionSelection,
        progress: (@MainActor (PhotosLibrarySyncState) -> Void)? = nil
    ) async -> ImportBatchResult {
        beginMediaImport()
        defer { endMediaImport() }
        let generation = desktopGeneration
        let status = await authorizePhotos(progress: progress, offerRecovery: true)
        guard desktopGeneration == generation else { return ImportBatchResult() }
        guard PhotosLibraryAuthorization.isUsable(status) else {
            return ImportBatchResult(entries: [
                .init(source: selection.displayName, status: .failed, reason: photosAuthorizationFailure(status))
            ])
        }
        guard let collection = resolvePhotosCollection(selection.localIdentifier) else {
            return ImportBatchResult(entries: [
                .init(source: selection.displayName, status: .failed, reason: "The Photos collection is no longer available. Choose it again.")
            ])
        }

        return await syncPhotosLibraryCollection(
            selection: selection,
            collection: collection,
            widgetID: nil,
            progress: progress
        )
    }

    /// Reconciles an existing collection widget. Missing/revoked collections only change the
    /// persisted source status; the previous managed snapshot remains untouched and renderable.
    @discardableResult
    func refreshPhotosLibraryCollection(
        _ widgetID: UUID,
        offerPermissionRecovery: Bool = true,
        progress: (@MainActor (PhotosLibrarySyncState) -> Void)? = nil
    ) async -> ImportBatchResult {
        beginMediaImport()
        defer { endMediaImport() }
        guard let item = photos.first(where: { $0.id == widgetID }),
              let source = item.photosLibrarySource,
              !source.localIdentifier.isEmpty else {
            return ImportBatchResult(entries: [
                .init(source: "Photos collection", status: .failed, reason: "Choose a Photos collection again to relink this snapshot.")
            ])
        }
        let snapshot = PhotosRefreshSnapshot(generation: desktopGeneration, item: item)
        func widgetSnapshotIsCurrent() -> Bool {
            snapshot.currentIndex(in: self) != nil
        }
        let status = await authorizePhotos(
            progress: progress,
            offerRecovery: offerPermissionRecovery
        )
        guard widgetSnapshotIsCurrent() else {
            setPhotosLibrarySyncState(.idle, progress: progress)
            return ImportBatchResult()
        }
        guard PhotosLibraryAuthorization.isUsable(status) else {
            markPhotosCollectionUnavailable(widgetID, message: photosAuthorizationFailure(status))
            return ImportBatchResult(entries: [
                .init(source: source.displayName, status: .failed, reason: photosAuthorizationFailure(status))
            ])
        }
        guard let collection = resolvePhotosCollection(source.localIdentifier) else {
            markPhotosCollectionUnavailable(widgetID, message: "The Photos collection is missing or no longer accessible. Choose it again to relink this snapshot.")
            return ImportBatchResult(entries: [
                .init(source: source.displayName, status: .failed, reason: "The Photos collection is missing or no longer accessible. Choose it again to relink this snapshot.")
            ])
        }
        let selection = PhotosLibraryCollectionSelection(
            localIdentifier: source.localIdentifier,
            collectionType: source.collectionType,
            displayName: source.displayName,
            assetCount: PHAsset.fetchAssets(in: collection, options: nil).count
        )
        return await syncPhotosLibraryCollection(
            selection: selection,
            collection: collection,
            widgetID: widgetID,
            progress: progress
        )
    }

    /// Rebinds an imported archive snapshot to a newly selected collection while retaining any
    /// managed files that cannot be replaced yet. A successful sync makes the selected collection
    /// the new durable source of truth.
    @discardableResult
    func relinkPhotosLibraryCollection(
        _ widgetID: UUID,
        to selection: PhotosLibraryCollectionSelection,
        progress: (@MainActor (PhotosLibrarySyncState) -> Void)? = nil
    ) async -> ImportBatchResult {
        beginMediaImport()
        defer { endMediaImport() }
        guard let item = photos.first(where: { $0.id == widgetID }),
              item.photosLibrarySource != nil else {
            return ImportBatchResult(entries: [
                .init(source: selection.displayName, status: .failed, reason: "The Photos collection widget no longer exists.")
            ])
        }
        let snapshot = PhotosRefreshSnapshot(generation: desktopGeneration, item: item)
        func widgetSnapshotIsCurrent() -> Bool {
            snapshot.currentIndex(in: self) != nil
        }
        let status = await authorizePhotos(progress: progress, offerRecovery: true)
        guard widgetSnapshotIsCurrent() else {
            setPhotosLibrarySyncState(.idle, progress: progress)
            return ImportBatchResult()
        }
        guard PhotosLibraryAuthorization.isUsable(status) else {
            markPhotosCollectionUnavailable(widgetID, message: photosAuthorizationFailure(status))
            return ImportBatchResult(entries: [
                .init(source: selection.displayName, status: .failed, reason: photosAuthorizationFailure(status))
            ])
        }
        guard let collection = resolvePhotosCollection(selection.localIdentifier) else {
            markPhotosCollectionUnavailable(widgetID, message: "The selected Photos collection is no longer available.")
            return ImportBatchResult(entries: [
                .init(source: selection.displayName, status: .failed, reason: "The selected Photos collection is no longer available.")
            ])
        }
        return await syncPhotosLibraryCollection(
            selection: selection,
            collection: collection,
            widgetID: widgetID,
            progress: progress,
            replacingAnonymousSnapshot: true
        )
    }

    /// Reconciles every live collection after a PhotoKit change notification. Each widget owns a
    /// safe managed snapshot, so an authorization or collection error is reported without data
    /// loss and can be fixed from its row/menu control later.
    @discardableResult
    func reconcilePhotosLibraryCollections() async -> ImportBatchResult {
        let ids = photos.compactMap { item in
            item.photosLibrarySource?.localIdentifier.isEmpty == false ? item.id : nil
        }
        var result = ImportBatchResult()
        for id in ids {
            guard !Task.isCancelled else { break }
            result.append(contentsOf: await refreshPhotosLibraryCollection(
                id,
                offerPermissionRecovery: false
            ))
        }
        return result
    }

    func photosLibraryStatusDescription(for id: UUID) -> String? {
        guard let source = photos.first(where: { $0.id == id })?.photosLibrarySource else { return nil }
        var description = "\(source.displayName) · \(source.status.displayName)"
        if let error = source.lastError, !error.isEmpty { description += " · \(error)" }
        return description
    }

    private func syncPhotosLibraryCollection(
        selection: PhotosLibraryCollectionSelection,
        collection: PHAssetCollection,
        widgetID: UUID?,
        progress: (@MainActor (PhotosLibrarySyncState) -> Void)?,
        replacingAnonymousSnapshot: Bool = false
    ) async -> ImportBatchResult {
        guard !Task.isCancelled else { return ImportBatchResult() }
        let assets = fetchPhotosAssets(in: collection)
        let descriptors = assets.map(PhotosLibraryAssetExporter.descriptor(for:))
        let itemIndex = widgetID.flatMap { id in photos.firstIndex(where: { $0.id == id }) }
        let existingItem = itemIndex.map { photos[$0] }
        let generation = desktopGeneration
        let snapshot = existingItem.map { PhotosRefreshSnapshot(generation: generation, item: $0) }
        func widgetSnapshotIsCurrent() -> Bool {
            guard !Task.isCancelled, desktopGeneration == generation else { return false }
            guard widgetID != nil else { return true }
            return snapshot?.currentIndex(in: self) != nil
        }
        let currentID = existingItem
            .flatMap { $0.photosLibraryAssets[safe: $0.folderImageIndex]?.localIdentifier }
        let bounded = PhotosLibraryCollectionPolicy.bounded(descriptors, currentAssetIdentifier: currentID)

        let source = PhotosLibrarySource(
            localIdentifier: selection.localIdentifier,
            collectionType: selection.collectionType,
            displayName: selection.displayName,
            status: assets.isEmpty ? .empty : .syncing,
            lastReconciledAt: existingItem?.photosLibrarySource?.lastReconciledAt,
            lastError: nil
        )
        var resultEntries = bounded.skipped.map {
            ImportBatchResult.Entry(source: $0.displayName, status: .skipped, reason: "The Photos collection cache limit was reached.")
        }
        if assets.isEmpty {
            if let itemIndex {
                var retainedSource = source
                retainedSource.status = .empty
                retainedSource.lastReconciledAt = Date()
                retainedSource.lastError = "No assets are currently available; the last managed snapshot remains visible."
                guard storePhotosCollectionSource(photos[itemIndex].id, source: retainedSource) else {
                    setPhotosLibrarySyncState(.failed("The Photos collection could not be saved."), progress: progress)
                    return ImportBatchResult(entries: [
                        .init(source: selection.displayName, status: .failed, reason: "The Photos collection could not be saved.")
                    ])
                }
            }
            setPhotosLibrarySyncState(.idle, progress: progress)
            return ImportBatchResult(entries: [
                .init(source: selection.displayName, status: .skipped, reason: "The collection is empty; the last managed snapshot remains available.")
            ])
        }

        let assetsByID = Dictionary(assets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let existingByID = Dictionary(existingItem?.photosLibraryAssets.map { ($0.localIdentifier, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let anonymousSnapshot = replacingAnonymousSnapshot || existingByID.keys.contains("")
        var reconciled: [PhotosLibraryAsset] = []
        var staged: [PhotoIngest.Prepared] = []
        var stagedFidelity: [String: ArchiveMediaFidelity] = [:]
        let total = bounded.selected.count
        var completed = 0
        // Existing snapshots are already consuming the cache budget. A changed asset gives its
        // old bytes back before its replacement is downloaded; a failed replacement adds them
        // back when the last known-good record is retained below.
        var totalManagedBytes = existingItem?.photosLibraryAssets.reduce(Int64(0)) {
            $0 + managedByteCount(for: $1)
        } ?? 0
        let directory = storageDir

        for descriptor in bounded.selected {
            let old = existingByID[descriptor.localIdentifier]
            let resourceTypes = assetsByID[descriptor.localIdentifier].flatMap {
                PhotosLibraryResourcePolicy.selectedTypes(for: descriptor.mediaKind,
                                                          in: PHAssetResource.assetResources(for: $0).map(\.type))
            }
            if let old,
               old.matchesCurrentResource(descriptor, resourceTypes: resourceTypes),
               managedFilesExist(for: old) {
                reconciled.append(old)
                resultEntries.append(.init(source: old.displayName, status: .accepted))
                completed += 1
                setPhotosLibrarySyncState(
                    .syncing(collection: selection.displayName, completed: completed, total: total, fraction: 1, message: "Keeping current asset"),
                    progress: progress
                )
                continue
            }

            guard widgetSnapshotIsCurrent() else {
                for file in staged { discardPreparedPhotosMedia(file) }
                setPhotosLibrarySyncState(.idle, progress: progress)
                return ImportBatchResult(entries: resultEntries)
            }
            setPhotosLibrarySyncState(
                .syncing(collection: selection.displayName, completed: completed, total: total, fraction: 0, message: "Downloading \(descriptor.displayName)"),
                progress: progress
            )

            guard let asset = assetsByID[descriptor.localIdentifier] else { continue }
            let oldManagedBytes = old.map { managedByteCount(for: $0) } ?? 0
            totalManagedBytes = max(0, totalManagedBytes - oldManagedBytes)
            let remainingBytes = PhotosLibraryCollectionPolicy.maxManagedBytes
                - min(totalManagedBytes, PhotosLibraryCollectionPolicy.maxManagedBytes)
            guard remainingBytes > 0 else {
                if let old {
                    reconciled.append(old)
                    totalManagedBytes += oldManagedBytes
                }
                resultEntries.append(.init(
                    source: descriptor.displayName,
                    status: .skipped,
                    reason: "The Photos collection cache byte limit was reached."
                ))
                completed += 1
                setPhotosLibrarySyncState(
                    .syncing(collection: selection.displayName, completed: completed, total: total, fraction: 1, message: "Skipped oversized Photos asset"),
                    progress: progress
                )
                continue
            }
            do {
                let completedForProgress = completed
                let progressLease = PhotosDownloadProgressLease()
                defer { progressLease.isActive = false }
                let exported = try await PhotosLibraryAssetExporter.export(
                    asset: asset,
                    allowNetwork: PhotosLibraryCollectionPolicy.allowNetworkDownloads,
                    maxBytes: remainingBytes,
                    progress: { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self, progressLease.isActive,
                                  self.desktopGeneration == generation,
                                  snapshot == nil || snapshot?.currentIndex(in: self) != nil else { return }
                            self.setPhotosLibrarySyncState(
                                .syncing(collection: selection.displayName, completed: completedForProgress, total: total, fraction: fraction, message: "Downloading \(descriptor.displayName)"),
                                progress: progress
                            )
                        }
                    }
                )
                let prepared: PhotoIngest.Prepared?
                if let stillData = exported.stillData, let paired = exported.pairedVideoData {
                    prepared = await Task.detached(priority: .utility) {
                        PhotoIngest.prepareLivePhoto(
                            stillData: stillData,
                            pairedVideoData: paired,
                            in: directory,
                            originalName: exported.originalName
                        )
                    }.value
                } else if let videoData = exported.videoData {
                    prepared = await Task.detached(priority: .utility) {
                        PhotoIngest.prepareVideo(
                            data: videoData,
                            fileExtension: exported.videoExtension ?? "mov",
                            in: directory,
                            originalName: exported.originalName
                        )
                    }.value
                } else if let stillData = exported.stillData {
                    prepared = await Task.detached(priority: .utility) {
                        PhotoIngest.prepare(
                            data: stillData,
                            in: directory,
                            originalName: exported.originalName
                        )
                    }.value
                } else {
                    prepared = nil
                }
                guard let prepared,
                      loadPreparedPhotosContent(prepared) != nil else {
                    if let prepared { discardPreparedPhotosMedia(prepared) }
                    throw PhotosLibraryAssetExportError.unavailable("The downloaded Photos asset could not be decoded by Arras.")
                }
                guard widgetSnapshotIsCurrent() else {
                    discardPreparedPhotosMedia(prepared)
                    for file in staged { discardPreparedPhotosMedia(file) }
                    setPhotosLibrarySyncState(.idle, progress: progress)
                    return ImportBatchResult(entries: resultEntries)
                }

                let byteCount = prepared.managedURLs.reduce(Int64(0)) { total, url in
                    total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                let remainingAfter = PhotosLibraryCollectionPolicy.maxManagedBytes
                    - min(totalManagedBytes, PhotosLibraryCollectionPolicy.maxManagedBytes)
                if byteCount > remainingAfter {
                    discardPreparedPhotosMedia(prepared)
                    if let old {
                        reconciled.append(old)
                        totalManagedBytes += oldManagedBytes
                    }
                    resultEntries.append(.init(source: exported.originalName, status: .skipped, reason: "The Photos collection cache byte limit was reached."))
                    completed += 1
                    setPhotosLibrarySyncState(
                        .syncing(collection: selection.displayName, completed: completed, total: total, fraction: 1, message: "Skipped oversized Photos asset"),
                        progress: progress
                    )
                    continue
                }

                let record = PhotosLibraryAsset(
                    localIdentifier: descriptor.localIdentifier,
                    displayName: exported.originalName.isEmpty ? descriptor.displayName : exported.originalName,
                    managedFilename: prepared.filename,
                    media: prepared.media,
                    status: .active,
                    sourceModificationDate: descriptor.modificationDate,
                    sourceByteCount: Int64(exported.stillData?.count ?? exported.videoData?.count ?? 0),
                    pairedVideoByteCount: Int64(exported.pairedVideoData?.count ?? 0),
                    sourceResourceTypes: exported.resourceTypes,
                    lastError: nil
                )
                staged.append(prepared)
                stagedFidelity.merge(prepared.mediaFidelityByFilename) { _, new in new }
                reconciled.append(record)
                totalManagedBytes += byteCount
                resultEntries.append(.init(source: record.displayName, status: .accepted))
            } catch is CancellationError {
                for file in staged { discardPreparedPhotosMedia(file) }
                setPhotosLibrarySyncState(.idle, progress: progress)
                return ImportBatchResult(entries: [
                    .init(source: selection.displayName, status: .skipped, reason: "The Photos sync was cancelled; the previous snapshot remains available.")
                ])
            } catch let exportError as PhotosLibraryAssetExportError {
                let wasSkipped: Bool
                if case .sizeLimit = exportError {
                    wasSkipped = true
                } else {
                    wasSkipped = false
                }
                if let old {
                    var retained = old
                    retained.status = wasSkipped ? .active : .failed
                    retained.lastError = wasSkipped ? nil : exportError.localizedDescription
                    reconciled.append(retained)
                    totalManagedBytes += oldManagedBytes
                }
                resultEntries.append(.init(
                    source: descriptor.displayName,
                    status: wasSkipped ? .skipped : .failed,
                    reason: exportError.localizedDescription
                ))
            } catch {
                if let old {
                    var retained = old
                    retained.status = .failed
                    retained.lastError = error.localizedDescription
                    reconciled.append(retained)
                    totalManagedBytes += oldManagedBytes
                }
                resultEntries.append(.init(source: descriptor.displayName, status: .failed, reason: error.localizedDescription))
            }
            completed += 1
            setPhotosLibrarySyncState(
                .syncing(collection: selection.displayName, completed: completed, total: total, fraction: 1, message: "Processed Photos asset"),
                progress: progress
            )
        }

        if let snapshot, await snapshot.readyIndex(in: self, onWait: {
            self.setPhotosLibrarySyncState(
                .syncing(collection: selection.displayName, completed: 0, total: 0, fraction: 1,
                         message: "Waiting for the photo or collage edit to finish…"),
                progress: progress)
        }) == nil {
            for file in staged { discardPreparedPhotosMedia(file) }
            setPhotosLibrarySyncState(.idle, progress: progress)
            return ImportBatchResult()
        }
        guard widgetSnapshotIsCurrent() else {
            for file in staged { discardPreparedPhotosMedia(file) }
            setPhotosLibrarySyncState(.idle, progress: progress)
            return ImportBatchResult()
        }
        // Array positions and appearance may have changed while downloads were awaited.
        let currentItemIndex = snapshot?.currentIndex(in: self)
        let currentItem = currentItemIndex.map { photos[$0] }

        // An archive snapshot has no PhotoKit IDs to correlate with a partially downloadable
        // replacement collection. Keep the currently displayed managed asset in that case so a
        // relink with one iCloud failure cannot silently replace the user's last safe image with
        // an unrelated subset. A later successful refresh drops the anonymous snapshot.
        if anonymousSnapshot,
           resultEntries.contains(where: { $0.status == .failed }),
           let existingItem,
           let current = existingItem.photosLibraryAssets[safe: existingItem.folderImageIndex],
           managedFilesExist(for: current),
           !reconciled.contains(where: { $0.managedFilenames == current.managedFilenames }) {
            let insertionIndex = min(existingItem.folderImageIndex, reconciled.count)
            reconciled.insert(current, at: insertionIndex)
            resultEntries.append(.init(
                source: current.displayName,
                status: .skipped,
                reason: "The previous snapshot remains visible while the relinked Photos asset is retried."
            ))
        }

        // Keep missing assets in the managed list so the previous safe snapshot remains visible.
        if let existingItem, !anonymousSnapshot {
            // Do not call an asset "missing" merely because the live-folder-style bound skipped
            // it; skipped assets are still in the collection and are reported above. Only an ID
            // that disappeared from PhotoKit gets a retained, explicitly missing snapshot.
            let currentIDs = Set(assets.map(\.localIdentifier))
            for old in existingItem.photosLibraryAssets where !old.localIdentifier.isEmpty && !currentIDs.contains(old.localIdentifier) {
                var retained = old
                retained.status = .missing
                retained.lastError = "This asset is no longer in the selected Photos collection."
                reconciled.append(retained)
                resultEntries.append(.init(source: old.displayName, status: .skipped, reason: "The asset is no longer in the selected Photos collection; its last managed copy remains."))
            }
        }

        // A collection can replace every selected asset while the previous snapshot still has
        // up to 200 entries. Keep the cache bound honest and, if the current asset disappeared,
        // reserve one slot for its last managed copy before dropping older missing entries.
        if reconciled.count > PhotosLibraryCollectionPolicy.maxManagedAssets {
            let currentIndex = currentID.flatMap { current in
                reconciled.firstIndex(where: { $0.localIdentifier == current })
            }
            var keepIndices = Array(reconciled.indices.prefix(PhotosLibraryCollectionPolicy.maxManagedAssets))
            if let currentIndex, !keepIndices.contains(currentIndex) {
                keepIndices.removeLast()
                keepIndices.append(currentIndex)
                keepIndices.sort()
            }
            let keepSet = Set(keepIndices)
            for droppedIndex in reconciled.indices where !keepSet.contains(droppedIndex) {
                let dropped = reconciled[droppedIndex]
                resultEntries.append(.init(
                    source: dropped.displayName,
                    status: .skipped,
                    reason: "The Photos collection cache limit was reached; its last snapshot was released."
                ))
            }
            reconciled = keepIndices.map { reconciled[$0] }
        }

        let retainedManagedNames = Set(reconciled.flatMap(\.managedFilenames))
        for prepared in staged where Set(prepared.managedFilenames).isDisjoint(with: retainedManagedNames) {
            discardPreparedPhotosMedia(prepared)
        }
        staged.removeAll { Set($0.managedFilenames).isDisjoint(with: retainedManagedNames) }

        guard !reconciled.isEmpty else {
            for file in staged { discardPreparedPhotosMedia(file) }
            if !resultEntries.contains(where: { $0.status == .failed }) {
                setPhotosLibrarySyncState(.idle, progress: progress)
                return ImportBatchResult(entries: resultEntries)
            }
            if let widgetID {
                markPhotosCollectionUnavailable(widgetID, message: "No Photos assets could be downloaded or decoded; the last managed snapshot remains available.")
            }
            setPhotosLibrarySyncState(.failed("No Photos assets could be downloaded."), progress: progress)
            return ImportBatchResult(entries: resultEntries + [
                .init(source: selection.displayName, status: .failed, reason: "No Photos assets could be downloaded or decoded.")
            ])
        }

        var nextItem: PhotoItem
        if let currentItem {
            nextItem = currentItem
        } else {
            nextItem = PhotoItem(filename: "")
            nextItem.customName = selection.displayName
            nextItem.rotationInterval = "30s"
            nextItem.folderSizeMode = "dynamic"
        }
        nextItem.customName = currentItem?.customName ?? selection.displayName
        nextItem.photosLibrarySource = source
        nextItem.photosLibrarySource?.status = resultEntries.contains(where: { $0.status == .failed }) ? .failed : .active
        nextItem.photosLibrarySource?.lastReconciledAt = Date()
        nextItem.photosLibrarySource?.lastError = resultEntries.first(where: { $0.status == .failed })?.reason
        nextItem.photosLibraryAssets = reconciled
        nextItem.spaceImageFilenames = reconciled.map(\.managedFilename)
        let displayedID = currentItem.flatMap { $0.photosLibraryAssets[safe: $0.folderImageIndex]?.localIdentifier }
        nextItem.folderImageIndex = displayedID.flatMap { id in reconciled.firstIndex(where: { $0.localIdentifier == id }) }
            ?? min(nextItem.folderImageIndex, max(0, reconciled.count - 1))
        let reconciledFilenames = Set(reconciled.flatMap(\.managedFilenames))
        nextItem.mediaFidelity = nextItem.mediaFidelity.filter { reconciledFilenames.contains($0.key) }
        nextItem.mediaFidelity.merge(stagedFidelity) { _, new in new }
        for filename in reconciledFilenames where nextItem.mediaFidelity[filename] == nil {
            nextItem.mediaFidelity[filename] = .sourceBytes
        }
        let oldManaged = Set(existingItem.map(storedFilenamesForPhotosLibrary) ?? [])

        if currentItemIndex != nil, let snapshot {
            guard widgetSnapshotIsCurrent() else {
                for file in staged { discardPreparedPhotosMedia(file) }
                setPhotosLibrarySyncState(.idle, progress: progress)
                return ImportBatchResult(entries: resultEntries)
            }
            guard commitPhotosCollectionRefresh(nextItem, replacing: snapshot) else {
                for file in staged { discardPreparedPhotosMedia(file) }
                setPhotosLibrarySyncState(.failed("The Photos collection could not be saved."), progress: progress)
                return ImportBatchResult(entries: resultEntries + [
                    .init(source: selection.displayName, status: .failed, reason: "The Photos collection could not be saved.")
                ])
            }
            for filename in oldManaged.subtracting(Set(storedFilenamesForPhotosLibrary(nextItem))) {
                removeStoredFileIfUnreferenced(filename)
            }
        } else {
            guard commitImportedItems([nextItem], replacing: false) else {
                for file in staged { discardPreparedPhotosMedia(file) }
                setPhotosLibrarySyncState(.failed("The Photos collection could not be saved."), progress: progress)
                return ImportBatchResult(entries: resultEntries + [
                    .init(source: selection.displayName, status: .failed, reason: "The Photos collection could not be saved.")
                ])
            }
        }

        // A relink can turn an archive snapshot (which had no live identifier) into a live
        // source after the manager was initialized. Ensure that path installs the observer too;
        // the new-item path and a normal refresh are both harmlessly idempotent here.
        installPhotosLibraryObserver()
        setPhotosLibrarySyncState(.idle, progress: progress)
        return ImportBatchResult(entries: resultEntries)
    }

    /// The existing-widget commit is kept separate from PhotoKit acquisition so the
    /// durable snapshot and native renderer share one transaction boundary.
    @discardableResult
    func commitPhotosCollectionRefresh(_ item: PhotoItem, replacing snapshot: PhotosRefreshSnapshot) -> Bool {
        guard let index = snapshot.currentIndex(in: self), item.id == snapshot.item.id,
              !replacementConflictsWithArrangement(photos[index]) else { return false }
        let previousPhotos = photos
        let previous = photos[index]
        let previousFilename = previous.spaceImageFilenames[safe: previous.folderImageIndex] ?? previous.filename
        let nextFilename = item.spaceImageFilenames[safe: item.folderImageIndex] ?? item.filename
        let previousMedia = previous.photosLibraryAssets.first { $0.managedFilename == previousFilename }?.media ?? previous.media
        let nextMedia = item.photosLibraryAssets.first { $0.managedFilename == nextFilename }?.media ?? item.media
        let previousSpaceImages = spaceImages[item.id]
        photos[index] = item
        spaceImages[item.id] = item.photosLibraryAssets.map { storageDir.appendingPathComponent($0.managedFilename) }
        guard persist() else {
            photos = previousPhotos
            if let previousSpaceImages { spaceImages[item.id] = previousSpaceImages }
            else { spaceImages.removeValue(forKey: item.id) }
            return false
        }
        // Metadata or another album entry can change without replacing the
        // displayed content. Preserve its decoder, geometry and resize history.
        if previousFilename != nextFilename || previousMedia != nextMedia || windows[item.id] == nil {
            refreshPhotosLibraryWindow(item)
        }
        return true
    }

    private func authorizePhotos(
        progress: (@MainActor (PhotosLibrarySyncState) -> Void)?,
        offerRecovery: Bool
    ) async -> PHAuthorizationStatus {
        setPhotosLibrarySyncState(.authorizing, progress: progress)
        let status = await PhotosLibraryAuthorization.requestIfNeeded(allowPrompt: offerRecovery)
        if !PhotosLibraryAuthorization.isUsable(status) {
            setPhotosLibrarySyncState(.failed(photosAuthorizationFailure(status)), progress: progress)
            if offerRecovery {
                PhotosPermissionRecovery.present(for: status)
            }
        }
        return status
    }

    private func fetchPhotosAssets(in collection: PHAssetCollection) -> [PHAsset] {
        let result = PHAsset.fetchAssets(in: collection, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            // The widget snapshot understands stills, Live Photos, and muted movies. Ignore
            // audio/unknown PhotoKit resources up front so an album containing them does not
            // consume a cache slot or report a misleading media decode failure.
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            assets.append(asset)
        }
        return assets
    }

    private func resolvePhotosCollection(_ localIdentifier: String) -> PHAssetCollection? {
        guard !localIdentifier.isEmpty else { return nil }
        return PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject
    }

    private func photosAuthorizationFailure(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .denied: return "Photos access was denied. Enable it in System Settings and try again."
        case .restricted: return "Photos access is restricted on this Mac."
        default: return "Photos access is unavailable. Enable it in System Settings and try again."
        }
    }

    private func setPhotosLibrarySyncState(
        _ state: PhotosLibrarySyncState,
        progress: (@MainActor (PhotosLibrarySyncState) -> Void)?
    ) {
        photosLibrarySyncState = state
        progress?(state)
    }

    private func markPhotosCollectionUnavailable(_ widgetID: UUID, message: String) {
        guard var source = photos.first(where: { $0.id == widgetID })?.photosLibrarySource else { return }
        source.status = .needsRelink
        source.lastError = message
        _ = storePhotosCollectionSource(widgetID, source: source)
    }

    @discardableResult
    func storePhotosCollectionSource(_ widgetID: UUID, source: PhotosLibrarySource) -> Bool {
        guard let index = photos.firstIndex(where: { $0.id == widgetID }),
              let previous = photos[index].photosLibrarySource else { return false }
        photos[index].photosLibrarySource = source
        guard persist() else {
            photos[index].photosLibrarySource = previous
            return false
        }
        return true
    }

    private func managedFilesExist(for asset: PhotosLibraryAsset) -> Bool {
        asset.managedFilenames.allSatisfy { FileManager.default.fileExists(atPath: storageDir.appendingPathComponent($0).path) }
    }

    private func managedByteCount(for asset: PhotosLibraryAsset) -> Int64 {
        asset.managedFilenames.reduce(Int64(0)) { total, filename in
            total + Int64((try? storageDir.appendingPathComponent(filename).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func storedFilenamesForPhotosLibrary(_ item: PhotoItem) -> [String] {
        var names = item.photosLibraryAssets.flatMap(\.managedFilenames)
        names.append(contentsOf: [item.filename, item.media.posterFilename, item.media.pairedVideoFilename].compactMap { $0 })
        names.append(contentsOf: item.spaceImageFilenames)
        return names.filter { !$0.isEmpty }
    }

    private func loadPreparedPhotosContent(_ prepared: PhotoIngest.Prepared) -> PhotoContent? {
        PhotoContent.load(from: prepared.url, posterURL: prepared.posterURL, pairedVideoURL: prepared.pairedVideoURL)
    }

    private func discardPreparedPhotosMedia(_ prepared: PhotoIngest.Prepared) {
        for url in prepared.managedURLs { try? FileManager.default.removeItem(at: url) }
    }

    func refreshPhotosLibraryWindow(_ item: PhotoItem) {
        guard item.isVisible, !item.isHiddenForDisplay, !item.isHiddenForPresence,
              collageAllowsWindow(item) else { return }
        guard let content = loadDisplayContent(for: item) else {
            recordMediaImportFailure("The stored Photos asset for \(label(for: item)) could not be decoded.")
            return
        }
        if let window = windows[item.id] {
            let filename = item.spaceImageFilenames[safe: item.folderImageIndex]
            let targetFrame = filename.flatMap { item.folderImageConfigs[$0] }.map { NSRectFromString($0.frameString) }
            window.swapImage(content, targetFrame: targetFrame, mode: item.folderSizeMode, animate: false)
        } else {
            createWindow(for: item, content: content)
        }
        setupRotationTimer(for: item)
    }
}

/// A PhotoKit change observer with no retained Photos objects. The manager remains the owner of
/// all durable state and can safely keep its last snapshot if authorization or a collection is
/// revoked.
@MainActor
final class PhotosChangeReconciler {
    private var pending = false
    private(set) var task: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        pending = true
        guard task == nil else { return }
        task = Task { @MainActor in
            // Changes arriving during an iCloud download require another pass,
            // but never a second concurrent download of the same collection.
            while pending && !Task.isCancelled {
                pending = false
                await operation()
            }
            task = nil
            // A fresh change can arrive while cancellation unwinds the old download.
            if pending { enqueue(operation) }
        }
    }

    func cancel() {
        pending = false
        task?.cancel()
    }
}

final class PhotosLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    weak var manager: PhotoManager?
    private let reconciler: PhotosChangeReconciler

    @MainActor
    init(manager: PhotoManager) {
        self.manager = manager
        reconciler = PhotosChangeReconciler()
    }

    @MainActor
    func cancelPendingSync() { reconciler.cancel() }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconciler.enqueue { [weak manager = self.manager] in
                guard let manager else { return }
                _ = await manager.reconcilePhotosLibraryCollections()
            }
        }
    }
}
