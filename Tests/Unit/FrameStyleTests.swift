import AppKit
import XCTest
@testable import Arras

final class FrameStyleTests: XCTestCase {
    func testPresetIdentitiesRemainStableForSavedLayouts() {
        XCTAssertEqual(StylePreset.gallery.rawValue, "gallery")
        XCTAssertEqual(StylePreset.polaroid.rawValue, "polaroid")
        XCTAssertEqual(StylePreset.minimal.rawValue, "minimal")
        XCTAssertEqual(StylePreset.modern.rawValue, "modern")
    }

    func testInvalidColorsAreRejectedInsteadOfPartiallyParsed() {
        XCTAssertNil(NSColor.fromHex("#GGGGGG"))
        XCTAssertNil(NSColor.fromHex("#12FFQQ"))
        XCTAssertNotNil(NSColor.fromHex("#12FFab"))
    }

    @MainActor
    func testPresetSaveFailureRestoresThePreviousAppearance() throws {
        try withTestLibrary { manager in
            var photo = PhotoItem(filename: "missing.png")
            photo.isVisible = false
            photo.matWidth = 7
            photo.stylePreset = nil
            manager.photos = [photo]
            XCTAssertTrue(manager.persist())
            try Data("corrupt".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.applyPreset(photo.id, .polaroid)
            XCTAssertEqual(manager.photos[0].matWidth, 7)
            XCTAssertNil(manager.photos[0].stylePreset)
            XCTAssertTrue(manager.windows.isEmpty)
        }
    }

    func testPresetsNeverApplyContentObscuringEffects() {
        for preset in StylePreset.allCases {
            let values = preset.values
            XCTAssertEqual(values.shapeMask, .roundedRect, "\(preset) must preserve the photo silhouette")
            XCTAssertFalse(values.borderGradientEnabled, "\(preset) must not colour the image edge")
            XCTAssertFalse(values.vignetteEnabled, "\(preset) must not darken the photo")
            XCTAssertEqual(values.tiltDegrees, 0, "\(preset) must not move a placed widget")
        }
    }

    @MainActor
    func testEveryLookSurvivesReloadWithoutChangingThePhotoOrReferenceEdits() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            manager.photos[0].reference.grayscale = true
            manager.photos[0].reference.note = "Keep this note"
            let original = manager.photos[0]
            for preset in StylePreset.allCases {
                manager.applyPreset(original.id, preset)
                let restored = try XCTUnwrap(PhotoManager(storageDirectory: manager.storageDir).photos.first)
                XCTAssertEqual(restored.filename, original.filename)
                XCTAssertEqual(restored.frameString, original.frameString)
                XCTAssertEqual(restored.reference, original.reference)
                XCTAssertEqual(restored.stylePreset, preset.rawValue)
                XCTAssertEqual(restored.matColorHex, preset.values.matColorHex)
                XCTAssertEqual(restored.matWidth, preset.values.matWidth)
            }
        }
    }

    @MainActor
    func testIndividualAppearanceEditsFitCollagesAndRollBackFailedSaves() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let child = try XCTUnwrap(manager.photos.first { $0.collageParentID != nil })
            let parentID = try XCTUnwrap(child.collageParentID)
            let parentBefore = try XCTUnwrap(manager.photos.first { $0.id == parentID }).frameString
            manager.setMat(child.id, width: 40, colorHex: "#EDE4D3")
            let parent = try XCTUnwrap(manager.photos.first { $0.id == parentID })
            XCTAssertNotEqual(parent.frameString, parentBefore)
            let restored = PhotoManager(storageDirectory: manager.storageDir)
            defer {
                restored.windows.values.forEach { $0.hidePhoto() }
                restored.windows.removeAll()
                restored.collageLabelWindows.values.forEach { $0.close() }
                restored.collageLabelWindows.removeAll()
            }
            XCTAssertEqual(restored.photos.first { $0.id == parentID }?.frameString, parent.frameString)
            XCTAssertEqual(restored.photos.first { $0.id == child.id }?.matWidth, 40)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let saved = try encoder.encode(manager.photos)
            let view = try XCTUnwrap(manager.windows[child.id]?.contentView as? DraggablePhotoView)
            let canvas = manager.windows[child.id]!.frame
            try Data("corrupt".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.setMat(child.id, width: 0, colorHex: "#FFFFFF")
            XCTAssertEqual(try encoder.encode(manager.photos), saved)
            XCTAssertEqual(view.matInset, 40)
            XCTAssertEqual(manager.windows[child.id]?.frame, canvas)
            manager.setTilt(child.id, 12)
            XCTAssertEqual(try encoder.encode(manager.photos), saved)
        }
    }

    func testPlainStyleDoesNotAddChrome() {
        let values = StylePreset.minimal.values
        XCTAssertFalse(values.shadowEnabled)
        XCTAssertEqual(values.borderWidth, 0)
        XCTAssertEqual(values.matWidth, 0)
    }
}
