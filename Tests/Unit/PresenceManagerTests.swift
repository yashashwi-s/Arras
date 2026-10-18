import AppKit
import XCTest
@testable import Arras

final class PresenceManagerTests: XCTestCase {
    @MainActor
    func testStaleLaunchServicesRecorderCannotHideWidgetsAfterItsProcessExits() {
        let recorder = "com.apple.QuickTimePlayerX"
        XCTAssertFalse(PresenceMonitor.isLiveConferencingApplication(
            bundleIdentifier: recorder, processIdentifier: 80291, isTerminated: false,
            processExists: { _ in false }), "Observed macOS ghost: no process, but isTerminated is false")
        XCTAssertTrue(PresenceMonitor.isLiveConferencingApplication(
            bundleIdentifier: recorder, processIdentifier: 123, isTerminated: false,
            processExists: { $0 == 123 }))
        for (bundle, pid, terminated) in [(recorder, Int32(0), false), (recorder, Int32(123), true), ("com.example.other", Int32(123), false)] {
            XCTAssertFalse(PresenceMonitor.isLiveConferencingApplication(
                bundleIdentifier: bundle, processIdentifier: pid, isTerminated: terminated,
                processExists: { _ in XCTFail("Invalid or unrelated entries must not probe a process"); return true }))
        }
    }

    func testFullscreenPolicySuppressesImmediatelyAndConfirmsOnlyRestoration() {
        XCTAssertEqual(FullscreenPresencePolicy.action(isPublishedFullscreen: true, sampledFullscreen: true, isExitTransition: true), .publishFullscreen)
        XCTAssertEqual(
            FullscreenPresencePolicy.action(
                isPublishedFullscreen: false,
                sampledFullscreen: true
            ),
            .publishFullscreen
        )
        XCTAssertEqual(
            FullscreenPresencePolicy.action(
                isPublishedFullscreen: true,
                sampledFullscreen: false
            ),
            .beginExitTransition
        )
        XCTAssertEqual(
            FullscreenPresencePolicy.action(
                isPublishedFullscreen: true,
                sampledFullscreen: true
            ),
            .unchanged
        )
        XCTAssertEqual(
            FullscreenPresencePolicy.action(
                isPublishedFullscreen: false,
                sampledFullscreen: false
            ),
            .unchanged
        )
    }

    func testExitTransitionSuppressesWithFullscreenPreferenceOff() {
        XCTAssertTrue(FullscreenPresencePolicy.shouldSuppress(
            isExitTransition: true,
            hideFullscreenEnabled: false,
            isFullscreen: true,
            hideConferencingEnabled: false,
            isConferencing: false
        ))
        XCTAssertFalse(FullscreenPresencePolicy.shouldSuppress(
            isExitTransition: false,
            hideFullscreenEnabled: false,
            isFullscreen: true,
            hideConferencingEnabled: false,
            isConferencing: false
        ))
    }

    @MainActor
    func testDesktopWidgetHidesInMissionControlInBothSpaceModes() {
        let window = DesktopPhotoWindow()

        window.setSpaceBound(false)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.transient))

        window.setSpaceBound(true)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.collectionBehavior.contains(.transient))
    }
}
