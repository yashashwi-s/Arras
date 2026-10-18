import AppKit

/// Placement snapshots never restore old media, styling, visibility or names.
struct WidgetPlacement: Equatable {
    let frameString: String
    let width: CGFloat
    let folderFrames: [String: FolderImageConfig]
    let displayID: String?
    let displayFrames: [String: String]
    let parentID: UUID?

    init(_ item: PhotoItem, frame: NSRect) {
        frameString = NSStringFromRect(frame)
        width = item.widgetWidth
        folderFrames = item.folderImageConfigs
        displayID = item.displayIdentifier
        displayFrames = item.savedDisplayFrames
        parentID = item.collageParentID
    }

    func apply(to item: inout PhotoItem) {
        item.frameString = frameString
        item.widgetWidth = width
        item.folderImageConfigs = folderFrames
        item.displayIdentifier = displayID
        item.savedDisplayFrames = displayFrames
        item.collageParentID = parentID
    }
}

struct WidgetScaledDimensions: Equatable {
    let compositionScale: CGFloat?
    let cornerRadius: CGFloat
    let matWidth: CGFloat
    let borderWidth: CGFloat
    let shadowBlur: CGFloat

    init(_ item: PhotoItem) {
        compositionScale = item.desktopCollage?.compositionScale
        cornerRadius = item.cornerRadius
        matWidth = item.matWidth
        borderWidth = item.borderWidth
        shadowBlur = item.shadowBlur
    }

    func apply(to item: inout PhotoItem) {
        if let compositionScale { item.desktopCollage?.compositionScale = compositionScale }
        else {
            item.cornerRadius = cornerRadius
            item.matWidth = matWidth
            item.borderWidth = borderWidth
            item.shadowBlur = shadowBlur
        }
    }
}

struct ArrangementSnapshot: Equatable {
    let placements: [UUID: WidgetPlacement]
    let members: [UUID: Set<UUID>]
    var scaledDimensions: [UUID: WidgetScaledDimensions] = [:]
    var stacking: [UUID: Int] = [:]
}

struct ArrangementChange {
    let name: String
    let before: ArrangementSnapshot
    let after: ArrangementSnapshot
}

@MainActor
extension PhotoManager {
    func arrangementSnapshot(ids: Set<UUID>) -> ArrangementSnapshot {
        let items = photos.filter { ids.contains($0.id) }
        return ArrangementSnapshot(
            placements: Dictionary(uniqueKeysWithValues: items.map { ($0.id, WidgetPlacement($0, frame: collageFrame($0))) }),
            members: Dictionary(uniqueKeysWithValues: items.filter { $0.desktopCollage != nil }.map { ($0.id, Set(collageMembers($0.id).map(\.id))) })
        )
    }

    /// Gesture pickup models retain durable destinations even during an animation.
    func storedArrangementSnapshot(_ items: [PhotoItem]) -> ArrangementSnapshot {
        ArrangementSnapshot(
            placements: Dictionary(uniqueKeysWithValues: items.map {
                ($0.id, WidgetPlacement($0, frame: NSRectFromString($0.frameString)))
            }),
            members: Dictionary(uniqueKeysWithValues: items.filter { $0.desktopCollage != nil }.map { parent in
                (parent.id, Set(photos.filter { $0.collageParentID == parent.id }.map(\.id)))
            })
        )
    }

    func recordArrangement(name: String, before: ArrangementSnapshot, after: ArrangementSnapshot) {
        guard before != after else { return }
        arrangementUndo.append(ArrangementChange(name: name, before: before, after: after))
        if arrangementUndo.count > 50 { arrangementUndo.removeFirst(arrangementUndo.count - 50) }
        arrangementRedo.removeAll()
    }

    var canUndoArrangement: Bool { arrangementUndo.last.map { matchesArrangement($0.after) } ?? false }
    var canRedoArrangement: Bool { arrangementRedo.last.map { matchesArrangement($0.before) } ?? false }

    /// Placement is provisional until gestures, return motion and appearance
    /// previews finish. Automatic replacement must not terminate those edits.
    var hasActiveArrangementInteraction: Bool {
        !collageDrags.isEmpty || !collageMoveSnapshots.isEmpty || !collageResizeSnapshots.isEmpty
            || !collageFlights.isEmpty || !collageAppearanceDrafts.isEmpty
    }

    /// Background work must preserve other scenes while refusing changes that intersect an
    /// unfinished gesture, its drop target, return motion or appearance preview.
    func hasArrangementInteraction(affecting ids: Set<UUID>) -> Bool {
        for (id, drag) in collageDrags {
            if ids.contains(id) || drag.parentID.map({ ids.contains($0) }) == true
                || drag.targetID.map({ ids.contains($0) }) == true { return true }
        }
        return collageMoveSnapshots.values.contains { snapshot in snapshot.originals.contains { ids.contains($0.id) } }
            || collageResizeSnapshots.values.contains { snapshot in snapshot.originals.contains { ids.contains($0.id) } }
            || collageFlights.keys.contains { ids.contains($0) }
            || collageAppearanceDrafts.keys.contains { ids.contains($0) }
    }

    private func matchesArrangement(_ snapshot: ArrangementSnapshot) -> Bool {
        var current = arrangementSnapshot(ids: Set(snapshot.placements.keys))
        current.scaledDimensions = Dictionary(uniqueKeysWithValues: photos.filter {
            snapshot.scaledDimensions[$0.id] != nil
        }.map { ($0.id, WidgetScaledDimensions($0)) })
        current.stacking = Dictionary(uniqueKeysWithValues: photos.filter {
            snapshot.stacking[$0.id] != nil
        }.map { ($0.id, $0.stackOrder) })
        return collageAppearanceDrafts.isEmpty && collageDrags.isEmpty && collageResizeSnapshots.isEmpty
            && collageMoveSnapshots.isEmpty && collageFlights.isEmpty
            && current == snapshot
    }

    /// Context and status menus expose history without taking keyboard focus from
    /// the user's foreground application. Shortcuts apply while this menu is open.
    func makeArrangementMenuItems() -> [NSMenuItem] {
        let undo = NSMenuItem(title: "Undo " + (arrangementUndo.last?.name ?? "Arrangement"),
                              action: #selector(undoArrangementFromMenu), keyEquivalent: "z")
        undo.target = self
        undo.isEnabled = canUndoArrangement
        let redo = NSMenuItem(title: "Redo " + (arrangementRedo.last?.name ?? "Arrangement"),
                              action: #selector(redoArrangementFromMenu), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = self
        redo.isEnabled = canRedoArrangement
        return [undo, redo]
    }

    /// AppKit presents this submenu inline as two icon buttons, retaining the
    /// same native actions, shortcuts and history validation as context menus.
    func makeArrangementMenuPalette() -> NSMenuItem {
        let palette = NSMenu(title: "Undo and Redo")
        palette.presentationStyle = .palette
        palette.autoenablesItems = false
        for (item, presentation) in zip(makeArrangementMenuItems(),
                                        [("arrow.uturn.backward", "⌘Z"), ("arrow.uturn.forward", "⇧⌘Z")]) {
            item.image = NSImage(systemSymbolName: presentation.0, accessibilityDescription: item.title)
            item.toolTip = "\(item.title) (\(presentation.1))"
            item.setAccessibilityLabel(item.title)
            palette.addItem(item)
        }
        let row = NSMenuItem(title: "Undo and Redo", action: nil, keyEquivalent: "")
        row.submenu = palette
        return row
    }

    @objc private func undoArrangementFromMenu() { _ = undoArrangement() }
    @objc private func redoArrangementFromMenu() { _ = redoArrangement() }

    @discardableResult
    func undoArrangement() -> Bool {
        guard let change = arrangementUndo.last, matchesArrangement(change.after),
              restoreArrangement(change.before) else { return false }
        arrangementUndo.removeLast()
        arrangementRedo.append(change)
        return true
    }

    @discardableResult
    func redoArrangement() -> Bool {
        guard let change = arrangementRedo.last, matchesArrangement(change.before),
              restoreArrangement(change.after) else { return false }
        arrangementRedo.removeLast()
        arrangementUndo.append(change)
        return true
    }

    private func restoreArrangement(_ snapshot: ArrangementSnapshot) -> Bool {
        let previous = photos
        for index in photos.indices {
            snapshot.placements[photos[index].id]?.apply(to: &photos[index])
            snapshot.scaledDimensions[photos[index].id]?.apply(to: &photos[index])
            if let order = snapshot.stacking[photos[index].id] { photos[index].stackOrder = order }
        }
        guard persist() else { photos = previous; return false }
        for (id, placement) in snapshot.placements {
            if snapshot.scaledDimensions[id] != nil,
               let item = photos.first(where: { $0.id == id }) {
                if let window = windows[id] as? CollageDesktopWindow, let settings = item.desktopCollage {
                    window.settings = settings
                } else {
                    (windows[id]?.contentView as? DraggablePhotoView)?.applyScaledAppearance(item)
                }
            }
            windows[id]?.setPhotoFrame(NSRectFromString(placement.frameString))
        }
        // A detached photo resumes its own depth/Space/lock settings. A reattached
        // photo gets its parent’s behavior from syncCollages below.
        for item in photos where snapshot.placements[item.id] != nil && item.collageParentID == nil && item.desktopCollage == nil {
            if windows[item.id] == nil, item.isVisible, !item.isHiddenForDisplay, !item.isHiddenForPresence,
               let content = loadDisplayContent(for: item) {
                createWindow(for: item, content: content)
                if !item.spaceImageFilenames.isEmpty { setupRotationTimer(for: item) }
            }
            let window = windows[item.id]
            (window?.contentView as? DraggablePhotoView)?.isLockedByCollage = false
            window?.setDepth(item.depth)
            window?.setSpaceBound(item.isSpaceBound)
            window?.setLocked(item.isLocked)
        }
        syncCollages()
        return true
    }
}
