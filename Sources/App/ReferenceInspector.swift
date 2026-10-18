import SwiftUI
import AppKit

struct ReferenceInspector: View {
    let item: PhotoItem
    @ObservedObject var manager: PhotoManager
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PhotoReferenceSettings
    @State private var baseline: PhotoReferenceSettings
    @State private var original: NSImage?
    @State private var preview: NSImage?
    @State private var failure: String?

    init(item: PhotoItem, manager: PhotoManager) {
        self.item = item
        self.manager = manager
        _draft = State(initialValue: item.reference)
        _baseline = State(initialValue: item.reference)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reference Tools").font(.headline)
                    Text(manager.label(for: item)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let preview {
                        Image(nsImage: preview).resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 250)
                            .accessibilityLabel("Preview of your edits")
                        .background(Color(nsColor: .underPageBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("The original photo couldn’t be loaded.").frame(height: 250)
                    }
                    Text(item.spaceImageFilenames.isEmpty
                         ? "Edits apply to the desktop. Originals stay unchanged. Rotation and crop update the photo’s proportions."
                         : "Edits apply to every photo in this slideshow. Originals stay unchanged. Rotation and crop update the photo’s proportions.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Rotate Left", systemImage: "rotate.left") { draft.quarterTurns -= 1 }
                        Button("Rotate Right", systemImage: "rotate.right") { draft.quarterTurns += 1 }
                    }
                    HStack {
                        Toggle("Flip Horizontal", isOn: $draft.flipHorizontal)
                        Toggle("Flip Vertical", isOn: $draft.flipVertical)
                    }
                    Toggle("Grayscale", isOn: $draft.grayscale)
                    DisclosureGroup("Crop Original") {
                        VStack(spacing: 10) {
                            cropSlider("Width", value: $draft.cropWidth, range: 0.05...1)
                            cropSlider("Height", value: $draft.cropHeight, range: 0.05...1)
                            cropSlider("From left", value: $draft.cropX, range: 0...max(0.001, 1 - draft.cropWidth))
                            cropSlider("From bottom", value: $draft.cropY, range: 0...max(0.001, 1 - draft.cropHeight))
                        }.padding(.top, 8)
                    }
                    Button("Reset Image Edits") {
                        let note = draft.note, source = draft.sourceURL
                        draft = PhotoReferenceSettings()
                        draft.note = note
                        draft.sourceURL = source
                    }.disabled(!draft.hasImageEdits)
                    Divider()
                    Text("Notes").font(.headline)
                    TextEditor(text: $draft.note).frame(height: 90)
                        .accessibilityLabel("Reference notes")
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    TextField("Source link (https://…)", text: $draft.sourceURL)
                        .textFieldStyle(.roundedBorder)
                    if let url = draft.webURL {
                        Link("Open Source", destination: url)
                    } else if !draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Use a full http or https web address.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    do {
                        try manager.applyReference(draft, to: item.id, replacing: baseline)
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(original == nil)
            }.padding(16)
        }
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .frame(width: 500, height: Constants.editorHeight(710))
        .onAppear {
            original = manager.loadDisplayContent(for: item).flatMap {
                PhotoReferenceRenderer.previewSource($0.representativeImage)
            }
            updatePreview()
        }
        .onChange(of: draft.renderKey) { _, _ in updatePreview() }
        .alert("Couldn’t Save Reference Edits", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func cropSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(title)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 40)
        }
    }

    private func updatePreview() {
        // Keep crop controls and output in agreement when a wider crop reaches an edge.
        draft = draft.normalized
        preview = original.flatMap { PhotoReferenceRenderer.image($0, settings: draft) }
    }
}
