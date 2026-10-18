import AppKit
import XCTest
@testable import Arras

final class WindowInteractionTests: XCTestCase {
    func testEditorFootersFitShortAndOffsetDisplaysWithoutGrowingNormalSheets() {
        let small = CGRect(x: 0, y: 78, width: 1024, height: 666)
        let short = Constants.editorHeight(710, visibleFrame: small, parentContentTop: 685)
        XCTAssertLessThanOrEqual(short + small.minY + 24, 685)
        XCTAssertEqual(short, 526)
        let secondary = CGRect(x: -1280, y: -800, width: 1280, height: 700)
        XCTAssertEqual(Constants.editorHeight(670, visibleFrame: secondary, parentContentTop: -180), 560)
        XCTAssertEqual(Constants.editorHeight(670, visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), parentContentTop: 1000), 670)
    }

    @MainActor
    func testSwiftUIHostRegistersTheLiveOwnerForIntentsAndSettings() throws {
        let owner = try XCTUnwrap(AppDelegate.current, "The actual SwiftUI host must register its adaptor at startup")
        XCTAssertTrue(try ArrasIntentBridge.manager() === owner.manager)
        XCTAssertTrue(owner.responds(to: #selector(AppDelegate.showSettingsFromMenu)))
        XCTAssertTrue(owner.manager.storageDir.lastPathComponent.hasPrefix("ArrasUnitHost-"))
        let originalSettings = owner.settingsWindow
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
            if originalSettings == nil { owner.settingsWindow = nil }
        }
        AppActivation.shared.apply()
        let settings = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "," })
        let action = try XCTUnwrap(settings.action)
        XCTAssertTrue(NSApp.sendAction(action, to: settings.target, from: settings))
        let deadline = Date().addingTimeInterval(1)
        while owner.settingsWindow?.isVisible != true && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let window = try XCTUnwrap(owner.settingsWindow, "Settings command must open Arras's owned window")
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSApp.sendAction(action, to: settings.target, from: settings))
        XCTAssertTrue(owner.settingsWindow === window)
        let wrapper = NSApp.delegate.map { String(reflecting: type(of: $0)) } ?? "nil"
        print("Native host application delegate: \(wrapper); registered Arras owner: \(String(reflecting: type(of: owner)))")
    }

    @MainActor
    func testIntentActionMutatesTheRegisteredLiveManager() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasIntentOwner-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: root)
        let owner = AppDelegate(manager: manager)
        let previousOwner = AppDelegate.current
        AppDelegate.current = owner
        defer {
            AppDelegate.current = previousOwner
            try? FileManager.default.removeItem(at: root)
        }
        let data = try StarterArtwork.animatedGIFData()
        try data.write(to: root.appendingPathComponent("sample.gif"))
        var item = PhotoItem(filename: "sample.gif")
        item.customName = "Intent sample"
        item.isVisible = false
        manager.photos = [item]
        XCTAssertTrue(manager.persist())
        var intent = SetPhotoOpacityIntent()
        intent.name = "Intent sample"
        intent.opacityPercent = 45
        _ = try await intent.perform()
        XCTAssertEqual(manager.photos[0].opacity, 0.45, accuracy: 0.001)
        let loaded = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: root.appendingPathComponent("photos.json")))
        XCTAssertEqual(loaded[0].opacity, 0.45, accuracy: 0.001)
    }

    @MainActor
    func testNativeAddMenuCreatesNewCollageAndOmitsLegacyCreationCommands() throws {
        let delegate = AppDelegate()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = NSMenu()
        delegate.statusItem = item
        defer {
            delegate.manager.photos.filter { $0.desktopCollage != nil }.forEach { delegate.manager.removePhoto($0.id) }
            NSStatusBar.system.removeStatusItem(item)
            delegate.statusItem = nil
        }
        delegate.rebuildMenu()
        let add = try XCTUnwrap(item.menu?.items.first { $0.title == "Add" }?.submenu)
        XCTAssertFalse(add.items.contains { ["New Composition", "Bubble", "Polaroid"].contains($0.title) })
        XCTAssertFalse(add.items.contains { $0.title == "Combine Photos…" })
        let create = try XCTUnwrap(add.items.first { $0.title == "Create Collage" })
        let action = try XCTUnwrap(create.action)
        XCTAssertTrue(NSApp.sendAction(action, to: create.target, from: create))
        let collage = try XCTUnwrap(delegate.manager.photos.last { $0.desktopCollage != nil })
        XCTAssertTrue(delegate.manager.windows[collage.id] is CollageDesktopWindow)
    }

    @MainActor
    func testMemberFloatingToggleUsesCollageDepthAndPreservesStandaloneDepth() throws {
        let delegate = AppDelegate()
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.menu = NSMenu()
        delegate.statusItem = status
        var parent = PhotoItem(filename: "")
        parent.desktopCollage = DesktopCollageSettings()
        parent.depth = .floating
        var child = PhotoItem(filename: "fixture.png")
        child.depth = .floating
        child.collageParentID = parent.id
        delegate.manager.photos = [parent, child]
        defer {
            delegate.manager.photos.removeAll(); _ = delegate.manager.persist()
            NSStatusBar.system.removeStatusItem(status); delegate.statusItem = nil
        }
        let action = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        action.tag = 1
        delegate.toggleFloating(action)
        XCTAssertEqual(delegate.manager.photos[0].depth, .onDesktop)
        XCTAssertEqual(delegate.manager.photos[1].depth, .floating)
        delegate.rebuildMenu()
        let desktopWidgets = try XCTUnwrap(status.menu?.items.first { $0.title.hasPrefix("Widgets (") }?.submenu)
        XCTAssertFalse(desktopWidgets.items[1].title.contains("floating"), "A member's badge follows the collage, preserving its standalone depth")
        delegate.toggleFloating(action)
        XCTAssertEqual(delegate.manager.photos[0].depth, .floating)
        XCTAssertEqual(delegate.manager.photos[1].depth, .floating)
        delegate.rebuildMenu()
        let floatingWidgets = try XCTUnwrap(status.menu?.items.first { $0.title.hasPrefix("Widgets (") }?.submenu)
        XCTAssertTrue(floatingWidgets.items[1].title.contains("floating"))
    }

    func testRevealOnHoverDerivesEffectiveAlphaWithoutChangingConfiguredOpacity() {
        XCTAssertEqual(effectivePhotoAlpha(
            configuredOpacity: 0.65,
            revealOnHover: false,
            isHovering: false,
            isInteractive: true
        ), 0.65)
        XCTAssertEqual(effectivePhotoAlpha(
            configuredOpacity: 0.65,
            revealOnHover: true,
            isHovering: false,
            isInteractive: true
        ), 0)
        XCTAssertEqual(effectivePhotoAlpha(
            configuredOpacity: 0.65,
            revealOnHover: true,
            isHovering: true,
            isInteractive: true
        ), 0.65)
        XCTAssertEqual(effectivePhotoAlpha(
            configuredOpacity: 0.65,
            revealOnHover: true,
            isHovering: false,
            isInteractive: false
        ), 0.65)
    }

    func testAppBundleContainsPhotosPermissionAndAgentMetadata() throws {
        // The direct XCTest runner's main bundle is xctest. Inspect the actual
        // app embedding this test bundle in both hosted and direct runs.
        let appURL = Bundle(for: type(of: self)).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try XCTUnwrap(Bundle(url: appURL))
        XCTAssertEqual(app.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String, "com.yashashwi.tableau")
        XCTAssertEqual(app.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
        XCTAssertFalse((app.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String ?? "").isEmpty)
        XCTAssertNotNil(app.object(forInfoDictionaryKey: "CFBundleDocumentTypes"))
    }

    @MainActor
    func testFinderURLCallbackIsRegisteredWithAppKit() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("application:openURLs:")))
    }

    @MainActor
    func testSettingsWindowIsConfiguredForTheActiveSpace() {
        let window = NSWindow()
        AppDelegate.configureSettingsWindow(window)

        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.collectionBehavior, [.managed, .primary, .moveToActiveSpace, .fullScreenNone])
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    @MainActor
    func testDetachedWidgetCannotOverrideCursorWithLateMouseMove() throws {
        let view = DraggablePhotoView(frame: NSRect(x: 0, y: 0, width: 300, height: 200),
                                     content: .still(NSImage(size: NSSize(width: 300, height: 200))),
                                     locked: false, canvasInset: 0)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
            location: NSPoint(x: 150, y: 100), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        defer { NSCursor.arrow.set() }
        NSCursor.crosshair.set()
        view.mouseMoved(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair)
    }

    @MainActor
    func testResizeGestureClaimsAndRetainsItsCursor() throws {
        let window = DesktopPhotoWindow()
        window.showPhoto(.still(NSImage(size: CGSize(width: 160, height: 100))), baseWidth: 160)
        defer { window.hidePhoto(); NSCursor.arrow.set() }
        let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
        let corner = CGPoint(x: window.canvasInset + 160, y: window.canvasInset + 100)
        @MainActor func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try testMouseEvent(type, in: window, at: window.convertPoint(toScreen: point))
        }
        NSCursor.arrow.set()
        view.mouseDown(with: try event(.leftMouseDown, corner))
        let resizeCursor = NSCursor.current
        XCTAssertNotEqual(resizeCursor, NSCursor.arrow)
        NSCursor.arrow.set()
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: corner.x + 20, y: corner.y + 10)))
        XCTAssertEqual(NSCursor.current, resizeCursor)
        view.mouseUp(with: try event(.leftMouseUp, corner))
    }

    @MainActor
    func testPhotoCornersFollowScreenPointerDespiteQueuedWindowCoordinates() throws {
        let window = DesktopPhotoWindow()
        window.showPhoto(.still(NSImage(size: CGSize(width: 160, height: 100))), baseWidth: 160)
        defer { window.hidePhoto(); NSCursor.arrow.set() }
        let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
        let pickup = CGRect(x: 200, y: 200, width: 160, height: 100)
        for corner in CollageResizeCorner.allCases {
            window.setPhotoFrame(pickup)
            view.mouseDown(with: try testMouseEvent(.leftMouseDown, in: window, at: corner.movingPoint(in: pickup)))
            let grown = corner.frame(from: pickup, scale: 1.25)
            let queued = try testMouseEvent(.leftMouseDragged, in: window, at: corner.movingPoint(in: grown), modifiers: .option)
            // The event's local coordinates were captured before the host moved.
            window.setPhotoOrigin(CGPoint(x: 500, y: 500))
            view.mouseDragged(with: queued)
            XCTAssertEqual(window.photoFrame, grown)
            let shrunk = corner.frame(from: pickup, scale: 0.75)
            view.mouseDragged(with: try testMouseEvent(.leftMouseDragged, in: window, at: corner.movingPoint(in: shrunk), modifiers: .option))
            XCTAssertEqual(window.photoFrame, shrunk)
            view.mouseUp(with: try testMouseEvent(.leftMouseUp, in: window, at: corner.movingPoint(in: shrunk)))
        }
    }

    @MainActor
    func testActivationPreservesEditorInFrontOfSettings() throws {
        let delegate = AppDelegate()
        delegate.showSettingsWindow()
        let settings = try XCTUnwrap(delegate.settingsWindow)
        let editor = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        defer { editor.close(); settings.close() }
        editor.makeKeyAndOrderFront(nil)
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        let ordered = NSApp.orderedWindows
        XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: editor)), try XCTUnwrap(ordered.firstIndex(of: settings)))
    }

    @MainActor
    func testSettingsReusesOneNormalWindowAfterRepeatedOpenAndClose() throws {
        let delegate = AppDelegate()
        defer { delegate.settingsWindow?.close() }
        AppActivation.shared.apply()
        delegate.showSettingsWindow()
        let first = try XCTUnwrap(delegate.settingsWindow)
        for _ in 0..<5 { delegate.showSettingsWindow(); XCTAssertTrue(delegate.settingsWindow === first) }
        first.close()
        XCTAssertFalse(first.isVisible)
        delegate.showSettingsWindow()
        XCTAssertTrue(delegate.settingsWindow === first)
        XCTAssertEqual(first.level, .normal)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    }

    @MainActor
    func testOpeningAndReopeningSettingsClearsInheritedDragCursor() {
        let delegate = AppDelegate()
        defer {
            delegate.settingsWindow?.close()
            NSCursor.arrow.set()
        }
        NSCursor.openHand.set()
        delegate.showSettingsWindow()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
        delegate.settingsWindow?.orderOut(nil)
        NSCursor.openHand.set()
        delegate.showSettingsWindow()
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }

    @MainActor
    func testHoverRevealKeepsSavedOpacityAndRespondsToDepthAndPointer() throws {
        let window = DesktopPhotoWindow()
        defer { window.hidePhoto() }
        var item = PhotoItem(filename: "fixture.png")
        item.opacity = 0.65
        item.revealOnHover = true
        window.showPhoto(.still(NSImage(size: CGSize(width: 100, height: 80))), locked: false, settings: item)
        let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
        XCTAssertEqual(view.alphaValue, 0)
        XCTAssertEqual(window.configuredOpacity, 0.65)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: event)
        window.setRevealOnHover(true, animated: false)
        XCTAssertEqual(view.alphaValue, 0.65)
        view.mouseExited(with: event)
        window.setRevealOnHover(true, animated: false)
        XCTAssertEqual(view.alphaValue, 0)
        window.setDepth(.behindIcons)
        XCTAssertEqual(view.alphaValue, 0.65)
        window.setDepth(.onDesktop)
        XCTAssertEqual(view.alphaValue, 0)
        window.setRevealOnHover(false, animated: false)
        XCTAssertEqual(view.alphaValue, 0.65)
    }

    @MainActor
    func testRepeatedClosureReleasesDecodedMediaViews() {
        for _ in 0..<40 {
            weak var releasedView: NSView?
            autoreleasepool {
                let window = DesktopPhotoWindow()
                window.showPhoto(.still(NSImage(size: CGSize(width: 100, height: 80))), baseWidth: 100, locked: false)
                releasedView = window.contentView
                XCTAssertNotNil(releasedView)
                window.hidePhoto()
            }
            XCTAssertNil(releasedView)
        }
    }

    @MainActor
    func testClosedCollageReleasesSurfaceWhileCallerRetainsPanel() async throws {
        // The helper returns before assertions so its creation/teardown locals
        // cannot keep the very view whose lifetime is under test alive.
        let probes = CollageSkin.allCases.map { skin in
            autoreleasepool { ClosedCollageProbe(skin: skin) }
        }
        try await Task.sleep(for: .milliseconds(50))

        for probe in probes {
            XCTAssertTrue(probe.hadSurface, probe.skin.rawValue)
            XCTAssertNil(probe.surface, "A retained closed \(probe.skin.rawValue) panel must release its material tree")
            XCTAssertNil(probe.window.contentView)
            XCTAssertNil(probe.window.photoId)
            XCTAssertFalse(probe.window.isVisible)
            probe.window.render()
            probe.window.setLocked(true)
            probe.window.resetManipulation()
            XCTAssertFalse(probe.window.containsBackgroundPoint(.zero))
            XCTAssertNil(probe.window.contentView, "Late updates must not recreate a hidden surface")
        }
    }

    @MainActor
    func testManagerRemovalReleasesCollageMaterialWithoutRequiringPanelDeallocation() throws {
        for skin in CollageSkin.allCases {
            try withTestLibrary { manager in
                weak var releasedWindow: NSWindow?
                weak var releasedView: NSView?
                var removedID: UUID?
                // Drain AppKit temporaries from creation as well as teardown.
                // A teardown-only pool leaves earlier creation references alive.
                try autoreleasepool {
                    XCTAssertTrue(manager.addStarterExample(.galleryWall))
                    let id = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil }?.id)
                    removedID = id
                    var settings = try XCTUnwrap(manager.photos.first { $0.id == id }?.desktopCollage)
                    settings.skin = skin
                    XCTAssertTrue(manager.applyCollageSettings(id, settings: settings))
                    releasedWindow = manager.windows[id]
                    releasedView = manager.windows[id]?.contentView
                    XCTAssertNotNil(releasedWindow)
                    XCTAssertNotNil(releasedView)
                    manager.removePhoto(id)
                    XCTAssertNil(manager.windows[id])
                    XCTAssertTrue(manager.photos.allSatisfy { $0.collageParentID == nil })
                }
                NSApp.updateWindows()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                // The bare panel may still be retained by AppKit or a caller.
                XCTAssertNil(releasedWindow?.contentView)
                XCTAssertNil((releasedWindow as? DesktopPhotoWindow)?.photoId)
                XCTAssertNil(manager.collageLabelWindows[try XCTUnwrap(removedID)])
                XCTAssertEqual(manager.photos.count, 3, "Removing a collage keeps its independent photos")
                XCTAssertNil(releasedView, "Normal removal must release its \(skin.rawValue) material")
            }
        }
    }

    @MainActor
    func testHiddenCollageDiscardsAQueuedDesktopDoubleClick() throws {
        let window = CollageDesktopWindow(settings: DesktopCollageSettings())
        defer { window.hidePhoto() }
        window.setPhotoFrame(CGRect(x: 120, y: 160, width: 360, height: 280))
        window.orderFront(nil)
        let surface = try XCTUnwrap(window.contentView as? CollageSurfaceView)
        var edits = 0, ordering = 0
        window.onEdit = { edits += 1 }
        window.onWindowInteraction = { ordering += 1 }
        let point = CGPoint(x: window.photoFrame.midX, y: window.photoFrame.midY)
        surface.mouseDown(with: try testMouseEvent(.leftMouseDown, in: window, at: point, clicks: 2))
        XCTAssertEqual(edits, 0, "Desktop double-click presentation must be queued until ordering settles")

        window.hidePhoto()
        let before = ordering
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(edits, 0, "A click queued before hiding must not reopen the hidden collage's editor")
        XCTAssertEqual(ordering, before, "A stale click must not reorder a closed panel")
        XCTAssertNil(surface.owner)
        XCTAssertNil(window.contentView)
    }

    @MainActor
    func testVisibleCollageDeliversItsDeferredDesktopDoubleClick() throws {
        let window = CollageDesktopWindow(settings: DesktopCollageSettings())
        defer { window.hidePhoto() }
        window.setPhotoFrame(CGRect(x: 120, y: 160, width: 360, height: 280))
        window.orderFront(nil)
        let surface = try XCTUnwrap(window.contentView as? CollageSurfaceView)
        var edits = 0
        window.onEdit = { edits += 1 }
        let point = CGPoint(x: window.photoFrame.midX, y: window.photoFrame.midY)
        surface.mouseDown(with: try testMouseEvent(.leftMouseDown, in: window, at: point, clicks: 2))
        XCTAssertEqual(edits, 0)

        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(edits, 1, "The visible original surface must retain its normal queued action")
        XCTAssertTrue(window.contentView === surface)
        XCTAssertTrue(surface.owner === window)
    }

    @MainActor
    func testTeardownDropsMediaViewAndPanelCanBeReused() throws {
        let window = DesktopPhotoWindow()
        defer { window.hidePhoto() }
        let image = NSImage(size: CGSize(width: 100, height: 80))
        window.showPhoto(.still(image), baseWidth: 100, locked: false)
        XCTAssertNotNil(window.contentView)
        window.hidePhoto()
        XCTAssertNil(window.contentView)
        XCTAssertNil(window.photoId)
        window.showPhoto(.still(image), baseWidth: 100, locked: false)
        XCTAssertNotNil(window.contentView)
        XCTAssertEqual(window.photoFrame.width, 100, accuracy: 0.001)
    }

    @MainActor
    func testShiftSnapPreservesTheConstrainedAxisAndOptionReleasesSnap() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let suite = "SnapInteraction-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = SnapEngine(defaults: defaults)
        engine.includesOtherApps = false
        let window = DesktopPhotoWindow()
        defer { window.hidePhoto(); engine.endDrag() }
        engine.beginDrag(for: window)
        let start = CGPoint(x: screen.frame.minX + 3, y: screen.visibleFrame.midY)
        let proposed = CGPoint(x: start.x + 1, y: start.y + 80)
        let shifted = engine.snappedOrigin(for: window, proposedOrigin: proposed,
            size: CGSize(width: 103, height: 79), matInset: 0, modifiers: .shift, dragStart: start)
        XCTAssertEqual(shifted.origin.x, start.x, accuracy: 0.001)
        XCTAssertFalse(shifted.guides.contains { $0.orientation == .vertical })
        let free = engine.snappedOrigin(for: window, proposedOrigin: proposed,
            size: CGSize(width: 103, height: 79), matInset: 0, modifiers: .option, dragStart: start)
        XCTAssertEqual(free.origin, proposed)
        XCTAssertTrue(free.guides.isEmpty)
    }

    @MainActor
    func testDistantWindowDoesNotAttractDraggingPhoto() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let suite = "SnapDistance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = SnapEngine(defaults: defaults)
        engine.includesOtherApps = false
        let window = DesktopPhotoWindow()
        let distant = DesktopPhotoWindow()
        defer { window.hidePhoto(); distant.hidePhoto(); engine.endDrag() }
        distant.showPhoto(.still(NSImage(size: CGSize(width: 100, height: 80))),
                          baseWidth: 100, locked: false)
        distant.setPhotoFrame(CGRect(x: screen.frame.minX + 219, y: screen.frame.maxY + 10_000,
                                    width: 100, height: 80))
        engine.beginDrag(for: window)
        let proposed = CGPoint(x: distant.visualFrame.minX + 3, y: screen.visibleFrame.midY + 71)
        let result = engine.snappedOrigin(for: window, proposedOrigin: proposed,
            size: CGSize(width: 103, height: 79), matInset: 0, modifiers: [], dragStart: proposed)
        let targets = NSApp.windows.compactMap { $0 as? DesktopPhotoWindow }
            .filter { $0 !== window && $0.isVisible }
            .map { "\(type(of: $0)): \($0.visualFrame)" }
        XCTAssertEqual(result.origin.x, proposed.x, accuracy: 0.001,
                       "Guides: \(result.guides); visible test windows: \(targets)")
    }

}

@MainActor
private final class ClosedCollageProbe {
    let skin: CollageSkin
    let window: CollageDesktopWindow
    let hadSurface: Bool
    weak var surface: NSView?

    @inline(never)
    init(skin: CollageSkin) {
        self.skin = skin
        var settings = DesktopCollageSettings()
        settings.skin = skin
        window = CollageDesktopWindow(settings: settings)
        window.photoId = UUID()
        window.setPhotoFrame(CGRect(x: 30, y: 60, width: 300, height: 200))
        window.orderFront(nil)
        surface = window.contentView
        hadSurface = surface != nil
        window.hidePhoto()
    }
}
