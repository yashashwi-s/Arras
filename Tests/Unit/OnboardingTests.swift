import AppKit
import XCTest
@testable import Arras

final class OnboardingTests: XCTestCase {
    @MainActor
    func testFirstLaunchChoicePersistsAndNeverInterruptsExistingOrDamagedLibraries() throws {
        let suite = "arras.onboarding-unit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let progress = OnboardingProgress(defaults: defaults)
        XCTAssertTrue(progress.shouldPresent(hasLibrary: false, needsRecovery: false))
        XCTAssertFalse(progress.isComplete, "Reading eligibility does not dismiss a tour")
        progress.complete()
        XCTAssertFalse(OnboardingProgress(defaults: defaults).shouldPresent(hasLibrary: false, needsRecovery: false))

        for needsRecovery in [false, true] {
            defaults.removeObject(forKey: OnboardingProgress.completedKey)
            XCTAssertFalse(progress.shouldPresent(hasLibrary: !needsRecovery, needsRecovery: needsRecovery))
            XCTAssertTrue(progress.isComplete)
            XCTAssertFalse(progress.shouldPresent(hasLibrary: false, needsRecovery: false),
                           "Clearing a library later must not reopen the tour")
        }
    }

    @MainActor
    func testRepeatedTourRequestsReuseOneWindowAndClosingLeavesLibraryUntouched() throws {
        let suite = "arras.onboarding-unit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try withTestLibrary { manager in
            let progress = OnboardingProgress(defaults: defaults)
            var finished = 0
            let controller = OnboardingController(progress: progress, manager: manager) { finished += 1 }
            controller.show()
            let first = try XCTUnwrap(controller.window)
            defer { controller.window?.close() }
            for _ in 0..<3 {
                controller.show()
                XCTAssertTrue(controller.window === first)
            }
            XCTAssertTrue(manager.photos.isEmpty)
            XCTAssertTrue(manager.windows.isEmpty)
            XCTAssertFalse(progress.isComplete)
            first.close()
            XCTAssertNil(controller.window)
            XCTAssertTrue(progress.isComplete)
            XCTAssertEqual(finished, 1)
            XCTAssertTrue(manager.photos.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.storageDir.appendingPathComponent("photos.json").path))
        }
    }
}
