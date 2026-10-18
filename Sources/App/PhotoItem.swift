import Foundation
import AppKit

/// Per-image configuration within a folder (position + size saved independently).
struct FolderImageConfig: Codable, Equatable {
    var frameString: String
    var widgetWidth: CGFloat

    init(frameString: String = "", widgetWidth: CGFloat = 300) {
        self.frameString = frameString
        self.widgetWidth = widgetWidth
    }
}

/// Represents a single photo placed on the desktop.
struct PhotoItem: Identifiable, Codable {
    var desktopCollage: DesktopCollageSettings? = nil
    var collageParentID: UUID? = nil
    let id: UUID
    var filename: String        // stored in app support dir
    /// Durable media metadata.  Missing in pre-video layouts, where it decodes to `.still`.
    var media: PhotoMedia
    var frameString: String     // NSStringFromRect
    var widgetWidth: CGFloat
    var isLocked: Bool
    var isVisible: Bool

    /// Decode-only marker: retired empty containers are omitted when loading/importing.
    var isRetiredCompositionContainer = false

    /// Linked sources own their membership; manual edits would be overwritten on refresh.
    var allowsManualMediaEditing: Bool {
        desktopCollage == nil && liveFolderSource == nil && photosLibrarySource == nil
    }

    // Floating Mode
    /// Superseded by `depth`, but still written on every save so that downgrading to an older
    /// build doesn't strand a floating widget back on the desktop. Keep the two in sync.
    var isFloating: Bool
    var opacity: CGFloat
    var revealOnHover: Bool

    // Desktop stacking
    var depth: WidgetDepth
    /// Front-to-back order among widgets sharing a depth. Higher is nearer the front.
    /// Windows are created in ascending order on launch, so this survives a relaunch —
    /// AppKit's own ordering does not.
    var stackOrder: Int

    // Naming
    var customName: String?

    // Aesthetic Controls
    var cornerRadius: CGFloat
    var shadowEnabled: Bool
    var shadowBlur: CGFloat
    var shadowOpacity: CGFloat
    var borderWidth: CGFloat
    var borderColorHex: String
    var vignetteEnabled: Bool

    // Borders, frames & depth
    // Raw Strings rather than typed enums, matching folderSizeMode/rotationInterval below --
    // an unrecognized value on decode (e.g. from a future version) falls back to a sane
    // default instead of failing the whole decode.
    var matWidth: CGFloat            // 0 = no mat (passe-partout)
    var matColorHex: String
    var shapeMask: String            // "roundedRect", "circle", "squircle", "arch"
    var borderStyle: String          // "solid", "dashed", "dotted"
    var borderGradientEnabled: Bool
    var borderGradientColorHex: String
    var tiltDegrees: Double           // small rotation for a scattered-pile look
    var stylePreset: String?         // last-applied named preset, for the picker's selection; nil once hand-tuned away from any preset

    // Smart Canvas (Spaces)
    var spaceImageFilenames: [String]
    var folderSizeMode: String         // "dynamic" or "fixed"
    var rotationInterval: String       // "click", "30s", "5m", "hourly", "daily", "custom"
    var folderImageIndex: Int
    var customRotationSeconds: Int     // used when rotationInterval == "custom"
    var folderImageConfigs: [String: FolderImageConfig]  // per-image position/size, keyed by filename

    // Finder-backed Spaces. The managed filenames above remain the render source; these
    // optional fields only describe how a Space can be reconciled with its original folder.
    var liveFolderSource: LiveFolderSource?
    var liveFolderEntries: [LiveFolderEntry]

    // Photos library-backed Spaces. Managed filenames remain the render source, while these
    // optional values describe the collection and asset identities used for reconciliation.
    // Missing values preserve every pre-Photos layout unchanged on decode.
    var photosLibrarySource: PhotosLibrarySource?
    var photosLibraryAssets: [PhotosLibraryAsset]

    // Space playback policy. The seed, step, and no-repeat history make random choices
    // deterministic across a save/relaunch instead of depending on process-local RNG state.
    var playbackOrder: SpacePlaybackOrder
    var playbackSeed: UInt64
    var playbackStep: UInt64
    var playbackHistory: [String]

    // Per-widget double-click action.
    var clickAction: WidgetClickAction

    // Optional normalized crop focus. Fixed slideshows consume it; ordinary widgets
    // continue to render at their true ratio. Nil preserves the old
    // centred-crop behaviour and keeps existing photos.json files byte-compatible on decode.
    var focalPoint: NormalizedFocalPoint?
    var reference = PhotoReferenceSettings()

    // Archive provenance is keyed by stored filename so each slideshow image retains
    // its own source-fidelity record.
    // Older layouts decode to an empty map and therefore make no original-quality claim.
    var mediaFidelity: [String: ArchiveMediaFidelity]

    // Per-Display Profiles, Space Binding
    var displayIdentifier: String?              // stable ID (see DisplayManager) of the display this photo currently belongs to; nil = not yet assigned (e.g. photos saved before this feature existed)
    var savedDisplayFrames: [String: String]    // last known frameString per displayIdentifier, so a photo restores exactly where it was when its display reconnects
    var isHiddenForDisplay: Bool                // true when auto-hidden because displayIdentifier's screen is currently disconnected — distinct from the user-controlled isVisible
    var isSpaceBound: Bool                      // pin to whichever Space the window is on instead of joining all Spaces (see DesktopPhotoWindow.setSpaceBound)

    // Retired schedule fields. Retained in the Codable model so existing photos.json and
    // .arras payloads continue to decode; the runtime no longer exposes or evaluates them.
    var scheduleEnabled: Bool
    var scheduleStartMinutes: Int
    var scheduleEndMinutes: Int
    var scheduleWeekdays: Int

    // Presence & Privacy
    var isHiddenForPresence: Bool               // true when auto-hidden by fullscreen/conferencing detection — distinct from isVisible, same precedent as isHiddenForDisplay

    init(filename: String, width: CGFloat = 300) {
        self.id = UUID()
        self.filename = filename
        self.media = .still
        self.frameString = ""
        self.widgetWidth = width
        self.isLocked = false
        self.isVisible = true

        self.isFloating = false
        self.opacity = 1.0
        self.revealOnHover = false
        self.depth = .onDesktop
        self.stackOrder = 0

        self.customName = nil

        self.cornerRadius = 16
        self.shadowEnabled = true
        self.shadowBlur = 10
        self.shadowOpacity = 0.3
        self.borderWidth = 0
        self.borderColorHex = "#FFFFFF"
        self.vignetteEnabled = false

        self.matWidth = 0
        self.matColorHex = "#FFFFFF"
        self.shapeMask = "roundedRect"
        self.borderStyle = "solid"
        self.borderGradientEnabled = false
        self.borderGradientColorHex = "#000000"
        self.tiltDegrees = 0
        self.stylePreset = nil

        self.spaceImageFilenames = []
        self.folderSizeMode = "dynamic"
        self.rotationInterval = "click"
        self.folderImageIndex = 0
        self.customRotationSeconds = 60
        self.folderImageConfigs = [:]
        self.liveFolderSource = nil
        self.liveFolderEntries = []
        self.photosLibrarySource = nil
        self.photosLibraryAssets = []

        // Preserve the old Space behavior (the existing On Click control
        // advanced a Space) while giving every new widget the same explicit, bounded action.
        self.playbackOrder = .ordered
        self.playbackSeed = SpacePlaybackSeed.forID(self.id)
        self.playbackStep = 0
        self.playbackHistory = []
        self.clickAction = .advance

        // Ordinary widgets and legacy Spaces remain ordinary widgets; a collage
        // is opt-in and starts by showing every photo in full.
        self.focalPoint = nil
        self.mediaFidelity = [:]

        self.displayIdentifier = nil
        self.savedDisplayFrames = [:]
        self.isHiddenForDisplay = false
        self.isSpaceBound = false

        self.scheduleEnabled = false
        self.scheduleStartMinutes = 0
        self.scheduleEndMinutes = 1439
        self.scheduleWeekdays = 0b111_1111  // all seven days
        self.isHiddenForPresence = false
    }

    // MARK: - Backward-compatible decoding

    enum CodingKeys: String, CodingKey {
        case id, filename, media, frameString, widgetWidth, isLocked, isVisible
        case desktopCollage, collageParentID
        case isFloating, opacity, revealOnHover, depth, stackOrder
        case customName
        case cornerRadius, shadowEnabled, shadowBlur, shadowOpacity
        case borderWidth, borderColorHex, vignetteEnabled
        case matWidth, matColorHex, shapeMask, borderStyle
        case borderGradientEnabled, borderGradientColorHex, tiltDegrees, stylePreset
        case spaceImageFilenames, folderSizeMode, rotationInterval, folderImageIndex
        case customRotationSeconds, folderImageConfigs
        case liveFolderSource, liveFolderEntries
        case photosLibrarySource, photosLibraryAssets
        case playbackOrder, playbackSeed, playbackStep, playbackHistory
        case clickAction
        case focalPoint
        case reference
        case mediaFidelity
        case displayIdentifier, savedDisplayFrames, isHiddenForDisplay, isSpaceBound
        case scheduleEnabled, scheduleStartMinutes, scheduleEndMinutes, scheduleWeekdays
        case isHiddenForPresence
    }

    private enum RetiredCodingKeys: String, CodingKey {
        case composition, livingCollageImageFilenames, livingCollageHeroIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        desktopCollage = try c.decodeIfPresent(DesktopCollageSettings.self, forKey: .desktopCollage)
        collageParentID = try c.decodeIfPresent(UUID.self, forKey: .collageParentID)
        id = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        media = try c.decodeIfPresent(PhotoMedia.self, forKey: .media) ?? .still
        frameString = try c.decode(String.self, forKey: .frameString)
        widgetWidth = try c.decode(CGFloat.self, forKey: .widgetWidth)
        isLocked = try c.decode(Bool.self, forKey: .isLocked)
        isVisible = try c.decode(Bool.self, forKey: .isVisible)
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        isRetiredCompositionContainer = try retired.contains(.composition) && !retired.decodeNil(forKey: .composition) && filename.isEmpty && desktopCollage == nil

        isFloating = try c.decodeIfPresent(Bool.self, forKey: .isFloating) ?? false
        opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1.0
        revealOnHover = try c.decodeIfPresent(Bool.self, forKey: .revealOnHover) ?? false
        // Absent from every photos.json written before 2.3, so fall back to the boolean it
        // replaced rather than to a bare default — otherwise every existing floating widget
        // would silently drop back onto the desktop on first launch after updating.
        depth = try c.decodeIfPresent(WidgetDepth.self, forKey: .depth) ?? (isFloating ? .floating : .onDesktop)
        stackOrder = try c.decodeIfPresent(Int.self, forKey: .stackOrder) ?? 0

        customName = try c.decodeIfPresent(String.self, forKey: .customName)

        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 16
        shadowEnabled = try c.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true
        shadowBlur = try c.decodeIfPresent(CGFloat.self, forKey: .shadowBlur) ?? 10
        shadowOpacity = try c.decodeIfPresent(CGFloat.self, forKey: .shadowOpacity) ?? 0.3
        borderWidth = try c.decodeIfPresent(CGFloat.self, forKey: .borderWidth) ?? 0
        borderColorHex = try c.decodeIfPresent(String.self, forKey: .borderColorHex) ?? "#FFFFFF"
        vignetteEnabled = try c.decodeIfPresent(Bool.self, forKey: .vignetteEnabled) ?? false

        matWidth = try c.decodeIfPresent(CGFloat.self, forKey: .matWidth) ?? 0
        matColorHex = try c.decodeIfPresent(String.self, forKey: .matColorHex) ?? "#FFFFFF"
        shapeMask = try c.decodeIfPresent(String.self, forKey: .shapeMask) ?? "roundedRect"
        borderStyle = try c.decodeIfPresent(String.self, forKey: .borderStyle) ?? "solid"
        borderGradientEnabled = try c.decodeIfPresent(Bool.self, forKey: .borderGradientEnabled) ?? false
        borderGradientColorHex = try c.decodeIfPresent(String.self, forKey: .borderGradientColorHex) ?? "#000000"
        tiltDegrees = try c.decodeIfPresent(Double.self, forKey: .tiltDegrees) ?? 0
        stylePreset = try c.decodeIfPresent(String.self, forKey: .stylePreset)

        spaceImageFilenames = try c.decodeIfPresent([String].self, forKey: .spaceImageFilenames) ?? []
        // Migration: If they had a folderPath, we just ignore it since it's broken in Sandbox anyway
        folderSizeMode = try c.decodeIfPresent(String.self, forKey: .folderSizeMode) ?? "dynamic"
        rotationInterval = try c.decodeIfPresent(String.self, forKey: .rotationInterval) ?? "click"
        folderImageIndex = try c.decodeIfPresent(Int.self, forKey: .folderImageIndex) ?? 0
        customRotationSeconds = try c.decodeIfPresent(Int.self, forKey: .customRotationSeconds) ?? 60
        folderImageConfigs = try c.decodeIfPresent([String: FolderImageConfig].self, forKey: .folderImageConfigs) ?? [:]
        liveFolderSource = try c.decodeIfPresent(LiveFolderSource.self, forKey: .liveFolderSource)
        liveFolderEntries = try c.decodeIfPresent([LiveFolderEntry].self, forKey: .liveFolderEntries) ?? []
        photosLibrarySource = try c.decodeIfPresent(PhotosLibrarySource.self, forKey: .photosLibrarySource)
        photosLibraryAssets = try c.decodeIfPresent([PhotosLibraryAsset].self, forKey: .photosLibraryAssets) ?? []

        // Decode enum raw values explicitly so an unknown future policy/action falls back to a
        // useful current behavior instead of rejecting the entire photos.json store.
        if let rawOrder = try c.decodeIfPresent(String.self, forKey: .playbackOrder),
           let decodedOrder = SpacePlaybackOrder(persistedValue: rawOrder) {
            playbackOrder = decodedOrder
        } else {
            playbackOrder = .ordered
        }
        playbackSeed = try c.decodeIfPresent(UInt64.self, forKey: .playbackSeed)
            ?? SpacePlaybackSeed.forID(id)
        playbackStep = try c.decodeIfPresent(UInt64.self, forKey: .playbackStep) ?? 0
        playbackHistory = try c.decodeIfPresent([String].self, forKey: .playbackHistory) ?? []

        if let rawAction = try c.decodeIfPresent(String.self, forKey: .clickAction),
           let decodedAction = WidgetClickAction(persistedValue: rawAction) {
            clickAction = decodedAction
        } else {
            clickAction = .advance
        }

        // One-way retirement: keep every old combined-photo image in an ordinary slideshow.
        // These keys are never encoded, and no combined-photo renderer or editor remains.
        let retiredNames = try retired.decodeIfPresent([String].self, forKey: .livingCollageImageFilenames) ?? []
        if !retiredNames.isEmpty {
            if spaceImageFilenames.isEmpty {
                let hero = try retired.decodeIfPresent(Int.self, forKey: .livingCollageHeroIndex) ?? 0
                spaceImageFilenames = retiredNames
                folderImageIndex = min(max(0, hero), retiredNames.count - 1)
                folderSizeMode = "dynamic"
            } else {
                let existingNames = spaceImageFilenames
                spaceImageFilenames.append(contentsOf: retiredNames.filter { !existingNames.contains($0) })
                folderImageIndex = min(max(0, folderImageIndex), spaceImageFilenames.count - 1)
            }
            // Stale composition metadata must not discard a record that still owns media.
            isRetiredCompositionContainer = false
        }
        if !spaceImageFilenames.isEmpty, !spaceImageFilenames.indices.contains(folderImageIndex) {
            // Loading already displays the first image for a missing selection.
            // Keep Settings and later edits on that same valid slot, including
            // damaged values that would overflow the one-based image counter.
            folderImageIndex = 0
        }
        focalPoint = try c.decodeIfPresent(NormalizedFocalPoint.self, forKey: .focalPoint)
        reference = try c.decodeIfPresent(PhotoReferenceSettings.self, forKey: .reference) ?? PhotoReferenceSettings()
        mediaFidelity = try c.decodeIfPresent([String: ArchiveMediaFidelity].self, forKey: .mediaFidelity) ?? [:]

        displayIdentifier = try c.decodeIfPresent(String.self, forKey: .displayIdentifier)
        savedDisplayFrames = try c.decodeIfPresent([String: String].self, forKey: .savedDisplayFrames) ?? [:]
        isHiddenForDisplay = try c.decodeIfPresent(Bool.self, forKey: .isHiddenForDisplay) ?? false
        isSpaceBound = try c.decodeIfPresent(Bool.self, forKey: .isSpaceBound) ?? false

        scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? false
        scheduleStartMinutes = try c.decodeIfPresent(Int.self, forKey: .scheduleStartMinutes) ?? 0
        scheduleEndMinutes = try c.decodeIfPresent(Int.self, forKey: .scheduleEndMinutes) ?? 1439
        scheduleWeekdays = try c.decodeIfPresent(Int.self, forKey: .scheduleWeekdays) ?? 0b111_1111
        isHiddenForPresence = try c.decodeIfPresent(Bool.self, forKey: .isHiddenForPresence) ?? false
    }

    // MARK: - Helper

    var borderColor: NSColor {
        NSColor.fromHex(borderColorHex) ?? .white
    }

    var matColor: NSColor {
        NSColor.fromHex(matColorHex) ?? .white
    }

    var borderGradientColor: NSColor {
        NSColor.fromHex(borderGradientColorHex) ?? .black
    }
}

// MARK: - NSColor Hex Extension

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        guard hexSanitized.count == 6 else { return nil }
        var rgbValue: UInt64 = 0
        let scanner = Scanner(string: hexSanitized)
        guard scanner.scanHexInt64(&rgbValue), scanner.isAtEnd else { return nil }
        return NSColor(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
