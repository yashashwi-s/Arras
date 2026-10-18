import Foundation

/// The bounded set of actions available to a widget's double-click gesture.
///
/// Desktop widgets are intentionally not an arbitrary action host. Keeping this enum small
/// makes the interaction predictable and lets old layouts decode safely if a future action is
/// added later.
enum WidgetClickAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case advance
    case quickLook
    case revealStoredMedia
    case copyPath

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .advance: return "Advance"
        case .quickLook: return "Quick Look"
        case .revealStoredMedia: return "Reveal Stored Media"
        case .copyPath: return "Copy Path"
        }
    }

    init?(persistedValue: String) {
        switch persistedValue {
        case "advance", "next", "nextImage": self = .advance
        case "quickLook", "quick-look", "preview": self = .quickLook
        case "revealStoredMedia", "reveal", "revealInFinder": self = .revealStoredMedia
        case "copyPath", "copy": self = .copyPath
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(persistedValue: raw) ?? .advance
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

}
