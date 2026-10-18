import Foundation
import AppKit

/// A focal point is stored in source-image coordinates: (0, 0) is the lower-left corner and
/// (1, 1) is the upper-right corner. It is deliberately optional on `PhotoItem` so existing
/// widgets keep the old centred crop and ordinary true-ratio widgets do not acquire a crop
/// policy merely because they were upgraded.
struct NormalizedFocalPoint: Codable, Equatable, Hashable {
    let x: Double
    let y: Double

    static let center = NormalizedFocalPoint(x: 0.5, y: 0.5)

    init(x: Double, y: Double) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    var accessibilitySummary: String {
        "\(Int((x * 100).rounded()))% horizontal, \(Int((y * 100).rounded()))% vertical"
    }
}

/// Crop math for fixed slideshow images. `contentsRect` is the portion
/// of the source image that must be shown to fill the target rectangle. With no saved focal
/// point the old centred crop is retained; a saved point only changes which part is centred.
enum PhotoCropGeometry {
    static func contentsRect(
        sourceSize: CGSize,
        targetSize: CGSize,
        focalPoint: NormalizedFocalPoint? = nil
    ) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let sourceAspect = sourceSize.width / sourceSize.height
        let targetAspect = targetSize.width / targetSize.height
        let focus = focalPoint ?? .center

        if sourceAspect > targetAspect {
            // The source is wider than the target: crop the left/right edges.
            let visibleWidth = targetAspect / sourceAspect
            let originX = (1 - visibleWidth) * focus.x
            return CGRect(x: originX, y: 0, width: visibleWidth, height: 1)
        } else if sourceAspect < targetAspect {
            // The source is taller than the target: crop the bottom/top edges.
            let visibleHeight = sourceAspect / targetAspect
            let originY = (1 - visibleHeight) * focus.y
            return CGRect(x: 0, y: originY, width: 1, height: visibleHeight)
        }

        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}

struct WidgetSelectionModifiers: OptionSet, Equatable {
    let rawValue: Int

    static let command = WidgetSelectionModifiers(rawValue: 1 << 0)
    static let shift = WidgetSelectionModifiers(rawValue: 1 << 1)
    static let option = WidgetSelectionModifiers(rawValue: 1 << 2)
    static let control = WidgetSelectionModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var value = WidgetSelectionModifiers()
        if eventFlags.contains(.command) { value.insert(.command) }
        if eventFlags.contains(.shift) { value.insert(.shift) }
        if eventFlags.contains(.option) { value.insert(.option) }
        if eventFlags.contains(.control) { value.insert(.control) }
        self = value
    }
}

enum WidgetSelectionLogic {
    struct Result: Equatable {
        let selectedIDs: Set<UUID>
        let anchorID: UUID?
    }

    /// Standard list semantics: a plain click selects one row, Command toggles one row,
    /// Shift selects the contiguous range from the last anchor, and Command-Shift adds that
    /// range to the existing selection.
    static func selection(
        orderedIDs: [UUID],
        currentIDs: Set<UUID>,
        anchorID: UUID?,
        clickedID: UUID,
        modifiers: WidgetSelectionModifiers
    ) -> Result {
        guard orderedIDs.contains(clickedID) else {
            return Result(selectedIDs: currentIDs, anchorID: anchorID)
        }

        if modifiers.contains(.shift) {
            let anchor = anchorID.flatMap { orderedIDs.firstIndex(of: $0) }
                ?? orderedIDs.firstIndex(of: clickedID)!
            let clicked = orderedIDs.firstIndex(of: clickedID)!
            let bounds = min(anchor, clicked)...max(anchor, clicked)
            let range = Set(orderedIDs[bounds])
            let selected = modifiers.contains(.command) ? currentIDs.union(range) : range
            return Result(selectedIDs: selected, anchorID: anchorID ?? clickedID)
        }

        if modifiers.contains(.command) {
            var selected = currentIDs
            if selected.contains(clickedID) {
                selected.remove(clickedID)
            } else {
                selected.insert(clickedID)
            }
            return Result(selectedIDs: selected, anchorID: clickedID)
        }

        return Result(selectedIDs: [clickedID], anchorID: clickedID)
    }
}

enum WidgetAlignment: String, CaseIterable, Identifiable {
    case left
    case center
    case right
    case top
    case middle
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return "Align Left"
        case .center: return "Align Center"
        case .right: return "Align Right"
        case .top: return "Align Top"
        case .middle: return "Align Middle"
        case .bottom: return "Align Bottom"
        }
    }
}

enum WidgetDistribution: String, CaseIterable, Identifiable {
    case horizontally
    case vertically

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .horizontally: return "Distribute Horizontally"
        case .vertically: return "Distribute Vertically"
        }
    }
}

enum WidgetNudgeDirection {
    case left, right, up, down
}

struct WidgetGeometryItem: Equatable {
    let id: UUID
    let photoFrame: CGRect
    let visualFrame: CGRect
}

/// Pure geometry planning for selection operations. The manager supplies only windows that
/// are currently present and editable, then applies the returned deltas in one transaction.
enum WidgetSelectionGeometry {
    /// The axis-aligned desktop footprint of a visible frame after its content is tilted about
    /// the centre. Alignment is judged by this footprint, rather than its unrotated persisted
    /// photo rect, because the mat and rotated corners are what a person actually sees.
    static func visibleFootprint(_ frame: CGRect, tiltDegrees: CGFloat) -> CGRect {
        guard tiltDegrees != 0, frame.width > 0, frame.height > 0 else { return frame }
        let radians = abs(tiltDegrees) * .pi / 180
        let width = frame.width * abs(cos(radians)) + frame.height * abs(sin(radians))
        let height = frame.width * abs(sin(radians)) + frame.height * abs(cos(radians))
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func alignmentDeltas(
        _ items: [WidgetGeometryItem],
        alignment: WidgetAlignment
    ) -> [UUID: CGPoint] {
        guard !items.isEmpty else { return [:] }

        switch alignment {
        case .left:
            let target = items.map { $0.visualFrame.minX }.min()!
            return items.reduce(into: [:]) { $0[$1.id] = CGPoint(x: target - $1.visualFrame.minX, y: 0) }
        case .center:
            let target = (items.map { $0.visualFrame.minX }.min()! + items.map { $0.visualFrame.maxX }.max()!) / 2
            return items.reduce(into: [:]) { $0[$1.id] = CGPoint(x: target - $1.visualFrame.midX, y: 0) }
        case .right:
            let target = items.map { $0.visualFrame.maxX }.max()!
            return items.reduce(into: [:]) { $0[$1.id] = CGPoint(x: target - $1.visualFrame.maxX, y: 0) }
        case .bottom:
            let target = items.map { $0.visualFrame.minY }.min()!
            return items.reduce(into: [:]) { $0[$1.id] = CGPoint(x: 0, y: target - $1.visualFrame.minY) }
        case .middle:
            let target = (items.map { $0.visualFrame.minY }.min()! + items.map { $0.visualFrame.maxY }.max()!) / 2
            return items.reduce(into: [:]) { $0[$1.id] = CGPoint(x: 0, y: target - $1.visualFrame.midY) }
        case .top:
            let target = items.map { $0.visualFrame.maxY }.max()!
            return items.reduce(into: [:]) { $0[$1.id] = CGPoint(x: 0, y: target - $1.visualFrame.maxY) }
        }
    }

    static func distributionDeltas(
        _ items: [WidgetGeometryItem],
        distribution: WidgetDistribution
    ) -> [UUID: CGPoint] {
        guard items.count >= 3 else { return [:] }

        switch distribution {
        case .horizontally:
            let sorted = items.sorted { lhs, rhs in
                if lhs.visualFrame.minX == rhs.visualFrame.minX { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.visualFrame.minX < rhs.visualFrame.minX
            }
            let outerMin = sorted.first!.visualFrame.minX
            let outerMax = sorted.last!.visualFrame.maxX
            let totalWidth = sorted.reduce(0) { $0 + $1.visualFrame.width }
            let availableGap = outerMax - outerMin - totalWidth
            // Distribution means equal *empty space* between visible objects. When the
            // selected objects already occupy more than their outer span, a negative gap
            // would silently force additional overlap. Keep the existing arrangement in that
            // case instead of making a crowded selection more surprising.
            guard availableGap >= 0 else { return [:] }
            let gap = availableGap / CGFloat(sorted.count - 1)
            var cursor = outerMin
            var result: [UUID: CGPoint] = [:]
            for item in sorted {
                result[item.id] = CGPoint(x: cursor - item.visualFrame.minX, y: 0)
                cursor += item.visualFrame.width + gap
            }
            return result
        case .vertically:
            let sorted = items.sorted { lhs, rhs in
                if lhs.visualFrame.minY == rhs.visualFrame.minY { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.visualFrame.minY < rhs.visualFrame.minY
            }
            let outerMin = sorted.first!.visualFrame.minY
            let outerMax = sorted.last!.visualFrame.maxY
            let totalHeight = sorted.reduce(0) { $0 + $1.visualFrame.height }
            let availableGap = outerMax - outerMin - totalHeight
            // See the horizontal case: never turn overlapping items into a more tightly
            // overlapping stack merely because their outer bounds were selected.
            guard availableGap >= 0 else { return [:] }
            let gap = availableGap / CGFloat(sorted.count - 1)
            var cursor = outerMin
            var result: [UUID: CGPoint] = [:]
            for item in sorted {
                result[item.id] = CGPoint(x: 0, y: cursor - item.visualFrame.minY)
                cursor += item.visualFrame.height + gap
            }
            return result
        }
    }
}

/// Appearance-only payload used by Copy Style/Paste Style. Content identity, name, frame,
/// source list, schedule, rotation policy and click action intentionally do not appear here.
struct WidgetAppearanceStyle: Equatable {
    var opacity: CGFloat
    var revealOnHover: Bool
    var cornerRadius: CGFloat
    var shadowEnabled: Bool
    var shadowBlur: CGFloat
    var shadowOpacity: CGFloat
    var borderWidth: CGFloat
    var borderColorHex: String
    var vignetteEnabled: Bool
    var matWidth: CGFloat
    var matColorHex: String
    var shapeMask: String
    var borderStyle: String
    var borderGradientEnabled: Bool
    var borderGradientColorHex: String
    var tiltDegrees: Double
    var stylePreset: String?
    var focalPoint: NormalizedFocalPoint?

    init(_ item: PhotoItem) {
        opacity = item.opacity
        revealOnHover = item.revealOnHover
        cornerRadius = item.cornerRadius
        shadowEnabled = item.shadowEnabled
        shadowBlur = item.shadowBlur
        shadowOpacity = item.shadowOpacity
        borderWidth = item.borderWidth
        borderColorHex = item.borderColorHex
        vignetteEnabled = item.vignetteEnabled
        matWidth = item.matWidth
        matColorHex = item.matColorHex
        shapeMask = item.shapeMask
        borderStyle = item.borderStyle
        borderGradientEnabled = item.borderGradientEnabled
        borderGradientColorHex = item.borderGradientColorHex
        tiltDegrees = item.tiltDegrees
        stylePreset = item.stylePreset
        focalPoint = item.focalPoint
    }

    func apply(to item: inout PhotoItem) {
        item.opacity = opacity
        item.revealOnHover = revealOnHover
        item.cornerRadius = cornerRadius
        item.shadowEnabled = shadowEnabled
        item.shadowBlur = shadowBlur
        item.shadowOpacity = shadowOpacity
        item.borderWidth = borderWidth
        item.borderColorHex = borderColorHex
        item.vignetteEnabled = vignetteEnabled
        item.matWidth = matWidth
        item.matColorHex = matColorHex
        item.shapeMask = shapeMask
        item.borderStyle = borderStyle
        item.borderGradientEnabled = borderGradientEnabled
        item.borderGradientColorHex = borderGradientColorHex
        item.tiltDegrees = tiltDegrees
        item.stylePreset = stylePreset
        item.focalPoint = focalPoint
    }
}

// MARK: - PhotoManager selection operations

extension PhotoManager {
    /// The current settings-list selection. Selection is UI state, not part of a PhotoItem, so
    /// it never leaks into `.arras` archives or changes the saved widget model.
    var hasCopiedAppearanceStyle: Bool { copiedAppearanceStyle != nil }

    var selectedAvailableWidgetCount: Int {
        editableSelectedIDs().count
    }

    /// Whether alignment has at least two editable widgets on one current display.
    /// The Settings action menu uses this instead of treating a mixed-display selection as
    /// an actionable group.
    var canAlignSelection: Bool {
        arrangeableGeometryItems().count >= 2
    }

    /// Whether the selected widgets can be distributed along the requested axis without
    /// introducing overlap. Distribution needs a three-item arrangement to have an interior
    /// item to position.
    func canDistributeSelection(_ distribution: WidgetDistribution) -> Bool {
        let items = arrangeableGeometryItems()
        return items.count >= 3
            && !WidgetSelectionGeometry.distributionDeltas(items, distribution: distribution).isEmpty
    }

    /// A short explanation displayed beside disabled arrangement controls. It reports the
    /// actual gating condition rather than letting a user invoke a command that does nothing.
    var selectionArrangementHint: String? {
        guard selectedPhotoIDs.count >= 2 else {
            return "Select at least two widgets to align them."
        }

        let editable = editableGeometryItems()
        guard editable.count >= 2 else {
            return "Select visible, unlocked widgets on this desktop Space."
        }

        let displayIDs = editable.compactMap { displayIdentifier(for: $0) }
        guard displayIDs.count == editable.count, Set(displayIDs).count == 1 else {
            return "Select widgets on one display to arrange them."
        }

        guard editable.count >= 3 else {
            return "Alignment is available. Select three widgets to distribute them."
        }

        let horizontal = WidgetSelectionGeometry.distributionDeltas(editable, distribution: .horizontally)
        let vertical = WidgetSelectionGeometry.distributionDeltas(editable, distribution: .vertically)
        if horizontal.isEmpty || vertical.isEmpty {
            return "Alignment is available. Separate overlapping widgets before distributing them."
        }
        return nil
    }

    func selectPhoto(_ id: UUID, modifiers: WidgetSelectionModifiers = []) {
        let result = WidgetSelectionLogic.selection(
            orderedIDs: photos.map(\.id),
            currentIDs: selectedPhotoIDs,
            anchorID: selectionAnchorID,
            clickedID: id,
            modifiers: modifiers
        )
        selectedPhotoIDs = result.selectedIDs
        selectionAnchorID = result.anchorID
    }

    func selectAllPhotos() {
        selectedPhotoIDs = Set(photos.map(\.id))
        selectionAnchorID = photos.last?.id
    }

    func clearPhotoSelection() {
        selectedPhotoIDs.removeAll()
        selectionAnchorID = nil
    }

    func normalizePhotoSelection() {
        let validIDs = Set(photos.map(\.id))
        selectedPhotoIDs.formIntersection(validIDs)
        if let anchor = selectionAnchorID, !validIDs.contains(anchor) {
            selectionAnchorID = selectedPhotoIDs.first
        }
    }

    @discardableResult
    func alignSelected(_ alignment: WidgetAlignment) -> Bool {
        let items = arrangeableGeometryItems()
        guard items.count >= 2 else { return false }
        return applyGeometryDeltas(WidgetSelectionGeometry.alignmentDeltas(items, alignment: alignment), name: "Align Photos")
    }

    @discardableResult
    func distributeSelected(_ distribution: WidgetDistribution) -> Bool {
        let items = arrangeableGeometryItems()
        let deltas = WidgetSelectionGeometry.distributionDeltas(items, distribution: distribution)
        guard items.count >= 3, !deltas.isEmpty else { return false }
        return applyGeometryDeltas(deltas, name: "Distribute Photos")
    }

    func setFocalPoint(_ id: UUID, x: Double, y: Double) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let original = photos[index]
        let point = NormalizedFocalPoint(x: x, y: y)
        photos[index].focalPoint = point
        updateLiveFocalPoint(for: photos[index])
        if !persist() {
            photos[index] = original
            updateLiveFocalPoint(for: original)
        }
    }

    func resetFocalPoint(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let original = photos[index]
        photos[index].focalPoint = nil
        updateLiveFocalPoint(for: photos[index])
        if !persist() {
            photos[index] = original
            updateLiveFocalPoint(for: original)
        }
    }

    func nudgeSelected(_ direction: WidgetNudgeDirection, modifiers: WidgetSelectionModifiers = []) {
        var distance: CGFloat = 1
        if modifiers.contains(.shift) { distance *= 10 }
        if modifiers.contains(.option) { distance *= 5 }
        if modifiers.contains(.control) { distance *= 10 }

        let delta: CGPoint
        switch direction {
        case .left: delta = CGPoint(x: -distance, y: 0)
        case .right: delta = CGPoint(x: distance, y: 0)
        case .up: delta = CGPoint(x: 0, y: distance)
        case .down: delta = CGPoint(x: 0, y: -distance)
        }
        let ids = editableSelectedIDs()
        applyGeometryDeltas(Dictionary(uniqueKeysWithValues: ids.map { ($0, delta) }))
    }

    @discardableResult
    func copyAppearance(of id: UUID) -> Bool {
        guard let source = photos.first(where: { $0.id == id && $0.desktopCollage == nil }) else { return false }
        copiedAppearanceStyle = WidgetAppearanceStyle(source)
        return true
    }

    @discardableResult
    func copySelectedStyle() -> Bool {
        guard let source = photos.first(where: { selectedPhotoIDs.contains($0.id) && $0.desktopCollage == nil }) else { return false }
        return copyAppearance(of: source.id)
    }

    var canPasteSelectedAppearance: Bool {
        canPasteAppearance(to: selectedPhotoIDs)
    }

    func canPasteAppearance(to ids: Set<UUID>) -> Bool {
        hasCopiedAppearanceStyle && !appearancePasteTargets(ids).isEmpty
    }

    private func appearancePasteTargets(_ ids: Set<UUID>) -> [Int] {
        let targets = photos.indices.filter { ids.contains(photos[$0].id) && photos[$0].desktopCollage == nil }
        let affectedIDs = Set(targets.map { photos[$0].id }).union(targets.compactMap { photos[$0].collageParentID })
        guard !hasArrangementInteraction(affecting: affectedIDs) else { return [] }
        return targets
    }

    @discardableResult
    func pasteSelectedStyle() -> Bool { pasteAppearance(to: selectedPhotoIDs) }

    /// Settings edits work on hidden and position-locked photos too. Commit the whole
    /// change before updating windows, whose geometry callbacks may otherwise save midway.
    @discardableResult
    func pasteAppearance(to ids: Set<UUID>) -> Bool {
        guard let style = copiedAppearanceStyle else { return false }
        let targets = appearancePasteTargets(ids)
        guard !targets.isEmpty else { return false }
        let originals = photos
        for index in targets {
            let focalPoint = photos[index].focalPoint
            style.apply(to: &photos[index])
            // Framing is specific to each image, not part of a reusable look.
            photos[index].focalPoint = focalPoint
        }
        let parents = Set(targets.compactMap { photos[$0].collageParentID })
        for parent in parents { fitCollageModel(parent) }
        guard persist() else { photos = originals; return false }
        for index in targets { refreshLiveAppearance(photos[index]) }
        for parent in parents { fitCollageWindow(parent) }
        syncCollages(only: parents)
        return true
    }

    /// Duplicates only selected widgets that currently have a live, editable window. The
    /// existing single-widget duplicate path remains available; this wrapper suppresses its
    /// internal saves and commits all selected duplicates with one durable write.
    @discardableResult
    func duplicateSelectedPhotos() -> Int {
        let ids = editableSelectedIDs()
        guard !ids.isEmpty else { return 0 }

        let originalPhotos = photos
        let originalIDs = Set(originalPhotos.map(\.id))
        let originalFilenames = Set(originalPhotos.flatMap { storedFilenamesForSelection($0) })
        let originalSelection = selectedPhotoIDs
        let originalAnchor = selectionAnchorID

        persistenceSuppressed = true
        var createdIDs: [UUID] = []
        for id in ids {
            let before = Set(photos.map(\.id))
            duplicatePhoto(id)
            if let newID = photos.map(\.id).first(where: { !before.contains($0) }) {
                createdIDs.append(newID)
            }
        }
        persistenceSuppressed = false

        guard !createdIDs.isEmpty, persist() else {
            persistenceSuppressed = false
            let newIDs = Set(photos.map(\.id)).subtracting(originalIDs)
            for id in newIDs {
                windows[id]?.hidePhoto()
                windows.removeValue(forKey: id)
                cancelRotationTimer(for: id)
                stopLiveFolderWatcherForSelection(id)
                spaceImages.removeValue(forKey: id)
            }
            let newFilenames = Set(photos.flatMap { storedFilenamesForSelection($0) }).subtracting(originalFilenames)
            photos = originalPhotos
            selectedPhotoIDs = originalSelection
            selectionAnchorID = originalAnchor
            for filename in newFilenames {
                try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(filename))
            }
            return 0
        }

        selectedPhotoIDs = Set(createdIDs)
        selectionAnchorID = createdIDs.last
        return createdIDs.count
    }

    /// Handles the settings-window keyboard affordances. Returning true consumes the event;
    /// Command-V returns false when no style has been copied so the existing image-paste path
    /// can continue to work.
    @discardableResult
    func handleSelectionKey(_ event: NSEvent) -> Bool {
        let flags = WidgetSelectionModifiers(eventFlags: event.modifierFlags)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.contains(.command), characters == "z" {
            return flags.contains(.shift) ? redoArrangement() : undoArrangement()
        }
        if flags.contains(.command), characters == "a" {
            selectAllPhotos()
            return true
        }
        if flags.contains(.command), characters == "d" {
            return duplicateSelectedPhotos() > 0
        }
        if flags.contains(.command), characters == "c" {
            return copySelectedStyle()
        }
        if flags.contains(.command), characters == "v" {
            return pasteSelectedStyle()
        }
        if event.keyCode == 53 { // Escape
            guard !selectedPhotoIDs.isEmpty else { return false }
            clearPhotoSelection()
            return true
        }

        switch event.keyCode {
        case 123: nudgeSelected(.left, modifiers: flags); return !editableSelectedIDs().isEmpty
        case 124: nudgeSelected(.right, modifiers: flags); return !editableSelectedIDs().isEmpty
        case 125: nudgeSelected(.down, modifiers: flags); return !editableSelectedIDs().isEmpty
        case 126: nudgeSelected(.up, modifiers: flags); return !editableSelectedIDs().isEmpty
        default: return false
        }
    }

    private func editableSelectedIDs() -> [UUID] {
        photos.compactMap { item in
            guard selectedPhotoIDs.contains(item.id),
                  item.isVisible,
                  !item.isHiddenForDisplay,
                  !item.isHiddenForPresence,
                  !isEffectivelyLocked(item),
                  (photos.first { $0.id == item.collageParentID }?.depth ?? item.depth).isInteractive,
                  let window = windows[item.id],
                  window.photoId == item.id,
                  window.isVisible else { return nil }
            return item.id
        }
    }

    private func updateLiveFocalPoint(for item: PhotoItem) {
        let appliesToCrop = !item.spaceImageFilenames.isEmpty && item.folderSizeMode == "fixed"
        guard let window = windows[item.id],
              let view = window.contentView as? DraggablePhotoView else { return }
        view.setFocalPoint(item.focalPoint, cropEnabled: appliesToCrop)
    }

    private func editableGeometryItems() -> [WidgetGeometryItem] {
        let ids = editableSelectedIDs()
        return ids.compactMap { id in
            if let parent = photos.first(where: { $0.id == id })?.collageParentID, ids.contains(parent) { return nil }
            guard let window = windows[id],
                  let item = photos.first(where: { $0.id == id }) else { return nil }
            return WidgetGeometryItem(
                id: id,
                photoFrame: window.photoFrame,
                visualFrame: WidgetSelectionGeometry.visibleFootprint(
                    window.visualFrame,
                    tiltDegrees: CGFloat(item.tiltDegrees)
                )
            )
        }
    }

    /// Arrangement is deliberately local to one display. Screen coordinates are global, so
    /// aligning a selection that spans side-by-side displays would otherwise pull a widget
    /// across a monitor boundary solely because that monitor happens to have a lower origin.
    /// Nudge remains a multi-display operation because it preserves each selected widget's
    /// relative location; alignment and distribution establish a shared local composition.
    private func arrangeableGeometryItems() -> [WidgetGeometryItem] {
        let items = editableGeometryItems()
        guard !items.isEmpty else { return [] }
        let displayIDs = items.compactMap { displayIdentifier(for: $0) }
        guard displayIDs.count == items.count, Set(displayIDs).count == 1 else { return [] }
        return items
    }

    private func displayIdentifier(for item: WidgetGeometryItem) -> String? {
        let center = CGPoint(x: item.photoFrame.midX, y: item.photoFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? windows[item.id]?.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(item.photoFrame) })
        return screen.map(DisplayManager.identifier(for:))
    }

    @discardableResult
    private func applyGeometryDeltas(_ deltas: [UUID: CGPoint], name: String = "Move Photos") -> Bool {
        let applicable = editableGeometryItems().filter { deltas[$0.id] != nil }
        guard !applicable.isEmpty else { return false }

        var moves: [UUID: CGPoint] = [:]
        for item in applicable {
            guard let delta = deltas[item.id] else { continue }
            moves[item.id] = delta
            if photos.first(where: { $0.id == item.id })?.desktopCollage != nil {
                for child in collageMembers(item.id) { moves[child.id] = delta }
            }
        }
        let affectedParents = Set(photos.filter { moves[$0.id] != nil }.compactMap(\.collageParentID)).subtracting(moves.keys)
        let affectedIDs = Set(moves.keys).union(affectedParents)
        // An arrangement command must not discard another window's unsaved
        // collage draft or cancel a gesture that still owns these positions.
        guard !hasArrangementInteraction(affecting: affectedIDs) else { return false }
        let affectedCollages = Set(photos.filter {
            affectedIDs.contains($0.id) && $0.desktopCollage != nil
        }.map(\.id))
        let historyBefore = arrangementSnapshot(ids: affectedIDs)
        let originals = Dictionary(uniqueKeysWithValues: photos.filter { affectedIDs.contains($0.id) }.map { item in
            (item.id, (item, collageFrame(item)))
        })
        guard originals.count == affectedIDs.count else { return false }

        for (id, delta) in moves {
            guard let index = photos.firstIndex(where: { $0.id == id }),
                  let originalFrame = originals[id]?.1 else { continue }
            let frame = originalFrame.offsetBy(dx: delta.x, dy: delta.y)
            windows[id]?.setPhotoFrame(frame)
            photos[index].frameString = NSStringFromRect(frame)
            photos[index].widgetWidth = frame.width
            for key in Array(photos[index].folderImageConfigs.keys) {
                if var config = photos[index].folderImageConfigs[key] {
                    config.frameString = NSStringFromRect(NSRectFromString(config.frameString).offsetBy(dx: delta.x, dy: delta.y))
                    photos[index].folderImageConfigs[key] = config
                }
            }
            if let displayID = displayIdentifier(for: WidgetGeometryItem(
                id: id,
                photoFrame: frame,
                visualFrame: windows[id]?.visualFrame ?? frame
            )) {
                photos[index].displayIdentifier = displayID
                photos[index].savedDisplayFrames[displayID] = NSStringFromRect(frame)
            }

            if photos[index].folderSizeMode == "dynamic",
               let currentImage = windowCurrentImageFilename(for: id) {
                photos[index].folderImageConfigs[currentImage] = FolderImageConfig(
                    frameString: NSStringFromRect(frame),
                    widgetWidth: frame.width
                )
            }
        }

        for parent in affectedParents { fitCollageModel(parent) }

        if !persist() {
            for (id, (item, frame)) in originals {
                if let index = photos.firstIndex(where: { $0.id == id }) { photos[index] = item }
                windows[id]?.setPhotoFrame(frame)
            }
            syncCollages(only: affectedCollages)
            return false
        }
        for parent in affectedParents { fitCollageWindow(parent) }
        syncCollages(only: affectedCollages)
        recordArrangement(name: name, before: historyBefore, after: arrangementSnapshot(ids: affectedIDs))
        return true
    }

    private func storedFilenamesForSelection(_ item: PhotoItem) -> [String] {
        var names: [String] = []
        if !item.filename.isEmpty { names.append(item.filename) }
        if let poster = item.media.posterFilename, !poster.isEmpty { names.append(poster) }
        if let paired = item.media.pairedVideoFilename, !paired.isEmpty { names.append(paired) }
        names.append(contentsOf: item.spaceImageFilenames)
        names.append(contentsOf: item.liveFolderEntries.map(\.managedFilename))
        names.append(contentsOf: item.photosLibraryAssets.flatMap(\.managedFilenames))
        return names
    }

    private func windowCurrentImageFilename(for id: UUID) -> String? {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              let images = spaceImages[id],
              let image = images[safe: photos[index].folderImageIndex] else { return nil }
        return image.lastPathComponent
    }
}

enum WidgetListFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case visible = "Visible"
    case hidden = "Hidden"
    case slideshows = "Slideshows"
    case collages = "Collages"
    case linked = "Linked sources"
    var id: String { rawValue }
}

extension PhotoManager {
    func visibilityExplanation(for item: PhotoItem) -> String? {
        if !item.isVisible { return "Hidden by you" }
        if let parentID = item.collageParentID,
           let parent = photos.first(where: { $0.id == parentID }) {
            if !parent.isVisible { return "Hidden with collage" }
            if parent.isHiddenForDisplay { return "Collage waiting for display" }
            if parent.isHiddenForPresence { return "Collage hidden by Privacy settings" }
        }
        if item.isHiddenForDisplay { return "Waiting for display" }
        if item.isHiddenForPresence {
            return isConferencingAppDetected && autoHideForConferencingApps
                ? "Hidden while a call app is running" : "Hidden by fullscreen settings"
        }
        return nil
    }

    func matchesWidgetList(_ item: PhotoItem, query: String, filter: WidgetListFilter) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || label(for: item).localizedCaseInsensitiveContains(text) else { return false }
        switch filter {
        case .all: return true
        case .visible: return visibilityExplanation(for: item) == nil
        case .hidden: return visibilityExplanation(for: item) != nil
        case .slideshows: return !item.spaceImageFilenames.isEmpty
        case .collages: return item.desktopCollage != nil
        case .linked: return item.liveFolderSource != nil || item.photosLibrarySource != nil
        }
    }

    func filteredWidgetRoots(query: String, filter: WidgetListFilter) -> [PhotoItem] {
        collageRootItems.filter { item in
            matchesWidgetList(item, query: query, filter: filter)
                || (item.desktopCollage != nil && collageMembers(item.id).contains {
                    matchesWidgetList($0, query: query, filter: filter)
                })
        }
    }
}
