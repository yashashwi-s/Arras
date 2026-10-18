import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum StarterExample: String, CaseIterable, Identifiable {
    case minimal, polaroid, galleryWall, moodboard, animated, rotatingSpace

    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: "A Photo on Your Desktop"
        case .polaroid: "Print Photo"
        case .galleryWall: "Glass Photo Collage"
        case .moodboard: "Photos & Labels"
        case .animated: "A Little Motion"
        case .rotatingSpace: "A Changing View"
        }
    }
    var detail: String {
        switch self {
        case .minimal: "Move a picture into your everyday view."
        case .polaroid: "Give a photo a paper mat, shadow and tilt."
        case .galleryWall: "Arrange individual photos on a shared glass backdrop."
        case .moodboard: "Arrange editable text over a transparent collage."
        case .animated: "Bring a quiet GIF loop to your desktop."
        case .rotatingSpace: "Keep several pictures in one slideshow."
        }
    }
    var features: [String] {
        switch self {
        case .minimal: ["Position", "Size", "Stacking depth"]
        case .polaroid: ["Photo frame", "Paper mat", "Tilt"]
        case .galleryWall: ["Glass background", "Group movement", "Group resizing"]
        case .moodboard: ["Transparent background", "Border", "Editable labels"]
        case .animated: ["GIF playback", "Opacity", "Hover reveal"]
        case .rotatingSpace: ["3 images", "30-second rotation", "Manual advance"]
        }
    }
    var contents: String {
        switch self {
        case .minimal: "Adds one landscape photo with rounded corners."
        case .polaroid: "Adds one portrait photo with the Print frame style."
        case .galleryWall: "Adds a glass collage containing three separate photos and a caption. Each photo stays editable."
        case .moodboard: "Adds three photos inside a transparent collage with a white outline, a caption and a freely placed label."
        case .animated: "Adds one animated widget. The preview is still; the original GIF plays after you add it."
        case .rotatingSpace: "Adds one slideshow with three original images, changing every 30 seconds while playback is active."
        }
    }
    var steps: [String] {
        switch self {
        case .minimal: ["Drag the photo to a clear area of your desktop.", "Drag a corner to resize it.", "Expand its row in Settings to try stacking depth or Lock Position."]
        case .polaroid: ["Open the photo’s row in Settings, then choose Appearance.", "Change the paper mat, border or tilt to make it yours.", "Use Replace Image to keep the style and add your own photo."]
        case .galleryWall: ["Drag a photo to rearrange it, or its corner to resize just that photo.", "Drag the empty glass background to move the collage; drag a background corner to resize the group.", "Open Edit Collage in Settings to change its look, spacing and caption."]
        case .moodboard: ["Open Edit Collage in Settings and select a label to change its words or font.", "Choose Arrange Labels to drag text into place, then Apply to save.", "Change the collage background or border; drag its empty margin to move the group."]
        case .animated: ["Watch the circle drift while the widget is visible; playback pauses when system policy requires it.", "Expand its row in Settings, then More options to adjust opacity or try On hover.", "Use Replace Image to try your own GIF or animated PNG."]
        case .rotatingSpace: ["Double-click the widget to advance immediately.", "Open its row in Settings to choose the rotation interval and playback order.", "Choose Edit Slideshow to reorder or remove images, or Add Photos to grow the collection."]
        }
    }
    var isGrouped: Bool { self == .galleryWall || self == .moodboard }
    var itemCount: Int { frames.count + (isGrouped ? 1 : 0) }

    // Photo bounds, not shadow-expanded window bounds.
    var frames: [NSRect] {
        switch self {
        case .minimal, .animated, .rotatingSpace:
            [NSRect(x: 0, y: 0, width: 340, height: 200)]
        case .polaroid:
            [NSRect(x: 0, y: 0, width: 220, height: 280)]
        case .galleryWall:
            [NSRect(x: 0, y: 0, width: 185, height: 270),
             NSRect(x: 205, y: 145, width: 230, height: 125),
             NSRect(x: 205, y: 0, width: 230, height: 125)]
        case .moodboard:
            [NSRect(x: 0, y: 100, width: 240, height: 180),
             NSRect(x: 205, y: 35, width: 185, height: 240),
             NSRect(x: 85, y: 0, width: 200, height: 140)]
        }
    }

    @MainActor
    var collageSettings: DesktopCollageSettings? {
        guard isGrouped else { return nil }
        var settings = DesktopCollageSettings(skin: self == .galleryWall ? .glass : .transparent)
        settings.caption = self == .galleryWall ? "A few things worth keeping" : "MAKE ROOM FOR WHAT YOU LOVE"
        settings.captionStyle.font = .editorial
        settings.captionStyle.fontSize = self == .galleryWall ? 18 : 14
        if self == .moodboard {
            settings.borderWidth = 2
            settings.borderColorHex = "#FFFFFF"
            settings.captionStyle.colorHex = "#FFFFFF"
            settings.captionStyle.shadow = true
            var style = CollageLabelStyle()
            style.font = .handwritten
            style.fontSize = 30
            style.colorHex = "#FFFFFF"
            style.shadow = true
            style.rotationDegrees = -6
            style.positionX = 0.36
            style.positionY = 0.77
            style.widthFraction = 0.62
            settings.labels = [CollageTextLabel(text: "Little moments", style: style)]
        }
        settings.normalize()
        return settings
    }

    func configure(_ item: inout PhotoItem, index: Int) {
        item.customName = frames.count == 1 ? title : "\(title) · Photo \(index + 1)"
        item.shadowOpacity = 0.18
        if self == .polaroid {
            let values = StylePreset.polaroid.values
            item.stylePreset = StylePreset.polaroid.rawValue
            item.cornerRadius = values.cornerRadius
            item.shadowEnabled = values.shadowEnabled
            item.shadowBlur = values.shadowBlur
            item.shadowOpacity = values.shadowOpacity
            item.borderWidth = values.borderWidth
            item.borderColorHex = values.borderColorHex
            item.matWidth = values.matWidth
            item.matColorHex = values.matColorHex
            item.tiltDegrees = -3
            // This example adds a deliberate tilt beyond the reusable Print preset.
            item.stylePreset = nil
        } else if self == .moodboard {
            item.tiltDegrees = [-5, 4, -2][index]
            item.cornerRadius = 4
        } else {
            item.cornerRadius = self == .galleryWall ? 10 : 18
        }
    }

    @MainActor
    func sceneBounds(settings: DesktopCollageSettings?) -> NSRect {
        let footprints = frames.enumerated().map { index, frame in
            var item = PhotoItem(filename: "")
            configure(&item, index: index)
            return CollageGeometry.footprint(item, frame: frame)
        }
        if let settings {
            return CollageGeometry.enclosing(footprints, fallback: .zero, settings: settings)
        }
        return footprints.dropFirst().reduce(footprints[0]) { $0.union($1) }
    }
}

@MainActor
extension PhotoManager {
    /// Stage original artwork and the complete parent/child scene before one durable save.
    /// Only then create windows through the normal manager authority.
    @discardableResult
    func addStarterExample(_ example: StarterExample, makeVisible: Bool = true) -> Bool {
        let previousPhotos = photos
        var writtenURLs: [URL] = []
        do {
            var additions: [(PhotoItem, PhotoContent)] = []
            var settings = example.collageSettings
            let scene = example.sceneBounds(settings: settings)
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let scale = min(1, max(80, screen.width - 120) / scene.width,
                            max(80, screen.height - 120) / scene.height)
            let origin = NSPoint(x: screen.midX - scene.width * scale / 2 - scene.minX * scale,
                                 y: screen.midY - scene.height * scale / 2 - scene.minY * scale)
            let stackBase = (photos.map(\.stackOrder).max() ?? 0) + 1
            var parent: PhotoItem?
            if settings != nil {
                settings?.compositionScale = scale
                var item = PhotoItem(filename: "", width: scene.width * scale)
                item.desktopCollage = settings
                item.customName = example.title
                item.isVisible = makeVisible
                item.stackOrder = stackBase
                parent = item
            }
            for (index, frame) in example.frames.enumerated() {
                var urls: [URL] = []
                for phase in 0..<(example == .rotatingSpace ? 3 : 1) {
                    let animated = example == .animated
                    let url = storageDir.appendingPathComponent("starter-\(UUID().uuidString).\(animated ? "gif" : "png")")
                    let data = animated ? try StarterArtwork.animatedGIFData()
                        : try StarterArtwork.pngData(for: StarterArtwork.image(for: example, index: index, phase: phase))
                    try data.write(to: url, options: .atomic)
                    writtenURLs.append(url)
                    urls.append(url)
                }
                guard let content = PhotoContent.load(from: urls[0]) else { throw StarterArtwork.Error.couldNotEncode }
                var item = PhotoItem(filename: example == .rotatingSpace ? "" : urls[0].lastPathComponent,
                                     width: frame.width * scale)
                if case .animated = content { item.media = PhotoMedia(kind: .animatedImage) }
                for url in urls { item.mediaFidelity[url.lastPathComponent] = .transformed }
                example.configure(&item, index: index)
                item.stackOrder = stackBase + index + 1
                item.collageParentID = parent?.id
                item.cornerRadius *= scale
                item.matWidth *= scale
                item.borderWidth *= scale
                item.shadowBlur *= scale
                item.frameString = NSStringFromRect(NSRect(x: origin.x + frame.minX * scale,
                                                          y: origin.y + frame.minY * scale,
                                                          width: frame.width * scale, height: frame.height * scale))
                item.isVisible = makeVisible
                if example == .rotatingSpace {
                    item.spaceImageFilenames = urls.map(\.lastPathComponent)
                    item.rotationInterval = "30s"
                }
                additions.append((item, content))
            }
            if var group = parent, let settings = group.desktopCollage {
                let footprints = additions.map { CollageGeometry.footprint($0.0, frame: NSRectFromString($0.0.frameString)) }
                let bounds = CollageGeometry.enclosing(footprints, fallback: .zero, settings: settings)
                group.frameString = NSStringFromRect(bounds)
                group.widgetWidth = bounds.width
                additions.insert((group, .still(NSImage(size: bounds.size))), at: 0)
            }
            photos.append(contentsOf: additions.map { $0.0 })
            guard persist() else { throw StarterArtwork.Error.couldNotSave }
            if makeVisible {
                for (item, content) in additions {
                    // Creating the parent may create its children through syncCollages.
                    guard windows[item.id] == nil else { continue }
                    if !item.spaceImageFilenames.isEmpty {
                        spaceImages[item.id] = item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
                    }
                    createWindow(for: item, content: content)
                    if !item.spaceImageFilenames.isEmpty { setupRotationTimer(for: item) }
                }
                syncCollages()
            }
            return true
        } catch {
            photos = previousPhotos
            for url in writtenURLs { try? FileManager.default.removeItem(at: url) }
            recordMediaImportFailure("The \(example.title) example could not be created: \(error.localizedDescription)")
            return false
        }
    }
}

struct StarterExamplesView: View {
    @ObservedObject var manager: PhotoManager
    var onAdded: ((StarterExample, UUID?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: StarterExample = .galleryWall
    @State private var couldNotAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Try an example").font(.system(size: 22, weight: .semibold))
                Text("Choose something to explore, then add it to your desktop.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(StarterExample.allCases) { example in
                            Button { selected = example } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: StarterArtwork.previews[example]!)
                                        .resizable().scaledToFit().frame(width: 78, height: 52)
                                        .background(Color(nsColor: StarterArtwork.backdrop), in: RoundedRectangle(cornerRadius: 6))
                                        .accessibilityHidden(true)
                                    Text(example.title).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected == example ? Color.accentColor.opacity(0.10) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected == example ? Color.accentColor : Color.clear, lineWidth: 1.5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(example.title)
                            .accessibilityValue(selected == example ? "Selected" : "Not selected")
                            .accessibilityHint("Show a preview and instructions. " + example.detail)
                            .accessibilityIdentifier("starter-example-\(example.rawValue)")
                        }
                    }.padding(2)
                }.frame(width: 220)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(nsImage: StarterArtwork.previews[selected]!)
                            .resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 205)
                            .background(Color(nsColor: StarterArtwork.backdrop), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel(selected.title + " preview")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(selected.title).font(.system(size: 20, weight: .semibold))
                            Text(selected.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Text(selected.features.joined(separator: "  ·  "))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text(selected.contents).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Text("Try this after adding").font(.system(size: 13, weight: .semibold))
                        ForEach(Array(selected.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").font(.system(size: 11, weight: .semibold))
                                    .frame(width: 22, height: 22).background(.quaternary, in: Circle())
                                Text(step).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Divider()
                        DisclosureGroup("More to explore") {
                            VStack(alignment: .leading, spacing: 12) {
                                guide("Your own media", "Use Add Photos or Videos for files, GIFs and video, or choose the Photos button in Settings. An existing slideshow’s row has Add Photos.")
                                guide("Make it yours", "Expand a photo’s row → Appearance for shape, corners, paper mats, borders, shadows and tilt. More options holds opacity and hover reveal.")
                                guide("Where it lives", "More options holds stacking depth and Pin to this Space. The lock icon fixes a widget’s position. A collage shares depth and Space settings across its group.")
                                guide("Words and groups", "Create Collage groups existing widgets. Edit Collage adds captions, labels, fonts and outside borders; Arrange Labels lets you place text by hand.")
                                guide("Keep it private", "Settings → Privacy offers capture exclusion, automatic hiding while conferencing apps run and fullscreen hiding. Read each control’s limits before relying on it.")
                                guide("Pin more than photos", "Preferences → Menu bar reveals commands for clipboard images, a PDF page or a one-time screen-region capture. Enable a command, then find it under Add in the Arras menu.")
                                guide("Keep and transfer", "Settings → Preferences → Setups & backup exports one .arras file for another Mac. A photo’s actions menu can export just that widget.")
                            }.padding(.top, 8)
                        }.disclosureGroupStyle(FullRowDisclosureStyle()).font(.system(size: 12))
                            .accessibilityIdentifier("starter-feature-guide")
                    }.padding(.trailing, 4)
                }
            }.frame(height: min(530, max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 220)))
            Divider()
            HStack {
                Text("Original local artwork. Every example is editable.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Example") {
                    let existingIDs = Set(manager.photos.map(\.id))
                    if manager.addStarterExample(selected) {
                        let firstPhoto = manager.photos.first { !existingIDs.contains($0.id) && $0.desktopCollage == nil }
                        onAdded?(selected, firstPhoto?.id)
                        dismiss()
                    } else { couldNotAdd = true }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Add " + selected.title + " example")
                .accessibilityIdentifier("add-starter-example")
            }
        }
        .padding(22).frame(width: 730)
        .alert("Couldn’t Add Example", isPresented: $couldNotAdd) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your existing pictures are unchanged. Check available disk space and access to Arras’s storage, then try again.")
        }
    }

    private func guide(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
enum StarterArtwork {
    enum Error: LocalizedError {
        case couldNotEncode, couldNotSave
        var errorDescription: String? {
            switch self {
            case .couldNotEncode: "Its artwork could not be encoded."
            case .couldNotSave: "Its photo layout could not be saved."
            }
        }
    }
    static let cream = NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 1)
    static let charcoal = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.11, alpha: 1)
    static let terracotta = NSColor(srgbRed: 0.72, green: 0.29, blue: 0.18, alpha: 1)
    static let sand = NSColor(srgbRed: 0.82, green: 0.73, blue: 0.61, alpha: 1)
    static let backdrop = NSColor(srgbRed: 0.29, green: 0.36, blue: 0.39, alpha: 1)

    // Original bundled AI-generated artwork for stills; a generated geometric loop for animation.
    // Examples load offline and never use the user’s photo library.
    static func image(for example: StarterExample, index: Int = 0, phase: Int = 0) -> NSImage {
        let frame = example.frames[index]
        let size = NSSize(width: frame.width * 2, height: frame.height * 2)
        let samples = ["StarterCoast", "StarterBotanical", "StarterArchitecture"]
        let sampleIndex = example == .polaroid ? 1
            : (example == .galleryWall ? [1, 0, 2][index] : (index + phase) % samples.count)
        if example != .animated, let photo = NSImage(named: samples[sampleIndex]) {
            // Original bundled sample; only examples crop to their designed frame.
            // User imports continue to preserve their own aspect ratio.
            return NSImage(size: size, flipped: false) { bounds in
                let sourceSize = photo.size
                let ratio = bounds.width / bounds.height
                let cropSize = sourceSize.width / sourceSize.height > ratio
                    ? NSSize(width: sourceSize.height * ratio, height: sourceSize.height)
                    : NSSize(width: sourceSize.width, height: sourceSize.width / ratio)
                let focus = CGFloat([0.2, 0.55, 0.85][(index + phase) % 3])
                let crop = NSRect(x: (sourceSize.width - cropSize.width) * focus,
                                  y: (sourceSize.height - cropSize.height) * 0.5,
                                  width: cropSize.width, height: cropSize.height)
                photo.draw(in: bounds, from: crop, operation: .sourceOver, fraction: 1)
                return true
            }
        }
        return NSImage(size: size, flipped: false) { bounds in
            let w = bounds.width, h = bounds.height
            (index == 1 ? sand : cream).setFill()
            bounds.fill()
            let orbit = example == .animated ? sin(Double(phase) * .pi / 30) * 0.1 : Double(phase) * 0.05
            let diameter = min(w, h) * 0.56
            terracotta.setFill()
            NSBezierPath(ovalIn: NSRect(x: w * (0.18 + orbit), y: h * 0.22,
                                        width: diameter, height: diameter)).fill()
            charcoal.setFill()
            if index == 2 {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: w * 0.38, y: 0))
                path.line(to: NSPoint(x: w * 0.82, y: h * 0.86))
                path.line(to: NSPoint(x: w, y: 0))
                path.close(); path.fill()
            } else {
                NSBezierPath(roundedRect: NSRect(x: w * 0.62, y: h * 0.14,
                                                 width: w * 0.16, height: h * 0.72),
                             xRadius: w * 0.08, yRadius: w * 0.08).fill()
            }
            return true
        }
    }

    static let previews: [StarterExample: NSImage] = Dictionary(uniqueKeysWithValues: StarterExample.allCases.map { example in
        let artworks = example.frames.indices.map { image(for: example, index: $0) }
        let settings = example.collageSettings
        let bounds = example.sceneBounds(settings: settings)
        return (example, NSImage(size: NSSize(width: 560, height: 320), flipped: false) { canvas in
            // A quiet desktop backdrop makes glass and transparent grouping distinguishable.
            backdrop.setFill()
            canvas.fill()
            NSColor.white.withAlphaComponent(0.035).setFill()
            NSBezierPath(ovalIn: CGRect(x: 240, y: -150, width: 500, height: 500)).fill()
            let scene = bounds.insetBy(dx: -24, dy: -24)
            let scale = min(canvas.width / scene.width, canvas.height / scene.height)
            NSGraphicsContext.saveGraphicsState()
            let sceneTransform = NSAffineTransform()
            sceneTransform.translateX(by: canvas.midX - scene.midX * scale,
                                      yBy: canvas.midY - scene.midY * scale)
            sceneTransform.scale(by: scale)
            sceneTransform.concat()
            if let settings {
                let path = NSBezierPath(roundedRect: bounds, xRadius: settings.effectiveCornerRadius,
                                        yRadius: settings.effectiveCornerRadius)
                if settings.skin != .transparent {
                    let lightText = (NSColor.labelColor.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.5
                    (lightText ? NSColor.black.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.48)).setFill()
                    path.fill()
                }
                if settings.borderWidth > 0 {
                    (NSColor.fromHex(settings.borderColorHex) ?? .white).setStroke()
                    path.lineWidth = settings.borderWidth
                    path.stroke()
                }
            }
            for (index, frame) in example.frames.enumerated() {
                var item = PhotoItem(filename: "")
                example.configure(&item, index: index)
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: frame.midX, yBy: frame.midY)
                transform.rotate(byDegrees: CGFloat(item.tiltDegrees))
                transform.concat()
                let rect = NSRect(x: -frame.width / 2, y: -frame.height / 2,
                                  width: frame.width, height: frame.height)
                // Preview the same paper, edge and depth that the example will add.
                // A flat white rectangle concealed the differences between the looks.
                let outer = rect.insetBy(dx: -item.matWidth, dy: -item.matWidth)
                let silhouette = NSBezierPath(roundedRect: outer,
                                              xRadius: item.cornerRadius, yRadius: item.cornerRadius)
                NSGraphicsContext.saveGraphicsState()
                if item.shadowEnabled {
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(item.shadowOpacity)
                    shadow.shadowBlurRadius = item.shadowBlur
                    shadow.shadowOffset = NSSize(width: 0, height: -2)
                    shadow.set()
                }
                item.matColor.setFill()
                silhouette.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: item.cornerRadius, yRadius: item.cornerRadius).addClip()
                artworks[index].draw(in: rect)
                if item.borderWidth > 0 {
                    item.borderColor.setStroke()
                    let edge = NSBezierPath(roundedRect: rect.insetBy(dx: item.borderWidth / 2, dy: item.borderWidth / 2),
                                            xRadius: item.cornerRadius, yRadius: item.cornerRadius)
                    edge.lineWidth = item.borderWidth
                    edge.stroke()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            if let settings {
                // Use the same text measurement, placement and rotation as the desktop.
                for layout in CollageLabelLayout.layouts(settings: settings, in: bounds) {
                    NSGraphicsContext.saveGraphicsState()
                    let transform = NSAffineTransform()
                    transform.translateX(by: layout.rect.midX, yBy: layout.rect.midY)
                    transform.rotate(byRadians: layout.rotation)
                    transform.concat()
                    layout.text.draw(with: CGRect(x: -layout.rect.width / 2, y: -layout.rect.height / 2,
                                                  width: layout.rect.width, height: layout.rect.height),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        })
    })

    static func pngData(for image: NSImage) throws -> Data {
        guard let encoded = PhotoManager.encodeImportedStill(image), encoded.fileExtension == "png" else {
            throw Error.couldNotEncode
        }
        return encoded.data
    }

    static func animatedGIFData() throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 60, nil) else {
            throw Error.couldNotEncode
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for phase in 0..<60 {
            let image = image(for: .animated, phase: phase)
            var rect = NSRect(origin: .zero, size: image.size)
            guard let frame = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw Error.couldNotEncode }
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.04, kCGImagePropertyGIFUnclampedDelayTime: 0.04]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw Error.couldNotEncode }
        return data as Data
    }
}
