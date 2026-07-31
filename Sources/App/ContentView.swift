import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ContentView: View {
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?
    @State private var selectedPhotosItems: [PhotosPickerItem] = []
    @ObservedObject private var hotKeys = HotKeyManager.shared

    // SnapEngine stores this in UserDefaults rather than publishing it, so the
    // view seeds its own state from there once.
    @State private var snapEnabled = SnapEngine.shared.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if manager.photos.isEmpty {
                emptyView
            } else {
                photoList
            }

            // Sits directly above the footer so an available update is adjacent to
            // the version number it refers to, without shrinking the photo list
            // when there is nothing to report.
            UpdateBanner()

            Divider()
            footerBar
        }
        .frame(minWidth: 380)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(Constants.appName)
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            Spacer()

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

            Menu {
                Button("Export Layout…") { exportLayout() }
                Button("Import Layout…") { importLayout() }
            } label: {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export or import a .tableau layout bundle")
            .accessibilityLabel("Layout")
            .accessibilityHint("Export all photos, positions, and settings to a file, or import one from another Mac")
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
            Text("\(manager.photos.count) photo\(manager.photos.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

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
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let img = NSImage(contentsOf: url) {
                    manager.addPhoto(img)
                }
            }
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

        if panel.runModal() == .OK {
            let images = panel.urls.compactMap { NSImage(contentsOf: $0) }
            manager.addSpace(images: images)
        }
    }

    // MARK: - Layout Export/Import

    private func exportLayout() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tableau") ?? .data]
        panel.nameFieldStringValue = "My Desktop.tableau"
        panel.prompt = "Export"
        panel.message = "Save all photos, positions, and settings into a single file"

        // Off by default: a bundle meant for sharing shouldn't carry the author's
        // login and shortcut settings unless they say so.
        let includePrefs = NSButton(checkboxWithTitle: "Include app settings (shortcut, snapping, launch at login)", target: nil, action: nil)
        includePrefs.state = .off
        includePrefs.toolTip = "Positions are always stored relative to the screen, so the layout transfers to a Mac with different displays"
        panel.accessoryView = includePrefs

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try manager.exportLayout(to: url, includePreferences: includePrefs.state == .on)
        } catch {
            presentAlert(title: "Couldn't Export Layout", message: error.localizedDescription, style: .warning)
        }
    }

    private func importLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tableau") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a .tableau bundle to import"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Read the manifest first so the dialog can describe what's actually inside,
        // rather than asking the user to commit to an opaque file.
        let manifest = try? PhotoManager.inspect(url)

        // Never silently destroy the user's current widgets — always ask first.
        let choice = NSAlert()
        choice.messageText = "Import Layout"

        var details: [String] = []
        if let manifest {
            let count = manifest.itemCount ?? manifest.photos.count
            details.append("\(count) widget\(count == 1 ? "" : "s")")
            details.append("exported from Tableau \(manifest.appVersion)")
            details.append(manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))
        }
        let provenance = details.isEmpty ? "" : details.joined(separator: " · ") + "\n\n"

        choice.informativeText = provenance + (manager.photos.isEmpty
            ? "Add the photos from this bundle to your desktop."
            : "Add these photos to what you already have, or replace your current layout entirely? Replacing removes your existing widgets and can't be undone.")

        // Only offer the preferences toggle when the bundle actually carries them, and
        // leave it off — importing a shared layout must not silently rebind this Mac's
        // global shortcut or change what launches at login.
        var prefsCheckbox: NSButton?
        if let preferences = manifest?.preferences {
            let box = NSButton(
                checkboxWithTitle: "Also apply app settings (\(preferences.summary))",
                target: nil,
                action: nil
            )
            box.state = .off
            choice.accessoryView = box
            prefsCheckbox = box
        }

        choice.addButton(withTitle: "Merge")
        choice.addButton(withTitle: "Replace Everything")
        choice.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = choice.runModal()

        let mode: PhotoManager.LayoutImportMode
        switch response {
        case .alertFirstButtonReturn: mode = .merge
        case .alertSecondButtonReturn: mode = .replace
        default: return
        }

        do {
            let count = try manager.importLayout(from: url, mode: mode)
            if prefsCheckbox?.state == .on, let preferences = manifest?.preferences {
                manager.applyImportedPreferences(preferences)
            }
            onMenuUpdate?()
            if count == 0 {
                presentAlert(title: "Nothing to Import", message: "That bundle didn't contain any photos with valid images.", style: .informational)
            }
        } catch {
            presentAlert(title: "Couldn't Import Layout", message: error.localizedDescription, style: .warning)
        }
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func handlePhotosSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        for pickerItem in items {
            pickerItem.loadTransferable(type: Data.self) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let data):
                        guard let data else { return }
                        if let image = NSImage(data: data), image.isValid {
                            manager.addPhoto(image)
                            onMenuUpdate?()
                        }
                    case .failure:
                        break
                    }
                }
            }
        }
        Task { @MainActor in
            selectedPhotosItems = []
        }
    }
}

// MARK: - Photo Row

struct PhotoRowView: View {
    let item: PhotoItem
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header
            HStack(spacing: 0) {
                // Left: entire area expands/collapses
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        // Chevron
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.15), value: isExpanded)
                            .frame(width: 8)

                        // Thumbnail
                        thumbnailView

                        // Labels
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(manager.label(for: item))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(item.isVisible ? .primary : .secondary)
                                    .lineLimit(1)
                                badges
                            }
                            Text(collapsedStatus)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(rowAccessibilityLabel)
                .accessibilityValue(collapsedStatus)
                .accessibilityHint(isExpanded ? "Double-tap to collapse settings" : "Double-tap to expand settings")

                // Right: action buttons
                HStack(spacing: 6) {
                    toggleButton(
                        icon: item.isVisible ? "eye.fill" : "eye.slash",
                        color: item.isVisible ? .secondary : .quaternary,
                        tip: item.isVisible ? "Hide" : "Show",
                        hint: item.isVisible ? "Hides this photo from the desktop" : "Shows this photo on the desktop"
                    ) {
                        manager.toggleVisibility(item.id)
                        onMenuUpdate?()
                    }

                    toggleButton(
                        icon: "trash",
                        color: .quaternary,
                        tip: "Remove",
                        hint: "Removes this photo and deletes its saved copy. This can't be undone"
                    ) {
                        manager.removePhoto(item.id)
                        onMenuUpdate?()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // MARK: Expanded Panel
            if isExpanded {
                VStack(spacing: 0) {
                    separator
                    expandedPanel
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                }
            }
        }
        .background(rowBackground)
        .contextMenu {
            Button("Reveal in Finder") {
                revealInFinder()
            }
        }
        .onHover { isHovering = $0 }
    }

    // MARK: - Row Background

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isExpanded
                  ? Color(nsColor: .controlBackgroundColor)
                  : (isHovering
                     ? Color(nsColor: .controlBackgroundColor).opacity(0.5)
                     : Color.clear))
            .animation(.easeInOut(duration: 0.1), value: isHovering)
            .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let thumb = manager.thumbnail(for: item) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Badges

    private var badges: some View {
        HStack(spacing: 3) {
            if item.isLocked { iconBadge("lock.fill", .orange) }
            if item.isFloating { iconBadge("arrow.up.square", .blue) }
            if !item.spaceImageFilenames.isEmpty { iconBadge("folder.fill", .green) }
        }
    }

    private func iconBadge(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 8))
            .foregroundStyle(color)
    }

    // MARK: - Status (collapsed)

    private var collapsedStatus: String {
        if !item.spaceImageFilenames.isEmpty {
            let count = manager.folderImageCount(item.id)
            return "Folder · \(count) images · Showing \(item.folderImageIndex + 1)"
        }
        if !item.isVisible { return "Hidden" }
        return "Opacity \(Int(item.opacity * 100))%"
    }

    /// Combines name + status badges into one phrase so VoiceOver reads a single
    /// coherent sentence for the row instead of each fragment separately.
    private var rowAccessibilityLabel: String {
        var parts = [manager.label(for: item)]
        if item.isLocked { parts.append("locked") }
        if item.isFloating { parts.append("floating") }
        if !item.spaceImageFilenames.isEmpty { parts.append("space") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Button Helper

    private func toggleButton<S: ShapeStyle>(icon: String, color: S, tip: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tip)
        .accessibilityLabel(tip)
        .accessibilityHint(hint)
    }

    // MARK: - Separator

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 0.5)
            .padding(.horizontal, 10)
    }

    // MARK: - Expanded Panel

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Mode
            settingsGroup("MODE") {
                compactToggle("Float Above Windows", isOn: Binding(
                    get: { item.isFloating },
                    set: { manager.setFloating(item.id, $0); onMenuUpdate?() }
                ), hint: "Keeps this photo above other app windows instead of on the desktop")

                sliderRow("Opacity", value: Binding(
                    get: { item.opacity },
                    set: { manager.setOpacity(item.id, $0) }
                ), range: 0.1...1.0, step: 0.05) { "\(Int($0 * 100))%" }

                compactToggle("Pin to This Space", isOn: Binding(
                    get: { item.isSpaceBound },
                    set: { manager.setSpaceBound(item.id, $0); onMenuUpdate?() }
                ), hint: "Shows this photo only on the Space it currently sits on, instead of every Space")
            }

            separator

            // Appearance
            settingsGroup("APPEARANCE") {
                sliderRow("Corners", value: Binding(
                    get: { item.cornerRadius },
                    set: { manager.setCornerRadius(item.id, $0) }
                ), range: 0...50, step: 1) { "\(Int($0))px" }

                compactToggle("Shadow", isOn: Binding(
                    get: { item.shadowEnabled },
                    set: { manager.setShadow(item.id, enabled: $0, blur: item.shadowBlur, opacity: item.shadowOpacity) }
                ), hint: "Adds a drop shadow behind the photo")

                if item.shadowEnabled {
                    sliderRow("Blur", value: Binding(
                        get: { item.shadowBlur },
                        set: { manager.setShadow(item.id, enabled: true, blur: $0, opacity: item.shadowOpacity) }
                    ), range: 0...30, step: 1) { "\(Int($0))" }
                    .padding(.leading, 12)
                }

                borderRow

                compactToggle("Edge Fade", isOn: Binding(
                    get: { item.vignetteEnabled },
                    set: { manager.setVignette(item.id, enabled: $0) }
                ), hint: "Fades the photo's edges to transparent")

                compactToggle("Adapt to Dark Mode", isOn: Binding(
                    get: { item.themeAdaptive },
                    set: { manager.setThemeAdaptive(item.id, $0) }
                ), hint: "In Dark Mode: dims the photo so it doesn't glare, deepens the shadow, and adds a hairline edge so it doesn't melt into a dark wallpaper")
            }

            // Folder
            if !item.spaceImageFilenames.isEmpty {
                separator
                settingsGroup("SMART CANVAS") {
                    folderControls
                }
            }

            separator

            // Actions
            actionsRow
        }
    }

    // MARK: - Border

    private var borderRow: some View {
        HStack(spacing: 6) {
            Text("Border")
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .frame(width: 48, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { item.borderWidth },
                set: { manager.setBorder(item.id, width: $0, colorHex: item.borderColorHex) }
            ), in: 0...5, step: 0.5)
            .controlSize(.small)
            .accessibilityLabel("Border width")
            .accessibilityValue(item.borderWidth > 0 ? String(format: "%.1f pixels", item.borderWidth) : "Off")
            Text(item.borderWidth > 0 ? String(format: "%.1f", item.borderWidth) : "Off")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
                .accessibilityHidden(true)
            if item.borderWidth > 0 {
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor.fromHex(item.borderColorHex) ?? .white) },
                    set: { manager.setBorder(item.id, width: item.borderWidth, colorHex: NSColor($0).hexString) }
                ))
                .labelsHidden()
                .frame(width: 20)
                .accessibilityLabel("Border color")
            }
        }
    }

    // MARK: - Folder Controls

    @ViewBuilder
    private var folderControls: some View {
        let count = manager.folderImageCount(item.id)

        // Sizing Mode
        HStack(spacing: 6) {
            Text("Mode")
                .font(.system(size: 11))
                .frame(width: 48, alignment: .leading)
                .accessibilityHidden(true)
            Picker("", selection: Binding(
                get: { item.folderSizeMode },
                set: { manager.setFolderSizeMode(item.id, $0) }
            )) {
                Text("Dynamic").tag("dynamic")
                Text("Fixed Frame").tag("fixed")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .accessibilityLabel("Sizing mode")
            .accessibilityHint("Dynamic resizes each image to fit without cropping. Fixed Frame keeps the widget size and crops images to fill it")
        }

        Button("Add More Photos to Space...") {
            appendPhotos()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityHint("Adds more images to this rotating space")

        // Navigation
        HStack {
            Text("Image")
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text("\(item.folderImageIndex + 1) of \(count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .accessibilityHidden(true)
            Spacer()
            Button { manager.prevFolderImage(item.id); onMenuUpdate?() }
                label: { Image(systemName: "chevron.left").font(.system(size: 10)) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Previous image")
                .accessibilityHint("Shows the previous image in this space, image \(item.folderImageIndex + 1) of \(count)")
            Button { manager.nextFolderImage(item.id); onMenuUpdate?() }
                label: { Image(systemName: "chevron.right").font(.system(size: 10)) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Next image")
                .accessibilityHint("Shows the next image in this space, image \(item.folderImageIndex + 1) of \(count)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image \(item.folderImageIndex + 1) of \(count)")

        // Rotation
        HStack(spacing: 6) {
            Text("Rotate")
                .font(.system(size: 11))
                .frame(width: 48, alignment: .leading)
                .accessibilityHidden(true)
            Picker("", selection: Binding(
                get: { item.rotationInterval },
                set: { manager.setRotationInterval(item.id, $0) }
            )) {
                Text("On Click").tag("click")
                Divider()
                Text("30 seconds").tag("30s")
                Text("5 minutes").tag("5m")
                Text("Hourly").tag("hourly")
                Text("Daily").tag("daily")
                Divider()
                Text("Custom…").tag("custom")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityLabel("Rotation interval")
            .accessibilityHint("How often this space cycles to the next image")
        }

        // Custom interval
        if item.rotationInterval == "custom" {
            HStack(spacing: 6) {
                Text("Every")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("", value: Binding(
                    get: { item.customRotationSeconds },
                    set: { manager.setCustomRotationSeconds(item.id, $0) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 60)
                .accessibilityLabel("Custom rotation interval in seconds")
                Text("seconds")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 12)
        }

        // Info
        VStack(alignment: .leading, spacing: 3) {
            hintText("Double-click the photo on your desktop to go to next image")
            if item.folderSizeMode == "dynamic" {
                hintText("Dynamic: Images resize without cropping. Each photo remembers its size.")
            } else {
                hintText("Fixed Frame: Widget stays fixed. Images scale and crop to fill the frame.")
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(spacing: 12) {
            actionLink("Rename…", hint: "Change this photo's display name") {
                let alert = NSAlert()
                alert.messageText = "Rename"
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
                let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                tf.stringValue = manager.label(for: item)
                tf.isEditable = true; tf.isBezeled = true; tf.bezelStyle = .roundedBezel
                alert.accessoryView = tf
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    manager.renamePhoto(item.id, to: tf.stringValue)
                    onMenuUpdate?()
                }
            }

            if item.spaceImageFilenames.isEmpty {
                actionLink("Replace…", hint: "Choose a different image, keeping this photo's position and settings") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .tiff]
                    panel.allowsMultipleSelection = false; panel.prompt = "Replace"
                    NSApp.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
                        manager.replacePhoto(item.id, with: img)
                        onMenuUpdate?()
                    }
                }
            }

            actionLink("Duplicate", hint: "Creates a copy of this photo at a slightly offset position") {
                manager.duplicatePhoto(item.id)
                onMenuUpdate?()
            }

            Spacer()
        }
    }

    // MARK: - Reusable Components

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            content()
        }
    }

    private func compactToggle(_ label: String, isOn: Binding<Bool>, hint: String = "") -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
            .accessibilityHint(hint)
    }

    private func sliderRow(
        _ label: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        format: @escaping (CGFloat) -> String
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 48, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityValue(format(value.wrappedValue))
            Text(format(value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private func actionLink(_ title: String, hint: String = "", action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .accessibilityHint(hint)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.quaternary)
    }

    private func revealInFinder() {
        let filename: String
        if !item.spaceImageFilenames.isEmpty {
            let idx = min(item.folderImageIndex, item.spaceImageFilenames.count - 1)
            filename = item.spaceImageFilenames[idx]
        } else {
            filename = item.filename
        }
        let url = manager.storageDir.appendingPathComponent(filename)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
    private func appendPhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add to Space"
        panel.message = "Choose multiple images to append to this rotating space"

        if panel.runModal() == .OK {
            let images = panel.urls.compactMap { NSImage(contentsOf: $0) }
            manager.appendPhotosToSpace(item.id, images: images)
            onMenuUpdate?()
        }
    }
}
