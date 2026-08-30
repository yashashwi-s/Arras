import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ContentView: View {
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?
    @State private var selectedPhotosItems: [PhotosPickerItem] = []
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if manager.photos.isEmpty {
                emptyView
            } else {
                photoList
            }

            Divider()
            footerBar
        }
        .frame(minWidth: Constants.settingsMinimumWidth)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("From Finder…") { pickFile() }
                Button("Create Space…") { pickSpace() }
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Add photo")
            .accessibilityHint("Choose a photo from Finder, or create a rotating space from several photos")

            PhotosPicker(
                selection: $selectedPhotosItems,
                maxSelectionCount: 20,
                matching: .images
            ) {
                Label("Photos", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .onChange(of: selectedPhotosItems) { _, newItems in
                handlePhotosSelection(newItems)
            }
            .accessibilityLabel("Add from Photos")
            .accessibilityHint("Pick up to 20 photos from your Photos library")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    /// Deliberately thin. Launch at login, snapping and the global shortcut moved
    /// to Preferences — this tab is the photo list, and a footer full of app-wide
    /// switches made it the home for everything else too.
    private var footerBar: some View {
        HStack(spacing: 8) {
            if isImporting {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text("Adding photos…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(manager.photos.count) photo\(manager.photos.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            UpdateStatusView()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Place photos on your desktop")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Choose Photo…") { pickFile() }
                    .controlSize(.regular)
                    .accessibilityHint("Pick an image file to place on your desktop")
                Button("Create Space…") { pickSpace() }
                    .controlSize(.regular)
                    .accessibilityHint("Pick several images to display as one rotating widget")
            }
            PhotosPicker(
                selection: $selectedPhotosItems,
                maxSelectionCount: 20,
                matching: .images
            ) {
                Label("From Photos Library", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .onChange(of: selectedPhotosItems) { _, newItems in
                handlePhotosSelection(newItems)
            }
            .accessibilityLabel("Add from Photos")
            .accessibilityHint("Pick up to 20 photos from your Photos library")
            Spacer()
        }
    }

    // MARK: - Photo List

    private var photoList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(manager.photos) { item in
                    PhotoRowView(item: item, manager: manager, onMenuUpdate: onMenuUpdate)
                }
            }
            .padding(12)
        }
    }

    // MARK: - File Pickers

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            await manager.addPhotos(urls: urls)
            onMenuUpdate?()
        }
    }

    private func pickSpace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add Space"
        panel.message = "Choose multiple images to display as a rotating space"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            await manager.addSpace(urls: urls)
            onMenuUpdate?()
        }
    }

    // MARK: - Layout Export/Import



    private func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Fetches every picked asset concurrently, then imports the whole batch in one go.
    ///
    /// This used to hop each item's completion onto the main actor and do the decode, the JPEG
    /// re-encode, the window creation, a full rewrite of photos.json *and* a status-menu
    /// rebuild there — per photo. PhotoKit was fetching in parallel and then feeding a fully
    /// serialised main-actor pipeline. Failures were also swallowed silently: pick twenty,
    /// get seventeen, with nothing said about the other three.
    private func handlePhotosSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        selectedPhotosItems = []
        isImporting = true

        Task { @MainActor in
            defer { isImporting = false }

            let payloads: [Data] = await withTaskGroup(of: Data?.self) { group in
                for pickerItem in items {
                    group.addTask {
                        try? await pickerItem.loadTransferable(type: Data.self)
                    }
                }
                var collected: [Data] = []
                for await payload in group {
                    if let payload { collected.append(payload) }
                }
                return collected
            }

            if payloads.count < items.count {
                manager.recordMediaImportFailure(
                    "\(items.count - payloads.count) selected photo\((items.count - payloads.count) == 1 ? "" : "s") could not be downloaded from Photos."
                )
            }
            let added = await manager.addPhotos(data: payloads)
            onMenuUpdate?()

            if added < items.count {
                presentAlert(
                    title: "Some Photos Couldn't Be Added",
                    message: "\(items.count - added) of \(items.count) couldn't be read. They may still be downloading from iCloud.",
                    style: .informational
                )
            }
        }
    }
}
