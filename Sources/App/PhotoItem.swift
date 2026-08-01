import Foundation
import AppKit

/// Per-image configuration within a folder (position + size saved independently).
struct FolderImageConfig: Codable {
    var frameString: String
    var widgetWidth: CGFloat

    init(frameString: String = "", widgetWidth: CGFloat = 300) {
        self.frameString = frameString
        self.widgetWidth = widgetWidth
    }
}

/// Represents a single photo placed on the desktop.
struct PhotoItem: Identifiable, Codable {
    let id: UUID
    var filename: String        // stored in app support dir
    var frameString: String     // NSStringFromRect
    var widgetWidth: CGFloat
    var isLocked: Bool
    var isVisible: Bool

    // v1.1 — Floating Mode
    /// Superseded by `depth`, but still written on every save so that downgrading to an older
    /// build doesn't strand a floating widget back on the desktop. Keep the two in sync.
    var isFloating: Bool
    var opacity: CGFloat

    // v2.3 — Desktop stacking
    var depth: WidgetDepth
    /// Front-to-back order among widgets sharing a depth. Higher is nearer the front.
    /// Windows are created in ascending order on launch, so this survives a relaunch —
    /// AppKit's own ordering does not.
    var stackOrder: Int

    // v1.2 — Naming
    var customName: String?

    // v1.3 — Aesthetic Controls
    var cornerRadius: CGFloat
    var shadowEnabled: Bool
    var shadowBlur: CGFloat
    var shadowOpacity: CGFloat
    var borderWidth: CGFloat
    var borderColorHex: String
    var vignetteEnabled: Bool

    // v2.1 — Borders, frames & depth
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

    // v1.4 — Smart Canvas (Spaces)
    var spaceImageFilenames: [String]
    var folderSizeMode: String         // "dynamic" or "fixed"
    var rotationInterval: String       // "click", "30s", "5m", "hourly", "daily", "custom"
    var folderImageIndex: Int
    var customRotationSeconds: Int     // used when rotationInterval == "custom"
    var folderImageConfigs: [String: FolderImageConfig]  // per-image position/size, keyed by filename

    // v1.5 — Per-Display Profiles, Space Binding
    var displayIdentifier: String?              // stable ID (see DisplayManager) of the display this photo currently belongs to; nil = not yet assigned (e.g. photos saved before this feature existed)
    var savedDisplayFrames: [String: String]    // last known frameString per displayIdentifier, so a photo restores exactly where it was when its display reconnects
    var isHiddenForDisplay: Bool                // true when auto-hidden because displayIdentifier's screen is currently disconnected — distinct from the user-controlled isVisible
    var isSpaceBound: Bool                      // pin to whichever Space the window is on instead of joining all Spaces (see DesktopPhotoWindow.setSpaceBound)

    // v1.6 — Schedule (see PresenceManager.Schedule for the active-window math)
    var scheduleEnabled: Bool                   // opt-in: only show this photo during the window below
    var scheduleStartMinutes: Int               // minutes after midnight, local time
    var scheduleEndMinutes: Int                 // minutes after midnight; less than start means an overnight window (e.g. 22:00-06:00)
    var scheduleWeekdays: Int                   // bitmask; bit (Calendar.weekday - 1), so bit 0 = Sunday ... bit 6 = Saturday

    // v1.6 — Presence & Privacy
    var isHiddenForPresence: Bool               // true when auto-hidden by schedule, a fullscreen app, or conferencing-app detection — distinct from isVisible, same precedent as isHiddenForDisplay

    init(filename: String, width: CGFloat = 300) {
        self.id = UUID()
        self.filename = filename
        self.frameString = ""
        self.widgetWidth = width
        self.isLocked = false
        self.isVisible = true

        // v1.1 defaults
        self.isFloating = false
        self.opacity = 1.0
        self.depth = .onDesktop
        self.stackOrder = 0

        // v1.2 defaults
        self.customName = nil

        // v1.3 defaults
        self.cornerRadius = 16
        self.shadowEnabled = true
        self.shadowBlur = 10
        self.shadowOpacity = 0.3
        self.borderWidth = 0
        self.borderColorHex = "#FFFFFF"
        self.vignetteEnabled = false

        // v2.1 defaults
        self.matWidth = 0
        self.matColorHex = "#FFFFFF"
        self.shapeMask = "roundedRect"
        self.borderStyle = "solid"
        self.borderGradientEnabled = false
        self.borderGradientColorHex = "#000000"
        self.tiltDegrees = 0
        self.stylePreset = nil

        // v1.4 defaults
        self.spaceImageFilenames = []
        self.folderSizeMode = "dynamic"
        self.rotationInterval = "click"
        self.folderImageIndex = 0
        self.customRotationSeconds = 60
        self.folderImageConfigs = [:]

        // v1.5 defaults
        self.displayIdentifier = nil
        self.savedDisplayFrames = [:]
        self.isHiddenForDisplay = false
        self.isSpaceBound = false

        // v1.6 defaults
        self.scheduleEnabled = false
        self.scheduleStartMinutes = 0
        self.scheduleEndMinutes = 1439
        self.scheduleWeekdays = 0b111_1111  // all seven days
        self.isHiddenForPresence = false
    }

    // MARK: - Backward-compatible decoding

    enum CodingKeys: String, CodingKey {
        case id, filename, frameString, widgetWidth, isLocked, isVisible
        case isFloating, opacity, depth, stackOrder
        case customName
        case cornerRadius, shadowEnabled, shadowBlur, shadowOpacity
        case borderWidth, borderColorHex, vignetteEnabled
        case matWidth, matColorHex, shapeMask, borderStyle
        case borderGradientEnabled, borderGradientColorHex, tiltDegrees, stylePreset
        case spaceImageFilenames, folderSizeMode, rotationInterval, folderImageIndex
        case customRotationSeconds, folderImageConfigs
        case displayIdentifier, savedDisplayFrames, isHiddenForDisplay, isSpaceBound
        case scheduleEnabled, scheduleStartMinutes, scheduleEndMinutes, scheduleWeekdays
        case isHiddenForPresence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        frameString = try c.decode(String.self, forKey: .frameString)
        widgetWidth = try c.decode(CGFloat.self, forKey: .widgetWidth)
        isLocked = try c.decode(Bool.self, forKey: .isLocked)
        isVisible = try c.decode(Bool.self, forKey: .isVisible)

        isFloating = try c.decodeIfPresent(Bool.self, forKey: .isFloating) ?? false
        opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1.0
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
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)
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
