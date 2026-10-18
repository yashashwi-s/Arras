import SwiftUI
import AppKit

struct CollageLabelWizard: View {
    @ObservedObject var manager: PhotoManager
    let id: UUID
    @Binding var settings: DesktopCollageSettings
    @Binding var selection: UUID
    var onClose: () -> Void
    @State private var opening: DesktopCollageSettings?

    private var selectedStyle: CollageLabelStyle { settings.labelStyle(for: selection) }
    private func place(_ center: CGPoint) {
        var style = selectedStyle
        reserveStrip(for: selection)
        style.placement = .free
        style.positionX = center.x; style.positionY = center.y
        settings.setLabelStyle(style, for: selection)
    }
    private var position: CGPoint {
        if selectedStyle.placement == .caption, let layout = manager.collageAppearanceLayout(id, settings: settings),
           let label = CollageLabelLayout.layouts(settings: layout.settings, in: layout.bounds).first(where: { $0.label.id == selection }) {
            return CGPoint(x: (label.rect.midX - layout.bounds.minX) / layout.bounds.width,
                           y: (label.rect.midY - layout.bounds.minY) / layout.bounds.height)
        }
        return CGPoint(x: selectedStyle.positionX, y: selectedStyle.positionY)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Place your labels").font(.system(size: 20, weight: .semibold))
                    Text("Drag text into place. Hold Option to bypass center guides.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Label", selection: $selection) {
                    ForEach(settings.textLabels) { label in
                        Text(label.id == CollageTextLabel.captionID ? "Main caption" : String(label.text.prefix(22))).tag(label.id)
                    }
                }.frame(width: 190)
            }
            InteractiveCollageCanvas(manager: manager, id: id, settings: settings, selection: selection,
                                     onSelect: { selection = $0 }, onMove: { label, center in
                var style = settings.labelStyle(for: label)
                reserveStrip(for: label)
                style.placement = .free; style.positionX = center.x; style.positionY = center.y
                settings.setLabelStyle(style, for: label)
            }, onRestore: { label, style in
                restorePosition(style, for: label)
            })
            .frame(height: 340).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Label placement canvas")
            if settings.textLabels.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                Text("Add text to the main caption or add a label in the editor first.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Horizontal").frame(width: 75, alignment: .leading)
                        Slider(value: Binding(get: { position.x }, set: { place(CGPoint(x: $0, y: position.y)) }), in: 0...1)
                        Text("\(Int(position.x * 100))%").monospacedDigit().frame(width: 36)
                    }
                    HStack {
                        Text("Vertical").frame(width: 75, alignment: .leading)
                        Slider(value: Binding(get: { position.y }, set: { place(CGPoint(x: position.x, y: $0)) }), in: 0...1)
                        Text("\(Int(position.y * 100))%").monospacedDigit().frame(width: 36)
                    }
                }
                VStack(spacing: 4) {
                    ForEach([CGFloat(0.9), 0.5, 0.1], id: \.self) { y in
                        HStack(spacing: 4) {
                            ForEach([CGFloat(0.1), 0.5, 0.9], id: \.self) { x in
                                Button { place(CGPoint(x: x, y: y)) } label: {
                                    Image(systemName: "circle.fill").font(.system(size: 5)).frame(width: 22, height: 16)
                                }.accessibilityLabel("Place label \(x < 0.5 ? "left" : (x > 0.5 ? "right" : "center")) \(y > 0.5 ? "top" : (y < 0.5 ? "bottom" : "middle"))")
                            }
                        }
                    }
                }
            }.font(.system(size: 12))
            Divider()
            HStack {
                Text("Placement previews on your desktop. Apply in the editor to save.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    if let opening {
                        for label in opening.textLabels { restorePosition(label.style, for: label.id) }
                        settings.freeCaptionBandHeight = opening.freeCaptionBandHeight
                    }
                    onClose()
                }.keyboardShortcut(.cancelAction)
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 650)
        .onAppear { if opening == nil { opening = settings } }
    }

    private func restorePosition(_ original: CollageLabelStyle, for id: UUID) {
        var style = settings.labelStyle(for: id)
        style.placement = original.placement
        style.positionX = original.positionX; style.positionY = original.positionY
        settings.setLabelStyle(style, for: id)
    }
    private func reserveStrip(for id: UUID) {
        if id == CollageTextLabel.captionID, let layout = manager.collageAppearanceLayout(self.id, settings: settings) {
            settings.reserveCaptionStripForFreePlacement(width: layout.bounds.width)
        }
    }
}

private struct InteractiveCollageCanvas: NSViewRepresentable {
    let manager: PhotoManager
    let id: UUID
    let settings: DesktopCollageSettings
    let selection: UUID
    var onSelect: (UUID) -> Void
    var onMove: (UUID, CGPoint) -> Void
    var onRestore: (UUID, CollageLabelStyle) -> Void

    func makeNSView(context: Context) -> CollagePreviewView { CollagePreviewView(frame: .zero) }
    func updateNSView(_ view: CollagePreviewView, context: Context) {
        view.onSelectLabel = onSelect
        view.onMoveLabel = onMove
        view.onRestoreLabel = onRestore
        view.configure(manager: manager, id: id, settings: settings, selectedLabel: selection)
    }
}
