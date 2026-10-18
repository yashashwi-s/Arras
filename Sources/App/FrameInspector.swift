import SwiftUI
import AppKit

/// Photo-first styling: compare complete looks, then fine-tune individual controls.
struct FrameInspector: View {
    let item: PhotoItem
    @ObservedObject var manager: PhotoManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showingAdvanced = false
    @State private var showingAdjustments = false
    @State private var showingResetConfirmation = false

    /// Re-read from the manager rather than captured, so the sheet reflects edits made through
    /// it (`item` is a value copied when the sheet opened).
    private var live: PhotoItem {
        manager.photos.first { $0.id == item.id } ?? item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Appearance")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(manager.label(for: live))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Appearance for \(manager.label(for: live))")
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            appearancePreview(live, size: NSSize(width: 500, height: 164))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Color(nsColor: .underPageBackgroundColor))
                .accessibilityLabel("Live appearance preview")
            Text("Changes appear on your desktop as you edit.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 8)
            Picker("Appearance controls", selection: $showingAdjustments) {
                Text("Looks").tag(false)
                Text("Adjust").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if showingAdjustments {
                        basics
                        Divider().padding(.vertical, 2)
                        advanced
                    } else {
                        presetChoices
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .focusSection()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("frame-inspector-controls")

            Divider()

            HStack {
                Button("Reset") { showingResetConfirmation = true }
                    .controlSize(.regular)
                    .accessibilityIdentifier("frame-reset")
                    .accessibilityLabel("Reset frame settings")
                    .accessibilityHint("Opens a confirmation before returning every frame setting to the Plain preset")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.regular)
                    .accessibilityIdentifier("frame-done")
                    .accessibilityLabel("Done")
                    .accessibilityHint("Closes Appearance")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 670)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("frame-inspector")
        .alert(
            "Reset Appearance?",
            isPresented: $showingResetConfirmation
        ) {
            Button("Reset Appearance", role: .destructive) {
                manager.applyPreset(live.id, .minimal)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All shape, shadow, mat, border, fade and tilt changes will return to the Plain preset.")
        }
        .onExitCommand { dismiss() }
    }

    @ViewBuilder
    private func appearancePreview(_ photo: PhotoItem, size: NSSize) -> some View {
        if let thumbnail = manager.thumbnail(for: photo, size: 600),
           let rendered = PhotoAppearancePreview.image(photo: photo, thumbnail: thumbnail, size: size) {
            Image(nsImage: rendered).resizable().frame(width: size.width, height: size.height)
        } else {
            Image(systemName: "photo").frame(width: size.width, height: size.height).foregroundStyle(.secondary)
        }
    }

    private func presetPreview(_ preset: StylePreset) -> some View {
        appearancePreview(preset.applying(to: live), size: NSSize(width: 140, height: 82))
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }

    // MARK: - Basics

    @ViewBuilder
    private var presetChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a look").font(.subheadline.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(StylePreset.allCases, id: \.self) { preset in
                    Button { manager.applyPreset(live.id, preset) } label: {
                        VStack(spacing: 6) {
                            presetPreview(preset)
                            Text(preset.displayName).font(.caption)
                                .foregroundStyle(.primary)
                        }
                        .padding(8).frame(maxWidth: .infinity)
                        .background(live.stylePreset == preset.rawValue ? Color.accentColor.opacity(0.1) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(live.stylePreset == preset.rawValue ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.displayName)
                    .accessibilityValue(live.stylePreset == preset.rawValue ? "Selected" : "Not selected")
                    .help(preset.detail)
                }
            }
            Text(live.stylePreset.flatMap(StylePreset.init(rawValue:))?.detail ?? "Custom look · open Adjust to fine-tune it.")
                .font(.caption).foregroundStyle(.secondary)
        }

    }

    @ViewBuilder
    private var basics: some View {
        SettingRow("Shape") {
            Picker("", selection: Binding(
                get: { PhotoShapeMask(rawValue: live.shapeMask) ?? .roundedRect },
                set: { manager.setShapeMask(live.id, $0) }
            )) {
                ForEach(PhotoShapeMask.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Shape mask")
            .accessibilityHint("Crops the photo, its mat, border and shadow to this silhouette")
        }

        SettingRow("Corners", value: "\(Int(live.cornerRadius)) px") {
            Slider(value: Binding(
                get: { live.cornerRadius },
                set: { manager.setCornerRadius(live.id, $0) }
            ), in: 0...50, step: 1)
            .controlSize(.small)
            .accessibilityLabel("Corner radius")
            .accessibilityValue("\(Int(live.cornerRadius)) pixels")
        }

        SettingRow("Shadow", value: live.shadowEnabled ? "\(Int(live.shadowBlur))" : "Off") {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { live.shadowEnabled },
                    set: {
                        manager.setShadow(live.id, enabled: $0, blur: live.shadowBlur, opacity: live.shadowOpacity)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Shadow")
                .accessibilityValue(live.shadowEnabled ? "On" : "Off")

                Slider(value: Binding(
                    get: { live.shadowBlur },
                    set: {
                        manager.setShadow(live.id, enabled: true, blur: $0, opacity: live.shadowOpacity)
                    }
                ), in: 0...30, step: 1)
                .controlSize(.small)
                .disabled(!live.shadowEnabled)
                .accessibilityLabel("Shadow blur")
                .accessibilityValue(live.shadowEnabled ? "\(Int(live.shadowBlur)) pixels" : "Disabled")
            }
        }

        SettingRow("Mat", value: live.matWidth > 0 ? "\(Int(live.matWidth)) px" : "Off") {
            Slider(value: Binding(
                get: { live.matWidth },
                set: { manager.setMat(live.id, width: $0, colorHex: live.matColorHex) }
            ), in: 0...40, step: 1)
            .controlSize(.small)
            .accessibilityLabel("Mat width")
            .accessibilityValue(live.matWidth > 0 ? "\(Int(live.matWidth)) pixels" : "Off")
            .accessibilityHint("A solid inset border between the frame and the photo, like a mounted print")
        } accessory: {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: live.matColor) },
                set: { manager.setMat(live.id, width: live.matWidth, colorHex: NSColor($0).hexString) }
            ))
            .labelsHidden()
            .frame(width: 42, height: 22)
            .opacity(live.matWidth > 0 ? 1 : 0.25)
            .disabled(live.matWidth == 0)
            .accessibilityLabel("Mat colour")
        }

        SettingRow("Border", value: live.borderWidth > 0 ? String(format: "%.1f", live.borderWidth) : "Off") {
            Slider(value: Binding(
                get: { live.borderWidth },
                set: { manager.setBorder(live.id, width: $0, colorHex: live.borderColorHex) }
            ), in: 0...5, step: 0.5)
            .controlSize(.small)
            .accessibilityLabel("Border width")
            .accessibilityValue(live.borderWidth > 0 ? "\(String(format: "%.1f", live.borderWidth)) pixels" : "Off")
        } accessory: {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor.fromHex(live.borderColorHex) ?? .white) },
                set: { manager.setBorder(live.id, width: live.borderWidth, colorHex: NSColor($0).hexString) }
            ))
            .labelsHidden()
            .frame(width: 42, height: 22)
            .opacity(live.borderWidth > 0 ? 1 : 0.25)
            .disabled(live.borderWidth == 0)
            .accessibilityLabel("Border colour")
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advanced: some View {
        // A hand-rolled disclosure rather than DisclosureGroup. DisclosureGroup indents its
        // content, which pushed the colour-well column past the right edge of the sheet — and
        // its label is inert, so clicking the word "Advanced" did nothing. This keeps the
        // advanced rows on exactly the same grid as the basics and makes the whole header row
        // the hit target.
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { showingAdvanced.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showingAdvanced ? 90 : 0))
                    Text("Advanced")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced frame settings")
            .accessibilityValue(showingAdvanced ? "expanded" : "collapsed")
            .accessibilityHint("Shows or hides stroke, gradient, edge fade and tilt controls")
            .accessibilityIdentifier("frame-advanced-toggle")

            if showingAdvanced {
        SettingRow("Stroke") {
            Picker("", selection: Binding(
                get: { PhotoBorderStyle(rawValue: live.borderStyle) ?? .solid },
                set: { manager.setBorderStyle(live.id, $0) }
            )) {
                ForEach(PhotoBorderStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .disabled(live.borderWidth == 0)
            .accessibilityLabel("Border stroke style")
            .accessibilityHint("Choose a solid, dashed or dotted border")
            .accessibilityIdentifier("frame-border-stroke")
        }

        SettingRow("Gradient", value: live.borderGradientEnabled ? "On" : "Off") {
            Toggle("", isOn: Binding(
                get: { live.borderGradientEnabled },
                set: {
                    manager.setBorderGradient(live.id, enabled: $0, colorHex: live.borderGradientColorHex)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(live.borderWidth == 0)
            .accessibilityLabel("Gradient border")
            .accessibilityValue(live.borderGradientEnabled ? "On" : "Off")
            .help("Sweeps from the border colour to a second colour instead of one flat colour")
            Spacer()
        } accessory: {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: live.borderGradientColor) },
                set: {
                    manager.setBorderGradient(live.id, enabled: true, colorHex: NSColor($0).hexString)
                }
            ))
            .labelsHidden()
            .frame(width: 42, height: 22)
            .opacity(live.borderGradientEnabled ? 1 : 0.25)
            .disabled(!live.borderGradientEnabled)
            .accessibilityLabel("Second border colour")
        }

        SettingRow("Soft Vignette", value: live.vignetteEnabled ? "On" : "Off") {
            Toggle("", isOn: Binding(
                get: { live.vignetteEnabled },
                set: { manager.setVignette(live.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("Edge fade")
            .accessibilityValue(live.vignetteEnabled ? "On" : "Off")
            .accessibilityHint("Darkens the photo's edges and corners")
            .accessibilityIdentifier("frame-edge-fade")
            Spacer()
        }

        SettingRow("Tilt", value: "\(Int(live.tiltDegrees))°") {
            Slider(value: Binding(
                get: { CGFloat(live.tiltDegrees) },
                set: { manager.setTilt(live.id, Double($0)) }
            ), in: -12...12, step: 1)
            .controlSize(.small)
            .accessibilityLabel("Tilt")
            .accessibilityValue("\(Int(live.tiltDegrees)) degrees")
            .accessibilityHint("Rotates the frame from minus twelve to plus twelve degrees")
        }
            }
        }
    }
}


/// Uses the desktop's actual layers, including masks, mats, tilt, border and shadows.
/// The source thumbnail already includes reference edits, so never apply them twice.
@MainActor
enum PhotoAppearancePreview {
    static func image(photo: PhotoItem, thumbnail: NSImage, size: NSSize) -> NSImage? {
        let saved = NSRectFromString(photo.frameString).size
        let photoSize = saved.width > 0 && saved.height > 0 ? saved : thumbnail.size
        guard photoSize.width > 0, photoSize.height > 0, size.width > 0, size.height > 0 else { return nil }
        let inset = PhotoCanvas.inset(photoSize: photoSize, shadowEnabled: photo.shadowEnabled,
                                     shadowBlur: photo.shadowBlur, matWidth: photo.matWidth,
                                     tiltDegrees: CGFloat(photo.tiltDegrees)) + 4
        let canvas = NSSize(width: photoSize.width + inset * 2, height: photoSize.height + inset * 2)
        var settings = photo
        settings.reference = PhotoReferenceSettings()
        let view = DraggablePhotoView(frame: NSRect(origin: .zero, size: canvas), content: .still(thumbnail),
                                      locked: true, canvasInset: inset, settings: settings)
        guard let layer = view.layer,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                            pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return nil }
        let scale = min(size.width / canvas.width, size.height / canvas.height)
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: (size.width - canvas.width * scale) / 2, y: (size.height - canvas.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        let result = NSImage(size: size)
        result.addRepresentation(bitmap)
        return result
    }
}
