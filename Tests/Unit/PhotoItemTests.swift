import XCTest
@testable import Arras

final class PhotoItemTests: XCTestCase {
    func testLegacyRequiredFieldsDecodeWithCurrentDefaults() throws {
        let json = """
        {
          "id": "31E63F72-9039-41B6-B6A2-09BC231A835A",
          "filename": "photo.jpg",
          "frameString": "{{10, 20}, {300, 200}}",
          "widgetWidth": 300,
          "isLocked": false,
          "isVisible": true
        }
        """

        let item = try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))

        XCTAssertEqual(item.depth, .onDesktop)
        XCTAssertEqual(item.opacity, 1)
        XCTAssertEqual(item.cornerRadius, 16)
        XCTAssertEqual(item.rotationInterval, "click")
        XCTAssertEqual(item.scheduleWeekdays, 0b111_1111)
        XCTAssertFalse(item.isSpaceBound)
    }

    func testCurrentItemRoundTripsWithoutLosingAppearanceOrSchedule() throws {
        var original = PhotoItem(filename: "photo.jpg", width: 420)
        original.customName = "Aurora"
        original.depth = .floating
        original.opacity = 0.65
        original.shapeMask = PhotoShapeMask.arch.rawValue
        original.stylePreset = StylePreset.modern.rawValue
        original.scheduleEnabled = true
        original.scheduleStartMinutes = 22 * 60
        original.scheduleEndMinutes = 6 * 60
        original.scheduleWeekdays = 0b010_1010

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.customName, "Aurora")
        XCTAssertEqual(decoded.depth, .floating)
        XCTAssertEqual(decoded.opacity, 0.65)
        XCTAssertEqual(decoded.shapeMask, PhotoShapeMask.arch.rawValue)
        XCTAssertEqual(decoded.stylePreset, StylePreset.modern.rawValue)
        XCTAssertEqual(decoded.scheduleStartMinutes, 22 * 60)
        XCTAssertEqual(decoded.scheduleEndMinutes, 6 * 60)
        XCTAssertEqual(decoded.scheduleWeekdays, 0b010_1010)
    }
}
