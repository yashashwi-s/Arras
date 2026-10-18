import AppKit

enum CollageSkin: String, Codable, CaseIterable, Identifiable {
    case glass, polaroid, solid, transparent
    var id: String { rawValue }
    var title: String {
        switch self { case .glass: return "Liquid Glass"; case .polaroid: return "Polaroid"; case .solid: return "Solid"; case .transparent: return "Transparent" }
    }
}

enum CollageGlassStyle: String, Codable, CaseIterable, Identifiable {
    case system, clear
    var id: String { rawValue }
    var title: String { self == .system ? "System" : "Clear" }
}

enum CollagePreset: String, CaseIterable, Identifiable {
    case systemGlass, whitePolaroid, gallery, ink, transparent
    var id: String { rawValue }
    var title: String {
        switch self { case .systemGlass: return "System Glass"; case .whitePolaroid: return "White Polaroid"; case .gallery: return "Gallery"; case .ink: return "Ink"; case .transparent: return "Transparent" }
    }
}

struct DesktopCollageSettings: Codable, Equatable {
    var skin: CollageSkin = .glass
    var padding: CGFloat = 28
    var gap: CGFloat = 20
    var cornerRadius: CGFloat = 24
    var borderWidth: CGFloat = 0
    var borderColorHex: String = "#FFFFFF"
    var tintHex: String = "#F5EFE3"
    var glassStyle: CollageGlassStyle = .system
    var usesCustomTint = false
    var tintStrength: CGFloat = 0.16
    var caption: String = ""
    var compositionScale: CGFloat = 1
    var captionStyle = CollageLabelStyle.caption
    var labels: [CollageTextLabel] = []
    var freeCaptionBandHeight: CGFloat?

    init(skin: CollageSkin = .glass) {
        self.skin = skin
        if skin == .polaroid { cornerRadius = 2; tintHex = "#FFFFFF" }
        if skin == .solid { tintHex = "#F2F3F5"; cornerRadius = 18 }
    }

    var effectivePadding: CGFloat { padding * compositionScale }
    var effectiveGap: CGFloat { gap * compositionScale }
    var effectiveCornerRadius: CGFloat { cornerRadius * compositionScale }
    var effectiveBorderWidth: CGFloat { borderWidth * compositionScale }
    var captionHeight: CGFloat { caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 44 * compositionScale }
    var textLabels: [CollageTextLabel] { [CollageTextLabel(id: CollageTextLabel.captionID, text: caption, style: captionStyle)] + labels }
    var fontFileNames: Set<String> { Set(textLabels.compactMap { $0.style.fontFileName }) }
    func captionBandHeight(for width: CGFloat) -> CGFloat {
        guard captionHeight > 0 else { return 0 }
        // Keep the established strip when moving the caption, without letting
        // freely placed typography grow its own coordinate system.
        guard captionStyle.placement == .caption else { return min(240, freeCaptionBandHeight ?? 44) * compositionScale }
        let label = CollageTextLabel(id: CollageTextLabel.captionID, text: caption, style: captionStyle)
        let text = CollageTypography.text(label, settings: self, scale: compositionScale)
        let available = max(1, width - effectivePadding * 2) * captionStyle.widthFraction
        let size = CollageTypography.size(of: text, width: available)
        let angle = captionStyle.rotationDegrees * .pi / 180
        let height = abs(sin(angle)) * size.width + abs(cos(angle)) * size.height
        return min(240 * compositionScale, max(captionHeight, height + 12 * compositionScale))
    }

    mutating func applyPreset(_ preset: CollagePreset) {
        // A named look must not inherit a border or glass tint from the previous look.
        // Text, label placement and composition scale remain the user's own.
        borderWidth = 0
        borderColorHex = "#FFFFFF"
        glassStyle = .system
        usesCustomTint = false
        tintStrength = 0.16
        tintHex = "#F5EFE3"
        switch preset {
        case .systemGlass:
            skin = .glass; padding = 28; gap = 20; cornerRadius = 24
            glassStyle = .system; usesCustomTint = false; tintStrength = 0.16
        case .whitePolaroid:
            skin = .polaroid; padding = 28; gap = 20; cornerRadius = 2; tintHex = "#FFFFFF"
        case .gallery:
            skin = .solid; padding = 28; gap = 20; cornerRadius = 18; tintHex = "#F2F3F5"
        case .ink:
            skin = .solid; padding = 28; gap = 20; cornerRadius = 18; tintHex = "#202226"
        case .transparent:
            skin = .transparent; padding = 28; gap = 20; cornerRadius = 18
            borderWidth = 0
        }
    }

    func labelStyle(for id: UUID) -> CollageLabelStyle {
        id == CollageTextLabel.captionID ? captionStyle : labels.first { $0.id == id }?.style ?? CollageLabelStyle()
    }
    mutating func setLabelStyle(_ style: CollageLabelStyle, for id: UUID) {
        if id == CollageTextLabel.captionID { captionStyle = style }
        else if let i = labels.firstIndex(where: { $0.id == id }) { labels[i].style = style }
    }
    mutating func setLabelText(_ text: String, for id: UUID) {
        if id == CollageTextLabel.captionID { caption = String(text.prefix(180)) }
        else if let i = labels.firstIndex(where: { $0.id == id }) { labels[i].text = String(text.prefix(180)) }
    }
    mutating func reserveCaptionStripForFreePlacement(width: CGFloat) {
        if captionStyle.placement == .caption { freeCaptionBandHeight = captionBandHeight(for: width) / compositionScale }
    }
    var duration: TimeInterval { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (skin == .glass ? 0.46 : 0.30) }

    mutating func normalize() {
        padding = padding.isFinite ? min(80, max(12, padding)) : 28
        gap = gap.isFinite ? min(100, max(0, gap)) : 20
        cornerRadius = cornerRadius.isFinite ? min(60, max(0, cornerRadius)) : 24
        borderWidth = borderWidth.isFinite ? min(12, max(0, borderWidth)) : 0
        if NSColor.fromHex(borderColorHex) == nil { borderColorHex = "#FFFFFF" }
        if NSColor.fromHex(tintHex) == nil { tintHex = "#F5EFE3" }
        tintStrength = tintStrength.isFinite ? min(1, max(0, tintStrength)) : 0.16
        caption = String(caption.prefix(180))
        compositionScale = compositionScale.isFinite ? min(8, max(0.1, compositionScale)) : 1
        captionStyle.normalize()
        if let height = freeCaptionBandHeight {
            freeCaptionBandHeight = height.isFinite && height >= 0 ? min(240, height) : nil
        }
        labels = Array(labels.prefix(12))
        var ids: Set<UUID> = [CollageTextLabel.captionID]
        for i in labels.indices {
            labels[i].text = String(labels[i].text.prefix(180))
            labels[i].style.normalize()
            labels[i].style.placement = .free
            if !ids.insert(labels[i].id).inserted { labels[i].id = UUID(); ids.insert(labels[i].id) }
        }
    }

    enum CodingKeys: String, CodingKey { case skin, padding, gap, cornerRadius, borderWidth, borderColorHex, tintHex, glassStyle, usesCustomTint, tintStrength, caption, compositionScale, captionStyle, labels, freeCaptionBandHeight }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skin = CollageSkin(rawValue: try c.decodeIfPresent(String.self, forKey: .skin) ?? "") ?? .glass
        padding = try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 28
        gap = try c.decodeIfPresent(CGFloat.self, forKey: .gap) ?? 20
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? (skin == .polaroid ? 3 : 24)
        borderWidth = try c.decodeIfPresent(CGFloat.self, forKey: .borderWidth) ?? 0
        borderColorHex = try c.decodeIfPresent(String.self, forKey: .borderColorHex) ?? "#FFFFFF"
        tintHex = try c.decodeIfPresent(String.self, forKey: .tintHex) ?? "#F5EFE3"
        glassStyle = CollageGlassStyle(rawValue: try c.decodeIfPresent(String.self, forKey: .glassStyle) ?? "") ?? .system
        // The old preview always saved a cream tint, even when untouched. Adopt
        // system glass for that default while preserving deliberately chosen colors.
        usesCustomTint = try c.decodeIfPresent(Bool.self, forKey: .usesCustomTint) ?? (tintHex != "#F5EFE3")
        tintStrength = try c.decodeIfPresent(CGFloat.self, forKey: .tintStrength) ?? 0.16
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        compositionScale = try c.decodeIfPresent(CGFloat.self, forKey: .compositionScale) ?? 1
        captionStyle = try c.decodeIfPresent(CollageLabelStyle.self, forKey: .captionStyle) ?? .caption
        labels = try c.decodeIfPresent([CollageTextLabel].self, forKey: .labels) ?? []
        freeCaptionBandHeight = try c.decodeIfPresent(CGFloat.self, forKey: .freeCaptionBandHeight)
        normalize()
    }
}

enum CollageResizeCorner: CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    func anchor(in rect: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.maxY)
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    func movingPoint(in rect: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func frame(from rect: CGRect, scale: CGFloat) -> CGRect {
        CollageGeometry.scaled(rect, around: anchor(in: rect), by: scale)
    }

    func proposedScale(in rect: CGRect, delta: CGPoint) -> CGFloat {
        let anchor = anchor(in: rect), moving = movingPoint(in: rect)
        let dx = moving.x - anchor.x
        return 1 + delta.x / (abs(dx) > 0 ? dx : 1)
    }

    func gripCenter(in rect: CGRect, radius: CGFloat) -> CGPoint {
        let point = movingPoint(in: rect), anchor = anchor(in: rect)
        let inset = min(18, max(6, radius * 0.293))
        return CGPoint(x: point.x + (anchor.x > point.x ? inset : -inset),
                       y: point.y + (anchor.y > point.y ? inset : -inset))
    }
}

enum CollageGeometry {
    static let emptySize = CGSize(width: 160, height: 160)
    static let snapDistance: CGFloat = 10

    static func scaled(_ rect: CGRect, around anchor: CGPoint, by scale: CGFloat) -> CGRect {
        CGRect(x: anchor.x + (rect.minX - anchor.x) * scale,
               y: anchor.y + (rect.minY - anchor.y) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    /// Prefer open desktop space so an empty glass panel cannot cover the very
    /// photo the user wants to pick up and add to it.
    static func emptyFrame(in screen: CGRect, avoiding occupied: [CGRect]) -> CGRect {
        let preferred = CGRect(x: screen.midX - emptySize.width / 2, y: screen.midY - emptySize.height / 2, width: emptySize.width, height: emptySize.height)
        var candidates = [preferred]
        let area = screen.insetBy(dx: 24, dy: 24)
        if area.width >= emptySize.width && area.height >= emptySize.height {
            for x in stride(from: area.minX, through: area.maxX - emptySize.width, by: 48) {
                for y in stride(from: area.minY, through: area.maxY - emptySize.height, by: 48) {
                    candidates.append(CGRect(origin: CGPoint(x: x, y: y), size: emptySize))
                }
            }
        }
        candidates.sort { hypot($0.midX - screen.midX, $0.midY - screen.midY) < hypot($1.midX - screen.midX, $1.midY - screen.midY) }
        if let open = candidates.first(where: { candidate in occupied.allSatisfy { !$0.insetBy(dx: -20, dy: -20).intersects(candidate) } }) { return open }
        func overlap(_ candidate: CGRect) -> CGFloat {
            occupied.reduce(0) { total, rect in
                let intersection = rect.intersection(candidate)
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
        }
        return candidates.min { overlap($0) < overlap($1) } ?? preferred
    }

    /// Include the photo's existing mat and rotation, rather than covering or changing its image.
    static func footprint(_ item: PhotoItem, frame: CGRect) -> CGRect {
        let r = frame.insetBy(dx: -max(0, item.matWidth), dy: -max(0, item.matWidth))
        let angle = CGFloat(item.tiltDegrees) * .pi / 180
        let width = abs(cos(angle)) * r.width + abs(sin(angle)) * r.height
        let height = abs(sin(angle)) * r.width + abs(cos(angle)) * r.height
        return CGRect(x: r.midX - width / 2, y: r.midY - height / 2, width: width, height: height)
    }

    static func enclosing(_ footprints: [CGRect], fallback: CGRect, settings: DesktopCollageSettings) -> CGRect {
        guard let first = footprints.first else { return CGRect(origin: fallback.origin, size: CGSize(width: emptySize.width * settings.compositionScale, height: emptySize.height * settings.compositionScale)) }
        let content = footprints.dropFirst().reduce(first) { $0.union($1) }
        let r = content.insetBy(dx: -settings.effectivePadding, dy: -settings.effectivePadding)
        let caption = settings.captionBandHeight(for: r.width)
        return CGRect(x: r.minX, y: r.minY - caption,
                      width: r.width, height: r.height + caption)
    }

    static func accepts(_ photo: CGRect, body: CGRect, siblings: [CGRect], gap: CGFloat) -> Bool {
        if body.contains(CGPoint(x: photo.midX, y: photo.midY)) { return true }
        let overlap = body.intersection(photo)
        if !overlap.isNull && overlap.width * overlap.height >= min(body.width * body.height, photo.width * photo.height) * 0.25 { return true }
        // The padded edge is a drop zone too: an adjacent photo need not cover an existing one.
        return siblings.contains { sibling in
            let verticalOverlap = min(photo.maxY, sibling.maxY) - max(photo.minY, sibling.minY)
            let horizontalOverlap = min(photo.maxX, sibling.maxX) - max(photo.minX, sibling.minX)
            let horizontalGap = max(sibling.minX - photo.maxX, photo.minX - sibling.maxX)
            let verticalGap = max(sibling.minY - photo.maxY, photo.minY - sibling.maxY)
            return (verticalOverlap > min(photo.height, sibling.height) * 0.25 && horizontalGap >= 0 && abs(horizontalGap - gap) <= snapDistance)
                || (horizontalOverlap > min(photo.width, sibling.width) * 0.25 && verticalGap >= 0 && abs(verticalGap - gap) <= snapDistance)
        }
    }

    /// Entry stays precise; an accepted photo has room to move around corners.
    /// Only fixed body/member bounds count, never the growing hover surface.
    static func retains(_ photo: CGRect, body: CGRect, siblings: [CGRect], gap: CGFloat) -> Bool {
        if accepts(photo, body: body, siblings: siblings, gap: gap) { return true }
        return (siblings.isEmpty ? [body] : siblings).contains { anchor in
            let dx = max(0, anchor.minX - photo.maxX, photo.minX - anchor.maxX)
            let dy = max(0, anchor.minY - photo.maxY, photo.minY - anchor.maxY)
            return hypot(dx, dy) <= gap + 40
        }
    }

    /// Only a nearby axis changes. No packing, scaling, cropping, or distant attraction.
    static func snapped(_ photo: CGRect, siblings: [CGRect], gap: CGFloat) -> CGRect {
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for other in siblings {
            xs += [other.minX - photo.minX, other.midX - photo.midX, other.maxX - photo.maxX]
            ys += [other.minY - photo.minY, other.midY - photo.midY, other.maxY - photo.maxY]
            if min(photo.maxY, other.maxY) >= max(photo.minY, other.minY) - snapDistance {
                xs += [other.maxX + gap - photo.minX, other.minX - gap - photo.maxX]
            }
            if min(photo.maxX, other.maxX) >= max(photo.minX, other.minX) - snapDistance {
                ys += [other.maxY + gap - photo.minY, other.minY - gap - photo.maxY]
            }
        }
        func nearest(_ values: [CGFloat]) -> CGFloat {
            values.filter { abs($0) <= snapDistance }.min { abs($0) < abs($1) } ?? 0
        }
        return photo.offsetBy(dx: nearest(xs), dy: nearest(ys))
    }

    static func alignmentGuides(_ photo: CGRect, siblings: [CGRect], gap: CGFloat) -> [SnapGuide] {
        var guides: [SnapGuide] = []
        for other in siblings {
            for (a, b) in [(photo.minY, other.minY), (photo.midY, other.midY), (photo.maxY, other.maxY)] where abs(a - b) < 0.5 {
                guides.append(SnapGuide(orientation: .horizontal, position: a, start: min(photo.minX, other.minX), end: max(photo.maxX, other.maxX), style: .solid))
            }
            for (a, b) in [(photo.minX, other.minX), (photo.midX, other.midX), (photo.maxX, other.maxX)] where abs(a - b) < 0.5 {
                guides.append(SnapGuide(orientation: .vertical, position: a, start: min(photo.minY, other.minY), end: max(photo.maxY, other.maxY), style: .solid))
            }
            if abs(photo.minX - other.maxX - gap) < 0.5 || abs(other.minX - photo.maxX - gap) < 0.5 {
                let lower = max(photo.minY, other.minY), upper = min(photo.maxY, other.maxY)
                if upper > lower {
                    guides.append(SnapGuide(orientation: .horizontal, position: (lower + upper) / 2, start: min(photo.maxX, other.maxX), end: max(photo.minX, other.minX), style: .dotted))
                }
            }
        }
        return Array(guides.prefix(12))
    }

    /// Preserve the placement graph: only neighbors that used the old exact gap
    /// move. Free placements and overlaps are not repacked into a different layout.
    static func changingGap(_ frames: [CGRect], from old: CGFloat, to new: CGFloat) -> [CGRect] {
        guard old != new else { return frames }
        func offsets(horizontal: Bool) -> [CGFloat] {
            var edges: [[(Int, CGFloat)]] = Array(repeating: [], count: frames.count)
            for i in frames.indices {
                for j in frames.indices where i != j {
                    let a = frames[i], b = frames[j]
                    let overlap = horizontal ? min(a.maxY, b.maxY) - max(a.minY, b.minY) : min(a.maxX, b.maxX) - max(a.minX, b.minX)
                    let gap = horizontal ? b.minX - a.maxX : b.minY - a.maxY
                    if overlap > 0 && abs(gap - old) < 1 {
                        edges[i].append((j, new - old))
                        edges[j].append((i, old - new))
                    }
                }
            }
            var result: [CGFloat?] = Array(repeating: nil, count: frames.count)
            for root in frames.indices where result[root] == nil {
                result[root] = 0
                var queue = [root], cursor = 0
                while cursor < queue.count {
                    let node = queue[cursor]; cursor += 1
                    for (neighbor, delta) in edges[node] where result[neighbor] == nil {
                        result[neighbor] = result[node]! + delta
                        queue.append(neighbor)
                    }
                }
            }
            return result.map { $0 ?? 0 }
        }
        let xs = offsets(horizontal: true), ys = offsets(horizontal: false)
        return frames.indices.map { frames[$0].offsetBy(dx: xs[$0], dy: ys[$0]) }
    }

    static func interpolated(_ from: CGRect, _ to: CGRect, progress: Double) -> CGRect {
        let t = CGFloat(min(1, max(0, progress)))
        let ease = t * t * (3 - 2 * t)
        return CGRect(x: from.minX + (to.minX - from.minX) * ease,
                      y: from.minY + (to.minY - from.minY) * ease,
                      width: from.width + (to.width - from.width) * ease,
                      height: from.height + (to.height - from.height) * ease)
    }
}
