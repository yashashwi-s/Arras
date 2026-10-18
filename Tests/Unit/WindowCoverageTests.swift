import AppKit
import CoreGraphics
import XCTest
@testable import Arras

final class WindowCoverageTests: XCTestCase {
    @MainActor
    func testStaticPhotosDoNotStartCoveragePollingAndReplacementUpdatesRegistration() throws {
        let monitor = WindowCoverageMonitor()
        let widget = DesktopPhotoWindow()
        defer { monitor.remove(widget); widget.hidePhoto() }
        let still = NSImage(size: NSSize(width: 40, height: 30))
        widget.showPhoto(.still(still))
        monitor.add(widget)
        XCTAssertFalse(monitor.isPolling)
        let data = try StarterArtwork.animatedGIFData()
        let frames = try XCTUnwrap(AnimatedImageIO.decodeForPlayback(data: data))
        widget.swapImage(.animated(frames, representative: still), animate: false)
        monitor.add(widget)
        XCTAssertTrue(monitor.isPolling)
        widget.swapImage(.still(still), animate: false)
        monitor.add(widget)
        XCTAssertFalse(monitor.isPolling)
    }

    func testPartialOverlapPausesWhileEdgeContactAndNoOverlapDoNot() {
        let target = CoverageWindow(
            id: 10, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0, alpha: 1
        )
        let content = CGRect(x: 20, y: 20, width: 40, height: 40)

        XCTAssertTrue(WindowCoveragePolicy.isCovered(
            windowID: target.id,
            contentBounds: content,
            windows: [
                CoverageWindow(id: 11, bounds: CGRect(x: 50, y: 30, width: 30, height: 30), layer: 0, alpha: 1),
                target
            ]
        ))
        XCTAssertFalse(WindowCoveragePolicy.isCovered(
            windowID: target.id,
            contentBounds: content,
            windows: [
                CoverageWindow(id: 12, bounds: CGRect(x: 60, y: 20, width: 20, height: 40), layer: 0, alpha: 1),
                target
            ]
        ))
        XCTAssertFalse(WindowCoveragePolicy.isCovered(
            windowID: target.id,
            contentBounds: content,
            windows: [
                CoverageWindow(id: 13, bounds: CGRect(x: 61, y: 20, width: 20, height: 40), layer: 0, alpha: 1),
                target
            ]
        ))
    }

    func testCoverageIgnoresWindowsBehindTargetInvisibleHelpersAndDesktopSurfaces() {
        let content = CGRect(x: 20, y: 20, width: 40, height: 40)
        let target = CoverageWindow(
            id: 20, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0, alpha: 1
        )
        let ignoredCandidates = [
            CoverageWindow(id: 21, bounds: content, layer: -1, alpha: 1), // desktop layer
            CoverageWindow(id: 22, bounds: content, layer: 0, alpha: 0.05), // invisible helper
            target,
            CoverageWindow(id: 23, bounds: content, layer: 0, alpha: 1) // behind target
        ]

        XCTAssertFalse(WindowCoveragePolicy.isCovered(
            windowID: target.id, contentBounds: content, windows: ignoredCandidates
        ))
        XCTAssertTrue(WindowCoveragePolicy.isCovered(
            windowID: target.id,
            contentBounds: content,
            windows: [
                CoverageWindow(id: 24, bounds: content, layer: 0, alpha: 0.06),
                target,
                CoverageWindow(id: 25, bounds: content, layer: 0, alpha: 1)
            ]
        ))
    }

    func testContentBoundsConvertsAppKitCoordinatesUsingTheTargetServerBounds() {
        let bounds = WindowCoveragePolicy.contentBounds(
            photo: CGRect(x: -180, y: 260, width: 120, height: 70),
            appKitWindow: CGRect(x: -200, y: 200, width: 300, height: 200),
            serverWindow: CGRect(x: -1320, y: 80, width: 600, height: 400)
        )

        XCTAssertEqual(bounds, CGRect(x: -1300, y: 150, width: 120, height: 70))
    }

    @MainActor
    func testLiveWindowServerCoveragePausesSlideshowAndRemovalResumesIt() throws {
        let widget = DesktopPhotoWindow()
        let captionParent = CollageDesktopWindow(settings: DesktopCollageSettings())
        let caption = CollageLabelWindow()
        let cover = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer {
            SnapGuideOverlay.shared.hide()
            caption.orderOut(nil)
            caption.close()
            captionParent.hidePhoto()
            cover.orderOut(nil)
            cover.close()
            widget.stopRuntimeActivityMonitoring()
            widget.orderOut(nil)
            widget.close()
        }

        // A playlist is dynamic content even though this test intentionally uses a still image,
        // avoiding a video file or timer while still driving the playback policy.
        var settings = PhotoItem(filename: "coverage-test.png")
        settings.spaceImageFilenames = ["coverage-test.png", "next.png"]
        widget.showPhoto(.still(testImage()), baseWidth: 160, locked: true, settings: settings)
        widget.sharingType = .none
        guard let screen = widget.screen ?? NSScreen.main else {
            throw XCTSkip("No screen is available for a WindowServer coverage test")
        }
        let photoFrame = CGRect(
            x: screen.visibleFrame.minX + 80,
            y: screen.visibleFrame.minY + 80,
            width: 160,
            height: 100
        )
        widget.setPhotoFrame(photoFrame, display: true)
        XCTAssertTrue(widget.hasDynamicContent)

        // The cover is transparent and click-through, and exists only long enough to produce
        // a real, partial overlap. Exercise the legacy sharing flag too; this
        // metadata check does not establish protection from captured pixels.
        cover.isOpaque = false
        cover.backgroundColor = .clear
        cover.hasShadow = false
        cover.ignoresMouseEvents = true
        cover.sharingType = .none
        cover.setFrame(
            CGRect(
                x: widget.visualFrame.midX,
                y: widget.visualFrame.midY,
                width: widget.visualFrame.width / 2,
                height: widget.visualFrame.height / 2
            ),
            display: true
        )

        drainMainRunLoop()
        guard let desktopMetadata = liveCoverage(for: widget, cover: cover), desktopMetadata.targetIsPresent else {
            throw XCTSkip("The desktop widget with a legacy sharing flag is not visible in this WindowServer session")
        }

        // Exercise the monitor above unrelated test-runner windows. The widget was first
        // confirmed at its normal desktop level; raising this short-lived test instance makes
        // the partial-overlap assertion independent of whatever apps the developer has open.
        widget.level = .screenSaver
        widget.orderFront(nil)
        cover.level = NSWindow.Level(rawValue: widget.level.rawValue + 1)
        drainMainRunLoop()
        guard let baseline = liveCoverage(for: widget, cover: cover) else {
            throw XCTSkip("WindowServer metadata became unavailable during the coverage test")
        }
        guard !baseline.isCovered else {
            throw XCTSkip("An on-screen window still covers the elevated test widget")
        }

        widget.startRuntimeActivityMonitoring()
        guard widget.runtimeActivityDecision.allowsExpensiveAnimation else {
            throw XCTSkip("A process-wide energy or accessibility policy is already pausing playback")
        }

        // Retain the original cover-only check before adding transparent chrome.
        cover.orderFront(nil)
        drainMainRunLoop()
        let coverOnly = try XCTUnwrap(liveCoverage(for: widget, cover: cover))
        let coverContext = "active=\(NSApp.isActive) widgetOnSpace=\(widget.isOnActiveSpace) coverOnSpace=\(cover.isOnActiveSpace) widgetVisible=\(widget.isVisible) coverVisible=\(cover.isVisible) widgetLevel=\(widget.level.rawValue) coverLevel=\(cover.level.rawValue) metadata=\(coverOnly)"
        XCTAssertTrue(coverOnly.coverIsPresent, coverContext)
        XCTAssertTrue(coverOnly.isCovered, coverContext)
        WindowCoverageMonitor.shared.refresh()
        XCTAssertTrue(widget.runtimeActivityDecision.blockers.contains(.occluded), coverContext)
        cover.orderOut(nil)
        drainMainRunLoop()
        XCTAssertFalse(try XCTUnwrap(liveCoverage(for: widget, cover: cover)).isCovered)
        WindowCoverageMonitor.shared.refresh()
        XCTAssertTrue(widget.runtimeActivityDecision.allowsExpensiveAnimation)

        // Known transparent Arras chrome must not pause the media it annotates.
        // Its metadata rectangle spans the photo/screen, although almost all of
        // its pixels are clear. Keep testing an ordinary covering panel below.
        captionParent.settings.caption = "Coverage caption"
        captionParent.level = widget.level
        captionParent.sharingType = .none
        captionParent.setPhotoFrame(photoFrame.insetBy(dx: -20, dy: -20))
        caption.update(from: captionParent)
        caption.orderFront(nil)
        caption.order(.above, relativeTo: widget.windowNumber)
        drainMainRunLoop()
        XCTAssertTrue(caption.isVisible)
        XCTAssertTrue(try XCTUnwrap(liveCoverage(for: widget, cover: caption)).coverIsPresent)
        WindowCoverageMonitor.shared.refresh()
        XCTAssertFalse(widget.runtimeActivityDecision.blockers.contains(.occluded), "A transparent caption must not pause its photo")
        caption.orderOut(nil)
        SnapGuideOverlay.shared.show([SnapGuide(orientation: .vertical, position: photoFrame.minX,
                                               start: photoFrame.minY, end: photoFrame.maxY, style: .solid)],
                                     on: screen, above: widget)
        drainMainRunLoop()
        XCTAssertTrue(try XCTUnwrap(liveCoverage(for: widget, cover: SnapGuideOverlay.shared)).coverIsPresent)
        WindowCoverageMonitor.shared.refresh()
        XCTAssertFalse(widget.runtimeActivityDecision.blockers.contains(.occluded),
                       "Alignment lines and an ordered-out caption must not pause the photo being dragged")
        caption.orderFront(nil)
        caption.order(.above, relativeTo: widget.windowNumber)

        cover.orderFront(nil)
        drainMainRunLoop()
        guard let covered = liveCoverage(for: widget, cover: cover), covered.coverIsPresent else {
            throw XCTSkip("A test panel with a legacy sharing flag was omitted from WindowServer metadata")
        }
        XCTAssertTrue(covered.isCovered, "The real partial overlap should be detected from WindowServer bounds")

        WindowCoverageMonitor.shared.refresh()
        XCTAssertTrue(widget.runtimeActivityDecision.blockers.contains(.occluded))
        XCTAssertFalse(widget.runtimeActivityDecision.allowsExpensiveAnimation)

        cover.orderOut(nil)
        drainMainRunLoop()

        WindowCoverageMonitor.shared.refresh()
        XCTAssertFalse(widget.runtimeActivityDecision.blockers.contains(.occluded))
        XCTAssertTrue(widget.runtimeActivityDecision.allowsExpensiveAnimation)
        // Chrome remains on screen here. Confirm the ordinary cover itself is
        // gone instead of classifying those transparent canvases as covers again.
        XCTAssertFalse(try XCTUnwrap(liveCoverage(for: widget, cover: cover)).coverIsPresent)
    }

    @MainActor
    private func liveCoverage(
        for widget: DesktopPhotoWindow,
        cover: NSWindow
    ) -> (isCovered: Bool, targetIsPresent: Bool, coverIsPresent: Bool)? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let windows = info.compactMap(coverageWindow(from:))
        guard let target = windows.first(where: { $0.id == widget.windowNumber }) else {
            return (false, false, false)
        }
        let content = WindowCoveragePolicy.contentBounds(
            photo: widget.visualFrame, appKitWindow: widget.frame, serverWindow: target.bounds
        )
        return (
            WindowCoveragePolicy.isCovered(windowID: widget.windowNumber, contentBounds: content, windows: windows),
            true,
            windows.contains(where: { $0.id == cover.windowNumber })
        )
    }

    private func coverageWindow(from entry: [String: Any]) -> CoverageWindow? {
        guard let id = entry[kCGWindowNumber as String] as? Int,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
        return CoverageWindow(
            id: id,
            bounds: rect,
            layer: layer,
            alpha: entry[kCGWindowAlpha as String] as? Double ?? 1
        )
    }

    @MainActor
    private func drainMainRunLoop() {
        NSApp.updateWindows()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func testImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 160, height: 100))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return image
    }
}
