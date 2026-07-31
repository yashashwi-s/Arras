import Foundation

/// Which optional commands appear in the menu bar.
///
/// The menu is the app's front door and stays short by default. Niche importers
/// — screen-region capture, PDF pages — are genuinely useful to a few people and
/// noise to everyone else, so they are opt-in from Preferences rather than
/// occupying a permanent slot. Everything here is additive; the core commands
/// (Add Photo, Settings, Quit) are never configurable, because a menu you can
/// empty is a menu that can lock you out of the app.
@MainActor
final class MenuBarCustomization: ObservableObject {
    static let shared = MenuBarCustomization()

    enum Item: String, CaseIterable, Identifiable {
        case paste
        case captureRegion
        case pdfPage
        case addSpace
        case toggleAll
        case privacy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .paste: return "Paste as Widget"
            case .captureRegion: return "Capture Screen Region"
            case .pdfPage: return "Add PDF Page"
            case .addSpace: return "Add Space"
            case .toggleAll: return "Show / Hide All Photos"
            case .privacy: return "Privacy submenu"
            }
        }

        var detail: String {
            switch self {
            case .paste: return "Turn a copied image into a widget"
            case .captureRegion: return "Drag a region of the screen and pin it"
            case .pdfPage: return "Place a page of a PDF on the desktop"
            case .addSpace: return "Create a rotating set of photos"
            case .toggleAll: return "Clear the desktop and bring it back"
            case .privacy: return "Screen sharing and fullscreen behaviour"
            }
        }

        /// Shown unless the user says otherwise. The two importers most people
        /// will never use start hidden.
        var defaultsToVisible: Bool {
            switch self {
            case .captureRegion, .pdfPage: return false
            case .paste, .addSpace, .toggleAll, .privacy: return true
            }
        }
    }

    private func key(for item: Item) -> String { "menuBar.\(item.rawValue)" }

    func isVisible(_ item: Item) -> Bool {
        UserDefaults.standard.object(forKey: key(for: item)) as? Bool ?? item.defaultsToVisible
    }

    func setVisible(_ item: Item, _ visible: Bool) {
        objectWillChange.send()
        UserDefaults.standard.set(visible, forKey: key(for: item))
    }

}
