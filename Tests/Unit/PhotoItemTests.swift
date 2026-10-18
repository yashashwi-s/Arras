import Foundation
import XCTest
@testable import Arras

final class PhotoItemTests: XCTestCase {
    func testSavedSlideshowRepairsOutOfRangeSelectionWithoutDroppingMedia() throws {
        var original = PhotoItem(filename: "first.png")
        original.spaceImageFilenames = ["first.png", "second.png", "third.png"]
        original.opacity = 0.6
        original.frameString = "{{120, 140}, {420, 310}}"
        for (index, expected) in [(Int.min, 0), (-1, 0), (0, 0), (1, 1), (2, 2), (3, 0), (Int.max, 0)] {
            var raw = try photoDictionary(original)
            raw["folderImageIndex"] = index
            let decoded = try JSONDecoder().decode(PhotoItem.self, from: JSONSerialization.data(withJSONObject: raw))
            XCTAssertEqual(decoded.folderImageIndex, expected, "Saved slideshow index: \(index)")
            XCTAssertTrue(decoded.spaceImageFilenames.indices.contains(decoded.folderImageIndex))
            XCTAssertEqual(decoded.id, original.id)
            XCTAssertEqual(decoded.spaceImageFilenames, original.spaceImageFilenames)
            XCTAssertEqual(decoded.opacity, original.opacity)
            XCTAssertEqual(decoded.frameString, original.frameString)
            let reloaded = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(decoded))
            XCTAssertEqual(reloaded.folderImageIndex, expected)
        }
    }

    func testActual249RecordPreservesEverySavedField() throws {
        // Produced by compiling PhotoItem and WidgetDepth from the v2.4.9 tag.
        // Keep this fixture independent of the current encoder and its defaults.
        let data = Data(##"{"borderColorHex":"#123456","borderGradientColorHex":"#ABCDEF","borderGradientEnabled":true,"borderStyle":"dashed","borderWidth":3,"cornerRadius":23,"customName":"My 2.4.9 photo","customRotationSeconds":92,"depth":"floating","displayIdentifier":"legacy-display","filename":"old-photo.png","folderImageConfigs":{"old-second.png":{"frameString":"{{75, 80}, {220, 440}}","widgetWidth":220}},"folderImageIndex":1,"folderSizeMode":"dynamic","frameString":"{{125, 230}, {412, 309}}","id":"4E165C90-D36C-446E-87A0-18B3D9888720","isFloating":true,"isHiddenForDisplay":true,"isHiddenForPresence":true,"isLocked":true,"isSpaceBound":true,"isVisible":false,"matColorHex":"#FEDCBA","matWidth":11,"opacity":0.64,"revealOnHover":true,"rotationInterval":"custom","savedDisplayFrames":{"legacy-display":"{{125, 230}, {412, 309}}"},"scheduleEnabled":true,"scheduleEndMinutes":1200,"scheduleStartMinutes":480,"scheduleWeekdays":31,"shadowBlur":17,"shadowEnabled":true,"shadowOpacity":0.42,"shapeMask":"arch","spaceImageFilenames":["old-photo.png","old-second.png"],"stackOrder":7,"stylePreset":"polaroid","tiltDegrees":-7,"vignetteEnabled":true,"widgetWidth":412}"##.utf8)
        let oldFields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: data)
        let saved = try JSONEncoder().encode(decoded)
        let currentFields = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        for (key, value) in oldFields {
            let actual = try XCTUnwrap(currentFields[key], "Dropped 2.4.9 field: " + key)
            XCTAssertEqual(NSDictionary(dictionary: [key: value]), NSDictionary(dictionary: [key: actual]), key)
        }
        XCTAssertNil(decoded.desktopCollage)
        XCTAssertNil(decoded.collageParentID)
        XCTAssertNil(decoded.liveFolderSource)
        XCTAssertNil(decoded.photosLibrarySource)
    }

    func testRetiredCombinedPhotosDecodeAsSlideshowsWithoutEncodingRetiredFields() throws {
        var original = PhotoItem(filename: "")
        original.isVisible = false
        original.frameString = "{{120, 140}, {420, 310}}"
        original.stylePreset = "print"
        original.rotationInterval = "custom"
        original.customRotationSeconds = 47
        for flag in [true, false] {
            var raw = try photoDictionary(original)
            raw["isLivingCollage"] = flag
            raw["livingCollageImageFilenames"] = ["a.png", "b.png", "a.png"]
            raw["livingCollageHeroIndex"] = 99
            raw["livingCollageLayout"] = ["obsolete": true]
            raw["livingCollageCropMode"] = "obsolete"
            raw["composition"] = ["material": "bubble"]
            for includeFlag in [true, false] {
                if !includeFlag { raw.removeValue(forKey: "isLivingCollage") }
                let item = try JSONDecoder().decode(PhotoItem.self, from: JSONSerialization.data(withJSONObject: raw))
                XCTAssertEqual(item.id, original.id)
                XCTAssertEqual(item.filename, "")
                XCTAssertEqual(item.frameString, original.frameString)
                XCTAssertEqual(item.stylePreset, original.stylePreset)
                XCTAssertEqual(item.rotationInterval, "custom")
                XCTAssertEqual(item.customRotationSeconds, 47)
                XCTAssertEqual(item.spaceImageFilenames, ["a.png", "b.png", "a.png"])
                XCTAssertEqual(item.folderImageIndex, 2)
                XCTAssertFalse(item.isRetiredCompositionContainer)
                let saved = try photoDictionary(item)
                XCTAssertFalse(saved.keys.contains { $0.lowercased().contains("livingcollage") })
            }
        }
        var mixed = try photoDictionary(original)
        mixed["spaceImageFilenames"] = ["current.png", "current.png"]
        mixed["folderImageIndex"] = 1
        mixed["livingCollageImageFilenames"] = ["old.png", "current.png"]
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: JSONSerialization.data(withJSONObject: mixed))
        XCTAssertEqual(decoded.spaceImageFilenames, ["current.png", "current.png", "old.png"])
        XCTAssertEqual(decoded.folderImageIndex, 1)
    }

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
        XCTAssertFalse(item.revealOnHover)
        XCTAssertEqual(item.cornerRadius, 16)
        XCTAssertEqual(item.rotationInterval, "click")
        XCTAssertEqual(item.playbackOrder, .ordered)
        XCTAssertEqual(item.playbackStep, 0)
        XCTAssertTrue(item.playbackHistory.isEmpty)
        XCTAssertEqual(item.clickAction, .advance)
        XCTAssertNil(item.desktopCollage)
        XCTAssertNil(item.collageParentID)
        XCTAssertNil(item.focalPoint)
        XCTAssertFalse(item.isSpaceBound)
        XCTAssertEqual(item.media, .still)
        XCTAssertNil(item.photosLibrarySource)
        XCTAssertTrue(item.photosLibraryAssets.isEmpty)
    }

    func testCurrentItemRoundTripsWithoutLosingAppearance() throws {
        var original = PhotoItem(filename: "photo.jpg", width: 420)
        original.customName = "Aurora"
        original.depth = .floating
        original.opacity = 0.65
        original.revealOnHover = true
        original.shapeMask = PhotoShapeMask.arch.rawValue
        original.stylePreset = StylePreset.modern.rawValue
        original.playbackOrder = .noRepeat
        original.playbackStep = 7
        original.playbackHistory = ["photo.jpg"]
        original.clickAction = .quickLook
        original.focalPoint = NormalizedFocalPoint(x: 0.18, y: 0.82)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.customName, "Aurora")
        XCTAssertEqual(decoded.depth, .floating)
        XCTAssertEqual(decoded.opacity, 0.65)
        XCTAssertTrue(decoded.revealOnHover)
        XCTAssertEqual(decoded.shapeMask, PhotoShapeMask.arch.rawValue)
        XCTAssertEqual(decoded.stylePreset, StylePreset.modern.rawValue)
        XCTAssertEqual(decoded.playbackOrder, .noRepeat)
        XCTAssertEqual(decoded.playbackStep, 7)
        XCTAssertEqual(decoded.playbackHistory, ["photo.jpg"])
        XCTAssertEqual(decoded.clickAction, .quickLook)
        XCTAssertEqual(decoded.focalPoint, original.focalPoint)

        let source = PhotosLibrarySource(
            localIdentifier: "album-id",
            collectionType: .smartAlbum,
            displayName: "Recently Added"
        )
        let asset = PhotosLibraryAsset(
            localIdentifier: "asset-id",
            displayName: "Aurora",
            managedFilename: "aurora.webp"
        )
        original.photosLibrarySource = source
        original.photosLibraryAssets = [asset]
        let photosDecoded = try JSONDecoder().decode(
            PhotoItem.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(photosDecoded.photosLibrarySource, source)
        XCTAssertEqual(photosDecoded.photosLibraryAssets, [asset])
    }

    func testMediaModelRoundTripsVideoAndPairedResourceMetadata() throws {
        var item = PhotoItem(filename: "movie.mov")
        item.media = PhotoMedia(
            kind: .video,
            posterFilename: "movie-poster.jpg",
            isMuted: true
        )

        let decoded = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(item))

        XCTAssertEqual(decoded.media.kind, .video)
        XCTAssertEqual(decoded.media.posterFilename, "movie-poster.jpg")
        XCTAssertNil(decoded.media.pairedVideoFilename)
        XCTAssertTrue(decoded.media.isMuted)
    }

    func testUnknownMediaKindFallsBackToStill() throws {
        let json = """
        {"kind":"future-media","posterFilename":"poster.jpg","isMuted":false}
        """
        let media = try JSONDecoder().decode(PhotoMedia.self, from: Data(json.utf8))

        XCTAssertEqual(media.kind, .still)
        XCTAssertEqual(media.posterFilename, "poster.jpg")
        XCTAssertFalse(media.isMuted)
    }

    func testUnknownPlaybackAndClickValuesUseSafeDefaults() throws {
        let json = """
        {
          "id": "31E63F72-9039-41B6-B6A2-09BC231A835A",
          "filename": "photo.jpg",
          "frameString": "{{10, 20}, {300, 200}}",
          "widgetWidth": 300,
          "isLocked": false,
          "isVisible": true,
          "playbackOrder": "futurePolicy",
          "clickAction": "futureAction"
        }
        """

        let item = try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))

        XCTAssertEqual(item.playbackOrder, .ordered)
        XCTAssertEqual(item.clickAction, .advance)
    }
}
