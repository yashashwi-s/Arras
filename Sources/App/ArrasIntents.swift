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
        guard let delegate = AppDelegate.current else {
            throw ArrasIntentError.appNotReady
        }
        return delegate.manager
    }
}

enum ArrasIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case invalidImage
    case photoNotFound(String)
    case importFailed(String)
    case couldNotSave
    case notASlideshow(String)
    case couldNotAdvance

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            return "Arras isn't ready yet. Try again in a moment."
        case .invalidImage:
            return "That file isn't an image Arras can display."
        case .photoNotFound(let name):
            return "No photo named \"\(name)\" was found."
        case .importFailed(let detail):
            return "The photo could not be added. \(detail)"
        case .couldNotSave:
            return "The change could not be saved. Check the library and available disk space, then try again."
        case .notASlideshow(let name):
            return "\"\(name)\" is not a slideshow. Choose a Space with stored images."
        case .couldNotAdvance:
            return "The slideshow could not change images. Finish any active edit, show the widget, and check its media and available disk space."
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
        let result = await manager.importPhotos(data: [file.data], sourceNames: ["Shortcut image"])
        guard result.acceptedCount == 1 else {
            throw ArrasIntentError.importFailed(result.failed.first?.reason ?? "The image could not be imported into this desktop.")
        }
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
        let requestedVisibility = !manager.photos.contains { $0.isVisible }
        let visible = manager.toggleAllVisibility()
        guard manager.photos.isEmpty || visible == requestedVisibility else { throw ArrasIntentError.couldNotSave }
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
            guard manager.toggleVisibility(item.id) else { throw ArrasIntentError.couldNotSave }
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
            guard manager.toggleVisibility(item.id) else { throw ArrasIntentError.couldNotSave }
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
        guard manager.setOpacity(item.id, CGFloat(opacityPercent) / 100.0) else { throw ArrasIntentError.couldNotSave }
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
        guard !item.spaceImageFilenames.isEmpty else { throw ArrasIntentError.notASlideshow(name) }
        guard manager.nextFolderImage(item.id) else { throw ArrasIntentError.couldNotAdvance }
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
        guard !item.spaceImageFilenames.isEmpty else { throw ArrasIntentError.notASlideshow(name) }
        guard manager.prevFolderImage(item.id) else { throw ArrasIntentError.couldNotAdvance }
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
