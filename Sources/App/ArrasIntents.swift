import AppKit
import AppIntents

// MARK: - MainActor bridge

/// Reaches the single live `PhotoManager` that `AppDelegate` owns.
///
/// An intent's `perform()` runs outside `PhotoManager`'s `@MainActor`
/// isolation, and Shortcuts can invoke one whether or not the app has any
/// window open (it's an `LSUIElement`) -- there is no view hierarchy to walk
/// to find the manager. Constructing a fresh `PhotoManager` here instead would
/// give two owners of the same `photos.json`, each free to overwrite the
/// other's writes; this bridge exists purely to avoid that.
@MainActor
enum ArrasIntentBridge {
    static func manager() throws -> PhotoManager {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            throw ArrasIntentError.appNotReady
        }
        return delegate.manager
    }
}

enum ArrasIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case invalidImage
    case photoNotFound(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            return "Arras isn't ready yet. Try again in a moment."
        case .invalidImage:
            return "That file isn't an image Arras can display."
        case .photoNotFound(let name):
            return "No photo named \"\(name)\" was found."
        }
    }
}

extension PhotoManager {
    /// Case-insensitive lookup by the same label the menu bar and settings show
    /// (`customName`, or "Photo N"), so a Shortcut can refer to a photo the way
    /// the user actually sees it without needing its UUID.
    func photo(named name: String) -> PhotoItem? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return photos.first { label(for: $0).compare(target, options: .caseInsensitive) == .orderedSame }
    }
}

// MARK: - Add Photo

struct AddPhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Photo to Desktop"
    static var description = IntentDescription("Adds an image file as a new desktop widget in Arras.")

    @Parameter(title: "Image File")
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = try ArrasIntentBridge.manager()
        guard let image = NSImage(data: file.data) else {
            throw ArrasIntentError.invalidImage
        }
        manager.addPhoto(image)
        return .result()
    }
}

// MARK: - Toggle All Visibility

struct ToggleAllPhotosVisibilityIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle All Arras Photos"
    static var description = IntentDescription(
        "Shows every Arras photo widget, or hides them all if any are currently visible."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let manager = try ArrasIntentBridge.manager()
        let visible = manager.toggleAllVisibility()
        return .result(value: visible)
    }
}

// MARK: - Show / Hide a specific photo

struct ShowPhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Arras Photo"
    static var description = IntentDescription("Shows an Arras photo widget by name.")

    @Parameter(title: "Photo Name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = try ArrasIntentBridge.manager()
        guard let item = manager.photo(named: name) else {
            throw ArrasIntentError.photoNotFound(name)
        }
        if !item.isVisible {
            manager.toggleVisibility(item.id)
        }
        return .result()
    }
}

struct HidePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Hide Arras Photo"
    static var description = IntentDescription("Hides an Arras photo widget by name.")

    @Parameter(title: "Photo Name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = try ArrasIntentBridge.manager()
        guard let item = manager.photo(named: name) else {
            throw ArrasIntentError.photoNotFound(name)
        }
        if item.isVisible {
            manager.toggleVisibility(item.id)
        }
        return .result()
    }
}

// MARK: - Set Opacity

struct SetPhotoOpacityIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Arras Photo Opacity"
    static var description = IntentDescription("Sets an Arras photo widget's opacity, from 0 to 100 percent.")

    @Parameter(title: "Photo Name")
    var name: String

    @Parameter(title: "Opacity Percent")
    var opacityPercent: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = try ArrasIntentBridge.manager()
        guard let item = manager.photo(named: name) else {
            throw ArrasIntentError.photoNotFound(name)
        }
        // setOpacity itself clamps to the app's normal 0.1...1.0 range, so an
        // out-of-range percent from Shortcuts can't produce an invisible or
        // over-driven widget.
        manager.setOpacity(item.id, CGFloat(opacityPercent) / 100.0)
        return .result()
    }
}

// MARK: - Next / Previous image in a Space

struct NextSpaceImageIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Image in Arras Space"
    static var description = IntentDescription("Advances an Arras Space to its next image.")

    @Parameter(title: "Space Name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = try ArrasIntentBridge.manager()
        guard let item = manager.photo(named: name) else {
            throw ArrasIntentError.photoNotFound(name)
        }
        manager.nextFolderImage(item.id)
        return .result()
    }
}

struct PreviousSpaceImageIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Image in Arras Space"
    static var description = IntentDescription("Steps an Arras Space back to its previous image.")

    @Parameter(title: "Space Name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = try ArrasIntentBridge.manager()
        guard let item = manager.photo(named: name) else {
            throw ArrasIntentError.photoNotFound(name)
        }
        manager.prevFolderImage(item.id)
        return .result()
    }
}

// MARK: - Shortcuts / Spotlight phrases

struct ArrasShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddPhotoIntent(),
            phrases: [
                "Add a photo in \(.applicationName)",
                "Add a photo to \(.applicationName)"
            ],
            shortTitle: "Add Photo",
            systemImageName: "photo.badge.plus"
        )
        AppShortcut(
            intent: ToggleAllPhotosVisibilityIntent(),
            phrases: [
                "Toggle \(.applicationName) photos",
                "Show or hide \(.applicationName) photos"
            ],
            shortTitle: "Toggle All Photos",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: ShowPhotoIntent(),
            phrases: [
                "Show a photo in \(.applicationName)"
            ],
            shortTitle: "Show Photo",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: HidePhotoIntent(),
            phrases: [
                "Hide a photo in \(.applicationName)"
            ],
            shortTitle: "Hide Photo",
            systemImageName: "eye.slash"
        )
        AppShortcut(
            intent: SetPhotoOpacityIntent(),
            phrases: [
                "Set photo opacity in \(.applicationName)"
            ],
            shortTitle: "Set Photo Opacity",
            systemImageName: "circle.lefthalf.filled"
        )
        AppShortcut(
            intent: NextSpaceImageIntent(),
            phrases: [
                "Next image in \(.applicationName)"
            ],
            shortTitle: "Next Space Image",
            systemImageName: "arrow.right"
        )
        AppShortcut(
            intent: PreviousSpaceImageIntent(),
            phrases: [
                "Previous image in \(.applicationName)"
            ],
            shortTitle: "Previous Space Image",
            systemImageName: "arrow.left"
        )
    }
}
