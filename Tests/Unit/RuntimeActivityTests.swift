import AppKit
import XCTest
@testable import Arras

final class RuntimeActivityTests: XCTestCase {
    @MainActor
    func testCustomSlideshowIntervalsKeepSavedValuesWithoutOverflowingNativeTimers() throws {
        try withTestLibrary { manager in
            var item = PhotoItem(filename: "sample.png")
            item.spaceImageFilenames = [item.filename]
            item.rotationInterval = "custom"
            manager.photos = [item]
            // An unshown window starts with active runtime policy, allowing the
            // actual timer path without displaying media or moving the pointer.
            let window = DesktopPhotoWindow()
            XCTAssertTrue(window.runtimeActivityDecision.allowsRotation)
            manager.windows[item.id] = window
            defer {
                manager.rotationTimers.values.forEach { $0.cancel() }
                manager.rotationTimers.removeAll()
            }

            for seconds in [Int.min, 0, 4, 5, 20, 86400, 10_000_000_000, Int.max] {
                manager.setCustomRotationSeconds(item.id, seconds)
                let expected = max(5, seconds)
                XCTAssertEqual(manager.photos[0].customRotationSeconds, expected)
                XCTAssertNotNil(manager.rotationTimers[item.id])

                let stored = try JSONDecoder().decode([PhotoItem].self, from:
                    Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
                XCTAssertEqual(stored[0].customRotationSeconds, expected)
                manager.setupRotationTimer(for: stored[0])
                XCTAssertNotNil(manager.rotationTimers[item.id], "A saved interval must also be safe on reload")
            }

            manager.setRotationInterval(item.id, "click")
            XCTAssertNil(manager.rotationTimers[item.id])
            XCTAssertEqual(manager.photos[0].customRotationSeconds, Int.max)
        }
    }

    func testOcclusionOnlyPausesWhenVisibleBitIsAbsent() {
        XCTAssertFalse(RuntimeActivityPolicy.isFullyOccluded(.visible))
        XCTAssertTrue(RuntimeActivityPolicy.isFullyOccluded(NSWindow.OcclusionState()))
    }

    func testFullyOccludedWidgetPausesAnimationAndRotation() {
        var input = RuntimeActivityInput()
        input.isOccluded = true

        let decision = RuntimeActivityPolicy.decision(for: input)

        XCTAssertFalse(decision.allowsExpensiveAnimation)
        XCTAssertFalse(decision.allowsRotation)
        XCTAssertEqual(decision.blockers, [.occluded])
    }

    func testUncoveredWidgetRemainsActive() {
        // Neither full occlusion nor the separate partial-coverage monitor reports overlap.
        let decision = RuntimeActivityPolicy.decision(for: RuntimeActivityInput())

        XCTAssertTrue(decision.allowsExpensiveAnimation)
        XCTAssertTrue(decision.allowsRotation)
        XCTAssertFalse(decision.isPaused)
    }

    func testEnergyAndAccessibilitySignalsPauseDecorativeWork() {
        var environment = RuntimeActivityEnvironment()
        environment.isLowPowerModeEnabled = true
        environment.isRunningOnLowBattery = true
        environment.thermalState = .serious
        environment.shouldReduceMotion = true
        environment.isSleeping = true

        let decision = RuntimeActivityPolicy.decision(
            for: RuntimeActivityInput(environment: environment)
        )

        XCTAssertFalse(decision.allowsExpensiveAnimation)
        XCTAssertFalse(decision.allowsRotation)
        XCTAssertEqual(
            decision.blockers,
            [.lowPowerMode, .lowBattery, .thermalPressure, .reduceMotion, .sleeping]
        )
    }

    func testLowBatteryPolicyOnlyPausesAtThresholdWhileOnBattery() {
        XCTAssertTrue(BatteryActivityPolicy.shouldPause(
            isDrawingFromBattery: true,
            currentCapacity: 20,
            maximumCapacity: 100
        ))
        XCTAssertFalse(BatteryActivityPolicy.shouldPause(
            isDrawingFromBattery: true,
            currentCapacity: 21,
            maximumCapacity: 100
        ))
        XCTAssertFalse(BatteryActivityPolicy.shouldPause(
            isDrawingFromBattery: false,
            currentCapacity: 5,
            maximumCapacity: 100
        ))
        XCTAssertFalse(BatteryActivityPolicy.shouldPause(
            isDrawingFromBattery: true,
            currentCapacity: nil,
            maximumCapacity: nil
        ))
    }

    func testFairThermalStateDoesNotPauseByItself() {
        var environment = RuntimeActivityEnvironment()
        environment.thermalState = .fair

        let decision = RuntimeActivityPolicy.decision(
            for: RuntimeActivityInput(environment: environment)
        )

        XCTAssertEqual(decision, .active)
    }

    func testPresenceSuppressionCombinesWithWindowOcclusion() {
        var environment = RuntimeActivityEnvironment()
        environment.isPresenceSuppressed = true
        let input = RuntimeActivityInput(isOccluded: true, environment: environment)

        let decision = RuntimeActivityPolicy.decision(for: input)

        XCTAssertEqual(decision.blockers, [.occluded, .presenceSuppressed])
    }
}
