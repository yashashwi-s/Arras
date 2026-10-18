import AppKit
import XCTest
@testable import Arras

final class AppDialogTests: XCTestCase {
    @MainActor
    func testScreenCaptureRequestsOnlyMissingPermissionAndOffersRecoveryOnDenial() {
        var requested = 0
        var recovered = 0
        XCTAssertTrue(ScreenCapturePermission.ensureAccess(preflight: { true }, request: { requested += 1; return false },
                                                           recover: { recovered += 1 }))
        XCTAssertEqual(requested, 0)
        XCTAssertEqual(recovered, 0)
        XCTAssertTrue(ScreenCapturePermission.ensureAccess(preflight: { false }, request: { requested += 1; return true },
                                                           recover: { recovered += 1 }))
        XCTAssertEqual(requested, 1)
        XCTAssertEqual(recovered, 0)
        XCTAssertFalse(ScreenCapturePermission.ensureAccess(preflight: { false }, request: { requested += 1; return false },
                                                            recover: { recovered += 1 }))
        XCTAssertEqual(requested, 2)
        XCTAssertEqual(recovered, 1)
        var opened: URL?
        PrivacySettingsPane.screenRecording.open { opened = $0; return true }
        XCTAssertEqual(opened?.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @MainActor
    func testDestructiveConfirmationHasNoReturnDefaultAndEscapeCancels() {
        _ = NSApplication.shared
        let alert = AppDialog.make(title: "Remove Widget?", message: "Remove this widget?", style: .warning,
                                   actions: [.init(title: "Remove", role: .destructive), .init(title: "Cancel", role: .cancel)])
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertNil(alert.window.defaultButtonCell)
    }

    @MainActor
    func testSaveDiscardCancelKeepsSaveAsDefaultAndMarksDestructiveChoice() {
        _ = NSApplication.shared
        let alert = AppDialog.make(title: "Apply Changes?", message: "Choose what to keep.",
                                   actions: [.init(title: "Apply"), .init(title: "Discard Changes", role: .destructive),
                                             .init(title: "Keep Editing", role: .cancel)])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "", "\u{1b}"])
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
    }
}
