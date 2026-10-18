import SwiftUI

/// An always-available route into tools that otherwise live in individual row menus.
struct PhotoToolsView: View {
    @ObservedObject var manager: PhotoManager
    var initialPhotoID: UUID? = nil
    var onChange: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var destination: Destination?
    @State private var feedback: String?

    private enum Destination: String, Identifiable {
        case appearance, reference, setups
        var id: String { rawValue }
    }
    private var photos: [PhotoItem] { manager.photos.filter { $0.desktopCollage == nil } }
    private var selected: PhotoItem? { photos.first { $0.id == selectedID } }
    private var canPasteAppearance: Bool {
        selectedID.map { manager.canPasteAppearance(to: [$0]) } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Photo Tools").font(.headline)
                    Text("Make a look, reuse it, and keep your favorite desktops.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Choose a photo").font(.headline)
                        Picker("Photo", selection: $selectedID) {
                            Text("Choose a photo…").tag(Optional<UUID>.none)
                            ForEach(photos) { photo in
                                Text(manager.label(for: photo) + (photo.isVisible ? "" : " · Hidden"))
                                    .tag(Optional(photo.id))
                            }
                        }
                        .accessibilityIdentifier("tools-photo-picker")
                        .disabled(photos.isEmpty)
                        if photos.isEmpty {
                            Text("Add a photo first, then return here to edit its look.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Appearance…", systemImage: "slider.horizontal.3") { destination = .appearance }
                            Button("Reference Tools…", systemImage: "crop.rotate") { destination = .reference }
                        }.disabled(selected == nil)
                        Text("Appearance changes the frame, shadow, colors and hover behavior. Reference Tools offers crop, rotation, flips, grayscale, notes and source links.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(selected?.spaceImageFilenames.isEmpty == false ? "Replace Current Slideshow Image…" : "Replace Image…", systemImage: "photo.badge.plus") {
                        replaceSelectedImage()
                    }.disabled(selected?.allowsManualMediaEditing != true)
                    Text(selected?.allowsManualMediaEditing == false
                         ? "This photo comes from a linked folder or Photos album. Change its source images there; sync keeps this widget up to date."
                         : "Use your own image while keeping the frame and styling.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Reuse a look").font(.headline)
                        Text("Copy appearance from the photo above, choose another photo, then paste. Its image, position and reference edits stay its own.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Copy Appearance") {
                                guard let selected, manager.copyAppearance(of: selected.id) else { return }
                                feedback = "Copied from \(manager.label(for: selected)). Choose another photo to paste."
                            }.disabled(selected == nil)
                            Button("Paste Appearance") {
                                guard let selected else { return }
                                if manager.pasteAppearance(to: [selected.id]) {
                                    feedback = "Appearance applied to \(manager.label(for: selected))."
                                    onChange?()
                                } else {
                                    feedback = "Appearance couldn’t be saved. The photo’s previous settings are still in place."
                                }
                            }.disabled(!canPasteAppearance)
                        }
                        if let feedback { Text(feedback).font(.caption).accessibilityIdentifier("tools-feedback") }
                        Text("For several photos, use the circles in the photo list and choose Paste Appearance from the selected-photos menu.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Arrange photos together").font(.headline)
                        Text("Select two or more photos using their circles in the list. The selected-photos menu offers Align and Distribute. Locked or hidden photos stay in place.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Create Collage in Add keeps photos together as a group. Open the collage’s controls to add photos and labels or adjust spacing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Keep a desktop you love").font(.headline)
                        Text("Save named setups before experimenting. Switch between them, restore the previous desktop, or recover the most recently removed widgets.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Saved Setups…", systemImage: "rectangle.stack") { destination = .setups }
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(width: 480, height: Constants.editorHeight(650))
        .onAppear {
            let selectedPhotos = photos.filter { manager.selectedPhotoIDs.contains($0.id) }
            if let initialPhotoID, photos.contains(where: { $0.id == initialPhotoID }) { selectedID = initialPhotoID }
            else if selectedPhotos.count == 1 { selectedID = selectedPhotos[0].id }
            else if photos.count == 1 { selectedID = photos[0].id }
        }
        .sheet(item: $destination) { target in
            switch target {
            case .appearance:
                if let selected { FrameInspector(item: selected, manager: manager) }
            case .reference:
                if let selected { ReferenceInspector(item: selected, manager: manager) }
            case .setups:
                SavedSetupsView(manager: manager, onChange: onChange)
            }
        }
    }
    private func replaceSelectedImage() {
        guard let selected, selected.allowsManualMediaEditing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.allowsMultipleSelection = false
        panel.prompt = "Replace"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            let result = await manager.replacePhoto(selected.id, with: url)
            onChange?()
            ImportBatchPresenter.present(result, title: "Replace Media")
        }
    }

}
