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
    var isFloating: Bool
    var opacity: CGFloat

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

    // v1.4 — Smart Canvas (Spaces)
    var spaceImageFilenames: [String]
    var folderSizeMode: String         // "dynamic" or "fixed"
    var rotationInterval: String       // "click", "30s", "5m", "hourly", "daily", "custom"
    var folderImageIndex: Int
    var customRotationSeconds: Int     // used when rotationInterval == "custom"
    var folderImageConfigs: [String: FolderImageConfig]  // per-image position/size, keyed by filename

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

        // v1.4 defaults
        self.spaceImageFilenames = []
        self.folderSizeMode = "dynamic"
        self.rotationInterval = "click"
        self.folderImageIndex = 0
        self.customRotationSeconds = 60
        self.folderImageConfigs = [:]
    }

    // MARK: - Backward-compatible decoding

    enum CodingKeys: String, CodingKey {
        case id, filename, frameString, widgetWidth, isLocked, isVisible
        case isFloating, opacity
        case customName
        case cornerRadius, shadowEnabled, shadowBlur, shadowOpacity
        case borderWidth, borderColorHex, vignetteEnabled
        case spaceImageFilenames, folderSizeMode, rotationInterval, folderImageIndex
        case customRotationSeconds, folderImageConfigs
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

        customName = try c.decodeIfPresent(String.self, forKey: .customName)

        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 16
        shadowEnabled = try c.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true
        shadowBlur = try c.decodeIfPresent(CGFloat.self, forKey: .shadowBlur) ?? 10
        shadowOpacity = try c.decodeIfPresent(CGFloat.self, forKey: .shadowOpacity) ?? 0.3
        borderWidth = try c.decodeIfPresent(CGFloat.self, forKey: .borderWidth) ?? 0
        borderColorHex = try c.decodeIfPresent(String.self, forKey: .borderColorHex) ?? "#FFFFFF"
        vignetteEnabled = try c.decodeIfPresent(Bool.self, forKey: .vignetteEnabled) ?? false

        spaceImageFilenames = try c.decodeIfPresent([String].self, forKey: .spaceImageFilenames) ?? []
        // Migration: If they had a folderPath, we just ignore it since it's broken in Sandbox anyway
        folderSizeMode = try c.decodeIfPresent(String.self, forKey: .folderSizeMode) ?? "dynamic"
        rotationInterval = try c.decodeIfPresent(String.self, forKey: .rotationInterval) ?? "click"
        folderImageIndex = try c.decodeIfPresent(Int.self, forKey: .folderImageIndex) ?? 0
        customRotationSeconds = try c.decodeIfPresent(Int.self, forKey: .customRotationSeconds) ?? 60
        folderImageConfigs = try c.decodeIfPresent([String: FolderImageConfig].self, forKey: .folderImageConfigs) ?? [:]
    }

    // MARK: - Helper

    var borderColor: NSColor {
        NSColor.fromHex(borderColorHex) ?? .white
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
