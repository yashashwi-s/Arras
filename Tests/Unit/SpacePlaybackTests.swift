import XCTest
@testable import Arras

final class SpacePlaybackTests: XCTestCase {
    private let filenames = ["old.jpg", "middle.jpg", "new.jpg"]

    func testOrderedAndNewestFirstUseThePersistedFilenameOrder() {
        XCTAssertEqual(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: 0,
                order: .ordered
            )?.index,
            1
        )
        XCTAssertEqual(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: 0,
                order: .newestFirst
            )?.index,
            2
        )
        XCTAssertEqual(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: 2,
                order: .newestFirst
            )?.index,
            1
        )
    }

    func testRandomSelectionIsDeterministicAndDoesNotLeaveTheCurrentImageInPlace() throws {
        let first = try XCTUnwrap(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: 0,
                order: .random,
                seed: 42,
                step: 0,
                history: []
            )
        )
        let again = try XCTUnwrap(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: 0,
                order: .random,
                seed: 42,
                step: 0,
                history: []
            )
        )

        XCTAssertEqual(first, again)
        XCTAssertEqual(first.step, 1)
        XCTAssertNotEqual(first.index, 0)

        let onlyImage = try XCTUnwrap(
            SpacePlaybackSelector.nextSelection(
                filenames: ["only.jpg"],
                currentIndex: 0,
                order: .random,
                seed: 42,
                step: 0
            )
        )
        XCTAssertEqual(onlyImage.index, 0)
    }

    func testNoRepeatExhaustionStartsANewBagWithoutRepeatingTheBoundaryImage() throws {
        let first = try XCTUnwrap(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: 0,
                order: .noRepeat,
                seed: 7,
                step: 0,
                history: [filenames[0]]
            )
        )
        let second = try XCTUnwrap(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: first.index,
                order: .noRepeat,
                seed: 7,
                step: first.step,
                history: first.history
            )
        )
        let afterExhaustion = try XCTUnwrap(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: second.index,
                order: .noRepeat,
                seed: 7,
                step: second.step,
                history: second.history
            )
        )

        XCTAssertNotEqual(first.index, second.index)
        XCTAssertEqual(first.history.count, 2)
        XCTAssertTrue(first.history.contains(filenames[0]))
        XCTAssertEqual(Set(second.history), Set(filenames))
        XCTAssertNotEqual(afterExhaustion.index, second.index)
        XCTAssertEqual(afterExhaustion.history.first, filenames[second.index])
    }

    func testSelectionStateRoundTripsExactlyForRelaunch() throws {
        let selection = try XCTUnwrap(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: 0,
                order: .noRepeat,
                seed: 99,
                step: 11,
                history: [filenames[0]]
            )
        )
        let nextInProcess = try XCTUnwrap(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: selection.index,
                order: .noRepeat,
                seed: 99,
                step: selection.step,
                history: selection.history
            )
        )
        let nextAfterReload = try XCTUnwrap(
            SpacePlaybackSelector.nextSelection(
                filenames: filenames,
                currentIndex: selection.index,
                order: .noRepeat,
                seed: 99,
                step: selection.step,
                history: selection.history
            )
        )

        XCTAssertEqual(nextInProcess, nextAfterReload)
    }

    func testClickActionsAreBoundedAndCodable() throws {
        XCTAssertEqual(WidgetClickAction.allCases, [.advance, .quickLook, .revealStoredMedia, .copyPath])

        let data = try JSONEncoder().encode(WidgetClickAction.copyPath)
        XCTAssertEqual(try JSONDecoder().decode(WidgetClickAction.self, from: data), .copyPath)
        XCTAssertEqual(
            try JSONDecoder().decode(WidgetClickAction.self, from: Data("\"reveal\"".utf8)),
            .revealStoredMedia
        )
    }

    func testBehindIconsDepthIsTheOnlyNonInteractiveDepth() {
        XCTAssertFalse(WidgetDepth.behindIcons.isInteractive)
        XCTAssertTrue(WidgetDepth.onDesktop.isInteractive)
        XCTAssertTrue(WidgetDepth.aboveWidgets.isInteractive)
        XCTAssertTrue(WidgetDepth.floating.isInteractive)
    }
}
