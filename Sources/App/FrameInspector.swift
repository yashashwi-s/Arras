import SwiftUI
import AppKit

/// Everything that shapes how a photo is drawn, in a sheet rather than in the 380pt photo list.
///
/// These eleven controls used to sit in the expanded row, which meant a column barely wide
/// enough for a slider had to hold segmented pickers, inline colour wells and mini switches as
/// well — and six of them appeared and disappeared conditionally, so every change made the
/// rows below jump. A sheet has the width to lay them out on one grid, and the four that only
/// matter once you are already fussing sit behind a disclosure.
struct FrameInspector: View {
    let item: PhotoItem
    @ObservedObject var manager: PhotoManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingAdvanced = false

    /// Re-read from the manager rather than captured, so the sheet reflects edits made through
    /// it (`item` is a value copied when the sheet opened).
    private var live: PhotoItem {
        manager.photos.first { $0.id == item.id } ?? item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Frame")
                    .font(.system(size: 13, weight: .semibold))
                Text(manager.label(for: live))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    basics
                    Divider().padding(.vertical, 2)
                    advanced
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            HStack {
                Button("Reset") { manager.applyPreset(live.id, .minimal) }
                    .controlSize(.regular)
                    .accessibilityHint("Returns every frame setting to the Minimal preset")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 460)
    }

    // MARK: - Basics

    @ViewBuilder
    private var basics: some View {
        SettingRow("Preset") {
            Picker("", selection: Binding(
                get: { live.stylePreset.flatMap(StylePreset.init(rawValue:)) },
                set: { if let preset = $0 { manager.applyPreset(live.id, preset) } }
            )) {
                Text("Custom").tag(StylePreset?.none)
                ForEach(StylePreset.allCases, id: \.self) { Text($0.displayName).tag(StylePreset?.some($0)) }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Style preset")
        }

        SettingRow("Shape") {
            Picker("", selection: Binding(
                get: { PhotoShapeMask(rawValue: live.shapeMask) ?? .roundedRect },
                set: { manager.setShapeMask(live.id, $0); manager.clearStylePreset(live.id) }
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
                set: { manager.setCornerRadius(live.id, $0); manager.clearStylePreset(live.id) }
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
                        manager.clearStylePreset(live.id)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Shadow")

                Slider(value: Binding(
                    get: { live.shadowBlur },
                    set: {
                        manager.setShadow(live.id, enabled: true, blur: $0, opacity: live.shadowOpacity)
                        manager.clearStylePreset(live.id)
                    }
                ), in: 0...30, step: 1)
                .controlSize(.small)
                .disabled(!live.shadowEnabled)
                .accessibilityLabel("Shadow blur")
            }
        }

        SettingRow("Mat", value: live.matWidth > 0 ? "\(Int(live.matWidth)) px" : "Off") {
            Slider(value: Binding(
                get: { live.matWidth },
                set: { manager.setMat(live.id, width: $0, colorHex: live.matColorHex); manager.clearStylePreset(live.id) }
            ), in: 0...40, step: 1)
            .controlSize(.small)
            .accessibilityLabel("Mat width")
            .accessibilityHint("A solid inset border between the frame and the photo, like a mounted print")
        } accessory: {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: live.matColor) },
                set: { manager.setMat(live.id, width: live.matWidth, colorHex: NSColor($0).hexString); manager.clearStylePreset(live.id) }
            ))
            .labelsHidden()
            .opacity(live.matWidth > 0 ? 1 : 0.25)
            .disabled(live.matWidth == 0)
            .accessibilityLabel("Mat colour")
        }

        SettingRow("Border", value: live.borderWidth > 0 ? String(format: "%.1f", live.borderWidth) : "Off") {
            Slider(value: Binding(
                get: { live.borderWidth },
                set: { manager.setBorder(live.id, width: $0, colorHex: live.borderColorHex); manager.clearStylePreset(live.id) }
            ), in: 0...5, step: 0.5)
            .controlSize(.small)
            .accessibilityLabel("Border width")
        } accessory: {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor.fromHex(live.borderColorHex) ?? .white) },
                set: { manager.setBorder(live.id, width: live.borderWidth, colorHex: NSColor($0).hexString); manager.clearStylePreset(live.id) }
            ))
            .labelsHidden()
            .opacity(live.borderWidth > 0 ? 1 : 0.25)
            .disabled(live.borderWidth == 0)
            .accessibilityLabel("Border colour")
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advanced: some View {
        DisclosureGroup(isExpanded: $showingAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow("Stroke") {
                    Picker("", selection: Binding(
                        get: { PhotoBorderStyle(rawValue: live.borderStyle) ?? .solid },
                        set: { manager.setBorderStyle(live.id, $0); manager.clearStylePreset(live.id) }
                    )) {
                        ForEach(PhotoBorderStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(live.borderWidth == 0)
                    .accessibilityLabel("Border stroke style")
                }

                SettingRow("Gradient", value: live.borderGradientEnabled ? "On" : "Off") {
                    Toggle("", isOn: Binding(
                        get: { live.borderGradientEnabled },
                        set: {
                            manager.setBorderGradient(live.id, enabled: $0, colorHex: live.borderGradientColorHex)
                            manager.clearStylePreset(live.id)
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(live.borderWidth == 0)
                    .accessibilityLabel("Gradient border")
                    .help("Sweeps from the border colour to a second colour instead of one flat colour")
                    Spacer()
                } accessory: {
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: live.borderGradientColor) },
                        set: {
                            manager.setBorderGradient(live.id, enabled: true, colorHex: NSColor($0).hexString)
                            manager.clearStylePreset(live.id)
                        }
                    ))
                    .labelsHidden()
                    .opacity(live.borderGradientEnabled ? 1 : 0.25)
                    .disabled(!live.borderGradientEnabled)
                    .accessibilityLabel("Second border colour")
                }

                SettingRow("Edge Fade", value: live.vignetteEnabled ? "On" : "Off") {
                    Toggle("", isOn: Binding(
                        get: { live.vignetteEnabled },
                        set: { manager.setVignette(live.id, enabled: $0); manager.clearStylePreset(live.id) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Edge fade")
                    .accessibilityHint("Darkens the photo's edges and corners")
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
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Advanced")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
