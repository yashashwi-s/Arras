import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ContentView: View {
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?
    @State private var selectedPhotosItems: [PhotosPickerItem] = []
    @State private var photosImportsInFlight = 0
    private var isImporting: Bool { photosImportsInFlight > 0 }
    private struct SlideshowSelection: Identifiable { let id: UUID }
    @State private var slideshowSelection: SlideshowSelection?
    @State private var showingStarterExamples = false
    @State private var showingSavedSetups = false
    @State private var showingPhotoTools = false
    @State private var addedExample: StarterExample?
    @State private var examplePhotoID: UUID?
    @State private var toolsPhotoID: UUID?
    @State private var searchText = ""
    @State private var listFilter: WidgetListFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if let example = addedExample {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Your example is ready", systemImage: "checkmark.circle")
                            .font(.headline)
                        Spacer()
                        Button { addedExample = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss example guide")
                    }
                    Text(example.title).font(.subheadline).bold()
                    Text(example.steps.first ?? example.detail)
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Next steps") {
                        ForEach(Array(example.steps.dropFirst().enumerated()), id: \.offset) { _, step in
                            Text(step).font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                        }
                    }.disclosureGroupStyle(FullRowDisclosureStyle()).font(.caption)
                    HStack {
                        Button("Find Example") {
                            searchText = example.title
                            listFilter = .all
                        }
                        Button("Photo Tools…") { toolsPhotoID = examplePhotoID; showingPhotoTools = true }
                        Button("Explore Examples…") { showingStarterExamples = true }
                    }.controlSize(.small)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16).padding(.bottom, 8)
                .accessibilityIdentifier("starter-next-step")
            }

            if manager.removedWidgetCount > 0 {
                HStack {
                    Text("\(manager.removedWidgetCount) removed · recoverable until the next removal")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") {
                        do { try manager.restoreRemovedWidgets(); onMenuUpdate?() }
                        catch { AppDialog.inform(title: "Couldn’t Restore Widgets", message: error.localizedDescription, style: .warning) }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }

            if manager.photos.isEmpty {
                emptyView
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a photo or collage", text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("widget-search")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                    Picker("Show", selection: $listFilter) {
                        ForEach(WidgetListFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                }
                .padding(10)
                .settingsSectionSurface()
                .padding(.horizontal, 20).padding(.bottom, 8)
                if manager.filteredWidgetRoots(query: searchText, filter: listFilter).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("No matching widgets").font(.headline)
                        Text("Try another name or show all your widgets.").font(.caption).foregroundStyle(.secondary)
                        Button("Show All Widgets") { searchText = ""; listFilter = .all }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    photoList
                }
            }

            Divider()
            footerBar
        }
        .frame(minWidth: Constants.settingsMinimumWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: manager.photos.isEmpty) { _, isEmpty in
            if isEmpty { addedExample = nil }
        }
        .onChange(of: selectedPhotosItems) { _, newItems in
            handlePhotosSelection(newItems)
        }
        // Keep presentation outside lazy rows: editing media can recycle their view hosts.
        .sheet(item: $slideshowSelection) { selection in
            SlideshowEditor(itemID: selection.id, manager: manager) { onMenuUpdate?() }
        }
        .sheet(isPresented: $showingPhotoTools) {
            PhotoToolsView(manager: manager, initialPhotoID: toolsPhotoID, onChange: onMenuUpdate)
                .onDisappear { toolsPhotoID = nil }
        }
        .sheet(isPresented: $showingSavedSetups) {
            SavedSetupsView(manager: manager, onChange: onMenuUpdate)
        }
        .sheet(isPresented: $showingStarterExamples) {
            StarterExamplesView(manager: manager) { example, firstPhotoID in
                addedExample = example
                examplePhotoID = firstPhotoID
                searchText = ""
                listFilter = .all
                onMenuUpdate?()
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Add Photos or Videos…") { pickFile() }
                Button("From Photos Collection…") {
                    PhotosLibraryCollectionPicker.present(manager: manager, onMenuUpdate: onMenuUpdate)
                }
                Button("Create Slideshow…") { pickSpace() }
                Button("Create Collage") { _ = manager.addDesktopCollage(); onMenuUpdate?() }
                    .accessibilityIdentifier("create-desktop-collage")
                Divider()
                Button("Try an Example…") { showingStarterExamples = true }
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Add photo")
            .accessibilityHint("Choose a photo, create a slideshow, or group desktop widgets into a collage")

            Button { showingSavedSetups = true } label: {
                Label("Setups", systemImage: "rectangle.stack")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Save and switch complete desktop arrangements")

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
            .accessibilityLabel("Add from Photos")
            .accessibilityHint("Pick up to 20 photos from your Photos library")

            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button { _ = manager.undoArrangement(); onMenuUpdate?() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!manager.canUndoArrangement)
                .help("Undo " + (manager.arrangementUndo.last?.name ?? "Arrangement"))
                .accessibilityLabel("Undo arrangement")
                Button { _ = manager.redoArrangement(); onMenuUpdate?() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!manager.canRedoArrangement)
                .help("Redo " + (manager.arrangementRedo.last?.name ?? "Arrangement"))
                .accessibilityLabel("Redo arrangement")
            }
            .buttonStyle(.borderless)
            Button { showingPhotoTools = true } label: {
                Label("Tools", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityIdentifier("photo-tools")
            .help("Edit photos, reuse appearance, arrange widgets and save setups")
        }
        .frame(height: 24)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    /// Deliberately thin. Launch at login, snapping and the global shortcut moved
    /// to Preferences — this tab is the photo list, and a footer full of app-wide
    /// switches made it the home for everything else too.
    private var footerBar: some View {
        HStack(spacing: 8) {
            if !manager.selectedPhotoIDs.isEmpty {
                selectionToolbar
            } else if isImporting {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text("Adding photos…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                let photoCount = manager.photos.filter { $0.desktopCollage == nil }.count
                let collageCount = manager.photos.filter { $0.desktopCollage != nil }.count
                Text("\(photoCount) \(photoCount == 1 ? "photo" : "photos") · \(collageCount) \(collageCount == 1 ? "collage" : "collages")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            UpdateStatusView()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Selection toolbar

    private var selectionToolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Select All") { manager.selectAllPhotos() }
                    .accessibilityLabel("Select all photos")
                Button("Clear Selection") { manager.clearPhotoSelection() }
                    .accessibilityLabel("Clear photo selection")
                Divider()
                if let hint = manager.selectionArrangementHint {
                    Text(hint).font(.caption)
                }
                Menu("Align") {
                    ForEach(WidgetAlignment.allCases) { alignment in
                        Button(alignment.displayName) {
                            manager.alignSelected(alignment)
                            onMenuUpdate?()
                        }
                    }
                }
                .disabled(!manager.canAlignSelection)
                Menu("Distribute") {
                    ForEach(WidgetDistribution.allCases) { distribution in
                        Button(distribution.displayName) {
                            manager.distributeSelected(distribution)
                            onMenuUpdate?()
                        }
                        .disabled(!manager.canDistributeSelection(distribution))
                    }
                }
                .disabled(!WidgetDistribution.allCases.contains { manager.canDistributeSelection($0) })
                Button("Duplicate") {
                    _ = manager.duplicateSelectedPhotos()
                    onMenuUpdate?()
                }
                .disabled(manager.selectedAvailableWidgetCount == 0)
                Divider()
                Button("Remove Selected…", role: .destructive) {
                    let ids = manager.selectedPhotoIDs
                    if RemovalConfirmation.confirm(count: ids.count, origin: .settings) {
                        manager.removePhotos(ids)
                        onMenuUpdate?()
                    }
                }
                Divider()
                Button("Copy Appearance") { _ = manager.copySelectedStyle() }
                    .disabled(!manager.photos.contains { manager.selectedPhotoIDs.contains($0.id) && $0.desktopCollage == nil })
                Button("Paste Appearance") {
                    _ = manager.pasteSelectedStyle()
                    onMenuUpdate?()
                }
                .disabled(!manager.canPasteSelectedAppearance)
            } label: {
                Label("\(manager.selectedPhotoIDs.count) selected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Selection actions")
            .accessibilityValue("\(manager.selectedPhotoIDs.count) selected")
            .accessibilityIdentifier("photo-selection-actions")
            .help("Align, distribute, duplicate, or copy a style. Arrow keys nudge selected widgets.")

            Button { manager.clearPhotoSelection() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear photo selection")
            .help("Clear selection")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo-selection-toolbar")
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Start with your photo")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Button("Add Photos or Videos…") { pickFile() }
                    .controlSize(.regular)
                    .accessibilityHint("Pick an image file to place on your desktop")
                Button("From Photos Collection…") {
                    PhotosLibraryCollectionPicker.present(manager: manager, onMenuUpdate: onMenuUpdate)
                }

                Button("Create Slideshow…") { pickSpace() }
                    .controlSize(.regular)
                    .accessibilityHint("Pick several images to display as one rotating widget")
                Button("Create Collage") { _ = manager.addDesktopCollage(); onMenuUpdate?() }
                    .controlSize(.regular)
                    .accessibilityHint("Create a desktop collage, then drag photo widgets into it")
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
            .accessibilityLabel("Add from Photos")
            .accessibilityHint("Pick up to 20 photos from your Photos library")
            Button("Try an Example…") { showingStarterExamples = true }
                .buttonStyle(.link)
                .accessibilityIdentifier("try-starter-examples")
                .accessibilityHint("Choose a ready-made photo widget you can edit or remove")
            Spacer()
        }
    }

    // MARK: - Photo List

    private var photoList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(manager.filteredWidgetRoots(query: searchText, filter: listFilter)) { item in
                    if item.desktopCollage != nil {
                        DesktopCollageRow(item: item, manager: manager, onMenuUpdate: onMenuUpdate, onEditSlideshow: { slideshowSelection = SlideshowSelection(id: $0) }, searchText: searchText, listFilter: listFilter)
                    } else {
                        PhotoRowView(item: item, manager: manager, onMenuUpdate: onMenuUpdate,
                                     onEditSlideshow: { slideshowSelection = SlideshowSelection(id: $0) })
                            .settingsSectionSurface()
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .accessibilityIdentifier("photos-scroll-view")
    }

    // MARK: - File Pickers

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let result = await manager.importPhotos(urls: urls)
            onMenuUpdate?()
            ImportBatchPresenter.present(result, title: "Finder Import")
        }
    }

    private func pickSpace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.prompt = "Create Slideshow"
        panel.message = "Choose multiple images to display as a slideshow"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let result = await manager.addSpace(urls: urls)
            onMenuUpdate?()
            ImportBatchPresenter.present(result, title: "Slideshow Import")
        }
    }

    // MARK: - Layout Export/Import

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
        photosImportsInFlight += 1
        let generation = manager.desktopGeneration
        manager.beginMediaImport()

        Task { @MainActor in
            defer { photosImportsInFlight -= 1; manager.endMediaImport() }

            let loaded: [(Int, Data?)] = await withTaskGroup(of: (Int, Data?).self) { group in
                for (index, pickerItem) in items.enumerated() {
                    group.addTask {
                        (index, try? await pickerItem.loadTransferable(type: Data.self))
                    }
                }
                var collected: [(Int, Data?)] = []
                for await payload in group { collected.append(payload) }
                return collected.sorted { $0.0 < $1.0 }
            }

            guard !Task.isCancelled, manager.desktopGeneration == generation else { return }
            // Keep failed iCloud downloads in the same result as successful payloads. Empty
            // data is deliberately passed through the decoder so the batch remains one-for-one.
            let payloads = loaded.map { $0.1 ?? Data() }
            let names = items.indices.map { "Photos item \($0 + 1)" }
            let result = await manager.importPhotos(data: payloads, sourceNames: names)
            onMenuUpdate?()
            ImportBatchPresenter.present(result, title: "Photos Import")
        }
    }
}
