import AppKit
import SwiftUI

struct SlideshowEditor: View {
    let itemID: UUID
    @ObservedObject var manager: PhotoManager
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var filenames: [String]

    init(itemID: UUID, manager: PhotoManager, onDone: (() -> Void)? = nil) {
        self.itemID = itemID
        self.manager = manager
        self.onDone = onDone
        _filenames = State(initialValue: manager.photos.first(where: { $0.id == itemID })?.spaceImageFilenames ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit Slideshow").font(.title2.weight(.semibold))
                    Text("Add, remove, or arrange the photos in your slideshow.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { onDone?(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("slideshow-editor-done")
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Photos").font(.headline)
                List {
                    ForEach(Array(filenames.enumerated()), id: \.offset) { index, filename in
                        HStack(spacing: 10) {
                            thumbnail(filename)
                            Text(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button { move(index, by: -1) } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == 0 || !allowsManualMediaEditing)
                            .accessibilityLabel("Move photo up")
                            .accessibilityIdentifier("slideshow-move-up-\(index)")
                            Button { move(index, by: 1) } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == filenames.count - 1 || !allowsManualMediaEditing)
                            .accessibilityLabel("Move photo down")
                            .accessibilityIdentifier("slideshow-move-down-\(index)")
                            Button(role: .destructive) { remove(at: index) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(filenames.count == 1 || !allowsManualMediaEditing)
                            .accessibilityLabel("Remove photo from slideshow")
                            .accessibilityIdentifier("slideshow-remove-\(index)")
                        }
                        .padding(.vertical, 3)
                        .moveDisabled(!allowsManualMediaEditing)
                    }
                    .onMove(perform: reorder)
                }
                .listStyle(.inset)
                HStack {
                    Button("Add Photos…") { addPhotos() }
                        .disabled(!allowsManualMediaEditing)
                        .accessibilityIdentifier("slideshow-editor-add-photos")
                    Spacer()
                    Text(filenames.count == 1 ? "At least one photo is required." : "Drag or use the arrows to reorder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 310)
            .padding(20)
            Text(allowsManualMediaEditing
                 ? "This list sets the order for Ordered playback. Other playback modes follow their own order."
                 : "Disconnect the linked source in slideshow settings to edit these photos manually.")
                .font(.caption).foregroundStyle(.secondary)
                .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 580, height: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow-editor")
    }

    private func thumbnail(_ filename: String) -> some View {
        Group {
            if let image = NSImage(contentsOf: manager.storageDir.appendingPathComponent(filename)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 34)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func move(_ index: Int, by offset: Int) {
        guard allowsManualMediaEditing else { return }
        let destination = index + offset
        guard filenames.indices.contains(index), filenames.indices.contains(destination) else { return }
        filenames.swapAt(index, destination)
        apply()
    }

    private func reorder(from offsets: IndexSet, to destination: Int) {
        guard allowsManualMediaEditing else { return }
        filenames.move(fromOffsets: offsets, toOffset: destination)
        apply()
    }

    private func remove(at index: Int) {
        guard allowsManualMediaEditing, filenames.count > 1, filenames.indices.contains(index) else { return }
        filenames.remove(at: index)
        apply()
    }

    private func apply() {
        if !manager.applySlideshowEdit(itemID, imageFilenames: filenames) {
            filenames = manager.photos.first(where: { $0.id == itemID })?.spaceImageFilenames ?? []
        }
    }

    private var allowsManualMediaEditing: Bool {
        manager.photos.first(where: { $0.id == itemID })?.allowsManualMediaEditing ?? false
    }

    private func addPhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.prompt = "Add to Slideshow"
        panel.message = "Choose images to add to this slideshow"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let result = await manager.appendPhotosToSpace(itemID, urls: urls)
            filenames = manager.photos.first(where: { $0.id == itemID })?.spaceImageFilenames ?? filenames
            ImportBatchPresenter.present(result, title: "Slideshow Import")
        }
    }
}
