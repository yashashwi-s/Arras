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

    var displayName: String {
        switch self {
        case .gallery: return "Gallery"
        case .polaroid: return "Polaroid"
        case .minimal: return "Minimal"
        case .modern: return "Modern"
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
            // A mounted print behind glass: white mat, hairline border, soft even shadow.
            return Values(
                cornerRadius: 4, shadowEnabled: true, shadowBlur: 14, shadowOpacity: 0.28,
                borderWidth: 1, borderColorHex: "#E5E5E5", borderStyle: .solid,
                borderGradientEnabled: false, borderGradientColorHex: "#000000",
                matWidth: 16, matColorHex: "#FFFFFF",
                shapeMask: .roundedRect, tiltDegrees: 0, vignetteEnabled: false
            )
        case .polaroid:
            // Thick mat, square corners, a slight tilt so a cluster reads as a scattered
            // pile of prints instead of a grid.
            return Values(
                cornerRadius: 2, shadowEnabled: true, shadowBlur: 12, shadowOpacity: 0.35,
                borderWidth: 0, borderColorHex: "#FFFFFF", borderStyle: .solid,
                borderGradientEnabled: false, borderGradientColorHex: "#000000",
                matWidth: 22, matColorHex: "#FAFAFA",
                shapeMask: .roundedRect, tiltDegrees: -3, vignetteEnabled: false
            )
        case .minimal:
            // No mat, no border -- just a quiet corner radius and a whisper of shadow.
            return Values(
                cornerRadius: 10, shadowEnabled: true, shadowBlur: 6, shadowOpacity: 0.16,
                borderWidth: 0, borderColorHex: "#FFFFFF", borderStyle: .solid,
                borderGradientEnabled: false, borderGradientColorHex: "#000000",
                matWidth: 0, matColorHex: "#FFFFFF",
                shapeMask: .roundedRect, tiltDegrees: 0, vignetteEnabled: false
            )
        case .modern:
            // Squircle crop with a colour-swept border -- the most "designed" of the four.
            return Values(
                cornerRadius: 24, shadowEnabled: true, shadowBlur: 18, shadowOpacity: 0.3,
                borderWidth: 3, borderColorHex: "#5AC8FA", borderStyle: .solid,
                borderGradientEnabled: true, borderGradientColorHex: "#FF2D95",
                matWidth: 0, matColorHex: "#FFFFFF",
                shapeMask: .squircle, tiltDegrees: 0, vignetteEnabled: true
            )
        }
    }
}
