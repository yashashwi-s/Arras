import AppKit

// MARK: - Shape Masks

/// Which silhouette a photo's frame, mat, image mask and shadow are all cut to. Kept as a
/// single enum + path function so every layer that needs the outline -- image mask, mat
/// fill, border stroke, shadow path -- derives from one source (`path(in:cornerRadius:)`)
/// instead of three slightly-different roundedRect calls drifting apart after a resize.
enum PhotoShapeMask: String, Codable, CaseIterable {
    case roundedRect
    case circle
    case squircle
    case arch

    var displayName: String {
        switch self {
        case .roundedRect: return "Rounded"
        case .circle: return "Circle"
        case .squircle: return "Squircle"
        case .arch: return "Arch"
        }
    }

    /// `rect` must be in the target layer's own local coordinates (origin .zero) -- callers
    /// are responsible for positioning the layer itself via `.frame`.
    func path(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        switch self {
        case .roundedRect:
            let r = max(0, min(cornerRadius, min(rect.width, rect.height) * 0.5))
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .circle:
            // An ellipse inscribed in the rect -- a true circle when the widget is square,
            // an oval otherwise. Forcing a literal circle would mean cropping to a square
            // sub-rect, which would silently disagree with the aspect ratio the resize
            // handles and snap engine already assume for this widget.
            return CGPath(ellipseIn: rect, transform: nil)
        case .squircle:
            // Not a true superellipse -- CGPath has no primitive for one -- but a heavily
            // rounded rect reads as a squircle at a glance, which is all this control is
            // for. Deliberately short of half the side: at exactly half, the straight edge
            // length hits zero and a rounded rect becomes a mathematically exact circle,
            // indistinguishable from .circle on a square frame.
            let r = min(rect.width, rect.height) * 0.38
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .arch:
            return Self.archPath(in: rect)
        }
    }

    /// Flat sides and bottom, a semicircular top -- a doorway/tombstone silhouette.
    /// Built by hand because CGPath(roundedRect:) has no way to round only the top two
    /// corners into a full semicircle while keeping the bottom square.
    private static func archPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let radius = min(rect.width / 2, rect.height)
        // DraggablePhotoView is not a flipped NSView, so +y is up and rect.maxY is the top.
        let springY = rect.maxY - radius
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: springY))
        if radius > 0 {
            path.addArc(
                center: CGPoint(x: rect.midX, y: springY),
                radius: radius,
                startAngle: .pi,
                endAngle: 0,
                clockwise: true
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: springY))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Border Style

enum PhotoBorderStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted

    var displayName: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .dotted: return "Dotted"
        }
    }
}

// MARK: - Style Presets

/// Bundles the appearance knobs into named looks. With this many individual controls,
/// presets are the actual interface for most users -- one click instead of eight.
enum StylePreset: String, Codable, CaseIterable {
    case gallery
    case polaroid
    case minimal
    case modern
    case museum
    case linen

    var displayName: String {
        switch self {
        // Keep the raw values stable: they are persisted in layouts. These names describe
        // the restrained result a person will actually see, rather than a visual trend.
        case .gallery: return "Thin Frame"
        case .polaroid: return "Print"
        case .minimal: return "Plain"
        case .modern: return "Soft Shadow"
        case .museum: return "Dark Mat"
        case .linen: return "Warm Paper"
        }
    }

    var detail: String {
        switch self {
        case .gallery: "A fine neutral edge with a subtle shadow."
        case .polaroid: "A warm paper mat around the whole photo."
        case .minimal: "Rounded corners, with no frame or shadow."
        case .modern: "Soft depth without a border or paper mat."
        case .museum: "A charcoal mount that gives bright photos room to glow."
        case .linen: "A generous warm mount with a fine, muted edge."
        }
    }

    /// The full set of appearance fields this preset writes. Returned as a struct rather than
    /// applied directly so PhotoManager can both persist it into PhotoItem and push it onto
    /// the live window in one place (see PhotoAppearanceControls.applyPreset).
    struct Values {
        var cornerRadius: CGFloat
        var shadowEnabled: Bool
        var shadowBlur: CGFloat
        var shadowOpacity: CGFloat
        var borderWidth: CGFloat
        var borderColorHex: String
        var borderStyle: PhotoBorderStyle
        var borderGradientEnabled: Bool
        var borderGradientColorHex: String
        var matWidth: CGFloat
        var matColorHex: String
        var shapeMask: PhotoShapeMask
        var tiltDegrees: Double
        var vignetteEnabled: Bool
    }

    var values: Values {
        switch self {
        case .gallery:
            // A quiet hairline around the photo. No mat means this also works at small sizes.
            return Values(
                cornerRadius: 6, shadowEnabled: true, shadowBlur: 8, shadowOpacity: 0.14,
                borderWidth: 1, borderColorHex: "#D1D1D6", borderStyle: .solid,
                borderGradientEnabled: false, borderGradientColorHex: "#000000",
                matWidth: 0, matColorHex: "#FFFFFF",
                shapeMask: .roundedRect, tiltDegrees: 0, vignetteEnabled: false
            )
        case .polaroid:
            // A printed photograph with enough breathing room to feel tactile, while still
            // preserving the photo's rectangular silhouette and its placement on the desktop.
            return Values(
                cornerRadius: 2, shadowEnabled: true, shadowBlur: 10, shadowOpacity: 0.22,
                borderWidth: 0, borderColorHex: "#FFFFFF", borderStyle: .solid,
                borderGradientEnabled: false, borderGradientColorHex: "#000000",
                matWidth: 16, matColorHex: "#FAFAFA",
                shapeMask: .roundedRect, tiltDegrees: 0, vignetteEnabled: false
            )
        case .minimal:
            // The image on its own. This is the reliable default for photos and collages.
            return Values(
                cornerRadius: 8, shadowEnabled: false, shadowBlur: 0, shadowOpacity: 0,
                borderWidth: 0, borderColorHex: "#FFFFFF", borderStyle: .solid,
                borderGradientEnabled: false, borderGradientColorHex: "#000000",
                matWidth: 0, matColorHex: "#FFFFFF",
                shapeMask: .roundedRect, tiltDegrees: 0, vignetteEnabled: false
            )
        case .museum:
            return Values(
                cornerRadius: 1, shadowEnabled: true, shadowBlur: 12, shadowOpacity: 0.24,
                borderWidth: 1, borderColorHex: "#45433F", borderStyle: .solid,
                borderGradientEnabled: false, borderGradientColorHex: "#000000",
                matWidth: 24, matColorHex: "#242320",
                shapeMask: .roundedRect, tiltDegrees: 0, vignetteEnabled: false
            )
        case .linen:
            return Values(
                cornerRadius: 0, shadowEnabled: true, shadowBlur: 8, shadowOpacity: 0.16,
                borderWidth: 1, borderColorHex: "#C9BDA8", borderStyle: .solid,
                borderGradientEnabled: false, borderGradientColorHex: "#000000",
                matWidth: 28, matColorHex: "#EDE4D3",
                shapeMask: .roundedRect, tiltDegrees: 0, vignetteEnabled: false
            )
        case .modern:
            // Depth without decoration. In particular, do not replace the photo silhouette
            // with a squircle, colour its edge, or darken its content.
            return Values(
                cornerRadius: 10, shadowEnabled: true, shadowBlur: 14, shadowOpacity: 0.20,
                borderWidth: 0, borderColorHex: "#FFFFFF", borderStyle: .solid,
                borderGradientEnabled: false, borderGradientColorHex: "#000000",
                matWidth: 0, matColorHex: "#FFFFFF",
                shapeMask: .roundedRect, tiltDegrees: 0, vignetteEnabled: false
            )
        }
    }
}


extension StylePreset {
    /// Shared by the real edit and its preview so a card cannot promise a different look.
    func applying(to original: PhotoItem) -> PhotoItem {
        var item = original
        let v = values

        item.stylePreset = rawValue
        item.cornerRadius = v.cornerRadius
        item.shadowEnabled = v.shadowEnabled
        item.shadowBlur = v.shadowBlur
        item.shadowOpacity = v.shadowOpacity
        item.borderWidth = v.borderWidth
        item.borderColorHex = v.borderColorHex
        item.borderStyle = v.borderStyle.rawValue
        item.borderGradientEnabled = v.borderGradientEnabled
        item.borderGradientColorHex = v.borderGradientColorHex
        item.matWidth = v.matWidth
        item.matColorHex = v.matColorHex
        item.shapeMask = v.shapeMask.rawValue
        item.tiltDegrees = v.tiltDegrees
        item.vignetteEnabled = v.vignetteEnabled

        return item
    }
}
