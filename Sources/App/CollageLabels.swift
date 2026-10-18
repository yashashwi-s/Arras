import AppKit

enum CollageLabelFont: String, Codable, CaseIterable, Identifiable {
    case modern, editorial, rounded, typewriter, handwritten, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modern: return "Modern"
        case .editorial: return "Editorial"
        case .rounded: return "Rounded"
        case .typewriter: return "Typewriter"
        case .handwritten: return "Handwritten"
        case .custom: return "Another Font"
        }
    }
}

enum CollageLabelWeight: String, Codable, CaseIterable, Identifiable {
    case original, regular, medium, semibold, bold
    var id: String { rawValue }
    var title: String { self == .original ? "Font Default" : rawValue.capitalized }
    var fontWeight: NSFont.Weight {
        switch self { case .original, .regular: return .regular; case .medium: return .medium; case .semibold: return .semibold; case .bold: return .bold }
    }
}

enum CollageLabelAlignment: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var textAlignment: NSTextAlignment {
        switch self { case .left: return .left; case .center: return .center; case .right: return .right }
    }
}

enum CollageLabelPlacement: String, Codable { case caption, free }

struct CollageLabelStyle: Codable, Equatable {
    var font: CollageLabelFont = .modern
    var fontName: String?
    var fontFileName: String?
    var fontSize: CGFloat = 24
    var weight: CollageLabelWeight = .regular
    var italic = false
    var colorHex: String?
    var opacity: CGFloat = 1
    var tracking: CGFloat = 0
    var lineSpacing: CGFloat = 0
    var alignment: CollageLabelAlignment = .center
    var rotationDegrees: CGFloat = 0
    var widthFraction: CGFloat = 0.7
    var positionX: CGFloat = 0.5
    var positionY: CGFloat = 0.5
    var placement: CollageLabelPlacement = .free
    var shadow = false

    static var caption: Self {
        var style = Self()
        style.fontSize = 16; style.weight = .medium; style.widthFraction = 1; style.placement = .caption
        return style
    }

    mutating func normalize() {
        func finite(_ value: CGFloat, _ range: ClosedRange<CGFloat>, _ fallback: CGFloat) -> CGFloat {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        fontSize = finite(fontSize, 10...96, 24)
        opacity = finite(opacity, 0...1, 1)
        tracking = finite(tracking, -2...12, 0)
        lineSpacing = finite(lineSpacing, 0...32, 0)
        rotationDegrees = finite(rotationDegrees, -180...180, 0)
        widthFraction = finite(widthFraction, 0.15...1, 0.7)
        positionX = finite(positionX, 0...1, 0.5)
        positionY = finite(positionY, 0...1, 0.5)
        if let colorHex, NSColor.fromHex(colorHex) == nil { self.colorHex = nil }
        fontName = fontName.map { String($0.prefix(160)) }
        if let name = fontFileName, !CollageFontLibrary.isManagedFilename(name) { fontFileName = nil }
    }

    enum CodingKeys: String, CodingKey {
        case font, fontName, fontFileName, fontSize, weight, italic, colorHex, opacity, tracking, lineSpacing,
             alignment, rotationDegrees, widthFraction, positionX, positionY, placement, shadow
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = CollageLabelFont(rawValue: try c.decodeIfPresent(String.self, forKey: .font) ?? "") ?? .modern
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        fontFileName = try c.decodeIfPresent(String.self, forKey: .fontFileName)
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 24
        weight = CollageLabelWeight(rawValue: try c.decodeIfPresent(String.self, forKey: .weight) ?? "") ?? .regular
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1
        tracking = try c.decodeIfPresent(CGFloat.self, forKey: .tracking) ?? 0
        lineSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .lineSpacing) ?? 0
        alignment = CollageLabelAlignment(rawValue: try c.decodeIfPresent(String.self, forKey: .alignment) ?? "") ?? .center
        rotationDegrees = try c.decodeIfPresent(CGFloat.self, forKey: .rotationDegrees) ?? 0
        widthFraction = try c.decodeIfPresent(CGFloat.self, forKey: .widthFraction) ?? 0.7
        positionX = try c.decodeIfPresent(CGFloat.self, forKey: .positionX) ?? 0.5
        positionY = try c.decodeIfPresent(CGFloat.self, forKey: .positionY) ?? 0.5
        placement = CollageLabelPlacement(rawValue: try c.decodeIfPresent(String.self, forKey: .placement) ?? "") ?? .free
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        normalize()
    }
}

struct CollageTextLabel: Codable, Equatable, Identifiable {
    static let captionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id = UUID()
    var text = "A memory"
    var style = CollageLabelStyle()

    init(id: UUID = UUID(), text: String = "A memory", style: CollageLabelStyle = CollageLabelStyle()) {
        self.id = id; self.text = text; self.style = style
    }

    enum CodingKeys: String, CodingKey { case id, text, style }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = String((try c.decodeIfPresent(String.self, forKey: .text) ?? "").prefix(180))
        style = try c.decodeIfPresent(CollageLabelStyle.self, forKey: .style) ?? CollageLabelStyle()
    }
}

enum CollageTypography {
    static func font(for style: CollageLabelStyle, scale: CGFloat = 1) -> NSFont {
        let size = max(0.1, style.fontSize * scale)
        let base: NSFont
        switch style.font {
        case .modern: base = .systemFont(ofSize: size, weight: style.weight.fontWeight)
        case .editorial:
            let system = NSFont.systemFont(ofSize: size, weight: style.weight.fontWeight)
            base = NSFont(name: "Georgia", size: size) ?? system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .rounded:
            let system = NSFont.systemFont(ofSize: size, weight: style.weight.fontWeight)
            base = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .typewriter: base = .monospacedSystemFont(ofSize: size, weight: style.weight.fontWeight)
        case .handwritten: base = NSFont(name: "Noteworthy", size: size) ?? NSFont(name: "ChalkboardSE-Regular", size: size) ?? .systemFont(ofSize: size)
        case .custom: base = style.fontName.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size, weight: style.weight.fontWeight)
        }
        let manager = NSFontManager.shared
        let weighted: NSFont
        if style.weight == .original || [.modern, .rounded, .typewriter].contains(style.font) { weighted = base }
        else {
            let weight = [CollageLabelWeight.regular: 5, .medium: 6, .semibold: 8, .bold: 9][style.weight]!
            let traits = manager.traits(of: base).subtracting([.boldFontMask, .italicFontMask])
            weighted = base.familyName.flatMap { manager.font(withFamily: $0, traits: traits, weight: weight, size: size) } ?? base
        }
        return style.italic ? manager.convert(weighted, toHaveTrait: .italicFontMask) : manager.convert(weighted, toNotHaveTrait: .italicFontMask)
    }

    static func color(for style: CollageLabelStyle, settings: DesktopCollageSettings) -> NSColor {
        if let hex = style.colorHex, let color = NSColor.fromHex(hex) { return color.withAlphaComponent(style.opacity) }
        let tint = NSColor.fromHex(settings.tintHex)?.usingColorSpace(.sRGB) ?? .white
        let color: NSColor = settings.skin == .glass || settings.skin == .transparent ? .labelColor : (tint.brightnessComponent > 0.55 ? NSColor(white: 0.12, alpha: 1) : .white)
        return color.withAlphaComponent(style.opacity)
    }

    static func text(_ label: CollageTextLabel, settings: DesktopCollageSettings, scale: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = label.style.alignment.textAlignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = label.style.lineSpacing * scale
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: label.style, scale: scale), .foregroundColor: color(for: label.style, settings: settings),
            .kern: label.style.tracking * scale, .paragraphStyle: paragraph
        ]
        if label.style.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3 * label.style.opacity)
            shadow.shadowBlurRadius = 2 * scale
            shadow.shadowOffset = CGSize(width: 0, height: -scale)
            attributes[.shadow] = shadow
        }
        return NSAttributedString(string: label.text, attributes: attributes)
    }

    static func size(of text: NSAttributedString, width: CGFloat) -> CGSize {
        let rect = text.boundingRect(with: CGSize(width: max(1, width), height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: max(1, width), height: max(1, ceil(rect.height)))
    }
}

struct CollageLabelLayout {
    let label: CollageTextLabel
    let text: NSAttributedString
    let rect: CGRect
    let rotation: CGFloat

    func contains(_ point: CGPoint) -> Bool {
        let dx = point.x - rect.midX, dy = point.y - rect.midY
        return rect.insetBy(dx: -4, dy: -4).contains(CGPoint(x: rect.midX + dx * cos(rotation) + dy * sin(rotation),
                                                         y: rect.midY - dx * sin(rotation) + dy * cos(rotation)))
    }

    static func layouts(settings: DesktopCollageSettings, in body: CGRect, previewScale: CGFloat = 1) -> [Self] {
        let scale = settings.compositionScale * previewScale
        let padding = settings.effectivePadding * previewScale
        return settings.textLabels.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.style.opacity > 0 }.map { label in
            let text = CollageTypography.text(label, settings: settings, scale: scale)
            let width = max(1, body.width - padding * 2) * label.style.widthFraction
            let rotation = label.style.rotationDegrees * .pi / 180
            // Free text never expands its own normalization frame. Keep its
            // rotated bounds inside the collage instead of chasing its position.
            let band = settings.captionBandHeight(for: body.width / previewScale) * previewScale
            let availableWidth = label.style.placement == .caption ? body.width - 2 * padding : body.width - 8 * previewScale
            let availableHeight = label.style.placement == .caption ? min(body.height - padding, band - 12 * scale) : body.height - 8 * previewScale
            let reserve = 2 * max(1, previewScale)
            let wrapWidth = max(1, min(width,
                abs(cos(rotation)) > 0.001 ? max(1, availableWidth - reserve * abs(sin(rotation))) / abs(cos(rotation)) : width,
                abs(sin(rotation)) > 0.001 ? max(1, availableHeight - reserve * abs(cos(rotation))) / abs(sin(rotation)) : width))
            var drawnText = text
            var size = CollageTypography.size(of: drawnText, width: wrapWidth)
            func fits(_ size: CGSize) -> Bool {
                abs(cos(rotation)) * size.width + abs(sin(rotation)) * size.height <= availableWidth + 0.01 &&
                    abs(sin(rotation)) * size.width + abs(cos(rotation)) * size.height <= availableHeight + 0.01
            }
            // Measure reflow at a fixed wrapping width; uniformly shrinking that
            // width too would preserve too many lines. Choose the largest fit.
            if !fits(size) {
                var lower: CGFloat = 0, upper: CGFloat = 1
                for _ in 0..<14 {
                    let factor = (lower + upper) / 2
                    let candidate = CollageTypography.text(label, settings: settings, scale: scale * factor)
                    let measured = CollageTypography.size(of: candidate, width: wrapWidth)
                    if fits(measured) { lower = factor } else { upper = factor }
                }
                drawnText = CollageTypography.text(label, settings: settings, scale: scale * max(0.001, lower))
                size = CollageTypography.size(of: drawnText, width: wrapWidth)
            }
            let halfWidth = (abs(cos(rotation)) * size.width + abs(sin(rotation)) * size.height) / 2
            let halfHeight = (abs(sin(rotation)) * size.width + abs(cos(rotation)) * size.height) / 2
            var center = CGPoint(x: body.minX + body.width * label.style.positionX, y: body.minY + body.height * label.style.positionY)
            if label.style.placement == .caption {
                center = CGPoint(x: body.midX, y: body.minY + padding / 2 + min(band, body.height - padding) / 2)
            }
            center.x = min(body.maxX - halfWidth, max(body.minX + halfWidth, center.x))
            center.y = min(body.maxY - halfHeight, max(body.minY + halfHeight, center.y))
            return Self(label: label, text: drawnText, rect: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), rotation: rotation)
        }
    }
}

@MainActor
final class CollageTextView: NSView {
    var layouts: [CollageLabelLayout] = [] { didSet { needsDisplay = true } }
    var showsContrastBacking = false { didSet { needsDisplay = true } }
    var selectedLabel: UUID? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        for layout in layouts {
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX: layout.rect.midX, byY: layout.rect.midY)
            (transform as NSAffineTransform).concat()
            let rotation = NSAffineTransform()
            rotation.rotate(byRadians: layout.rotation)
            rotation.concat()
            if showsContrastBacking {
                let color = (layout.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB) ?? .black
                let light = color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722 > 0.5
                (light ? NSColor.black : .white).withAlphaComponent(0.42).setFill()
                NSBezierPath(roundedRect: CGRect(x: -layout.rect.width / 2 - 3, y: -layout.rect.height / 2 - 2,
                                                width: layout.rect.width + 6, height: layout.rect.height + 4), xRadius: 3, yRadius: 3).fill()
            }
            if selectedLabel == layout.label.id {
                NSColor.controlAccentColor.setStroke()
                let outline = NSBezierPath(rect: CGRect(x: -layout.rect.width / 2 - 3, y: -layout.rect.height / 2 - 3,
                                                       width: layout.rect.width + 6, height: layout.rect.height + 6))
                outline.lineWidth = 1; outline.setLineDash([4, 3], count: 2, phase: 0); outline.stroke()
            }
            layout.text.draw(with: CGRect(x: -layout.rect.width / 2, y: -layout.rect.height / 2,
                                         width: layout.rect.width, height: layout.rect.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
