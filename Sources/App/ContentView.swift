import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ContentView: View {
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?
    @State private var selectedPhotosItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if manager.photos.isEmpty {
                emptyView
            } else {
                photoList
            }

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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            Toggle("Launch at Login", isOn: Binding(
                get: { manager.launchAtLogin },
                set: {
                    manager.setLaunchAtLogin($0)
                    onMenuUpdate?()
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))

            Spacer()

            Text("v2.0.0")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.quaternary)
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
                Button("Create Space…") { pickSpace() }
                    .controlSize(.regular)
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

                // Right: action buttons
                HStack(spacing: 6) {
                    toggleButton(
                        icon: item.isVisible ? "eye.fill" : "eye.slash",
                        color: item.isVisible ? .secondary : .quaternary,
                        tip: item.isVisible ? "Hide" : "Show"
                    ) {
                        manager.toggleVisibility(item.id)
                        onMenuUpdate?()
                    }

                    toggleButton(
                        icon: "trash",
                        color: .quaternary,
                        tip: "Remove"
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

    // MARK: - Button Helper

    private func toggleButton<S: ShapeStyle>(icon: String, color: S, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tip)
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
                ))

                sliderRow("Opacity", value: Binding(
                    get: { item.opacity },
                    set: { manager.setOpacity(item.id, $0) }
                ), range: 0.1...1.0, step: 0.05) { "\(Int($0 * 100))%" }
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
                ))

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
                ))
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
            Slider(value: Binding(
                get: { item.borderWidth },
                set: { manager.setBorder(item.id, width: $0, colorHex: item.borderColorHex) }
            ), in: 0...5, step: 0.5)
            .controlSize(.small)
            Text(item.borderWidth > 0 ? String(format: "%.1f", item.borderWidth) : "Off")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            if item.borderWidth > 0 {
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor.fromHex(item.borderColorHex) ?? .white) },
                    set: { manager.setBorder(item.id, width: item.borderWidth, colorHex: NSColor($0).hexString) }
                ))
                .labelsHidden()
                .frame(width: 20)
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
            Picker("", selection: Binding(
                get: { item.folderSizeMode },
                set: { manager.setFolderSizeMode(item.id, $0) }
            )) {
                Text("Dynamic").tag("dynamic")
                Text("Fixed Frame").tag("fixed")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }

        Button("Add More Photos to Space...") {
            appendPhotos()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .trailing)

        // Navigation
        HStack {
            Text("Image")
                .font(.system(size: 11))
            Text("\(item.folderImageIndex + 1) of \(count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Spacer()
            Button { manager.prevFolderImage(item.id); onMenuUpdate?() }
                label: { Image(systemName: "chevron.left").font(.system(size: 10)) }
                .buttonStyle(.bordered).controlSize(.small)
            Button { manager.nextFolderImage(item.id); onMenuUpdate?() }
                label: { Image(systemName: "chevron.right").font(.system(size: 10)) }
                .buttonStyle(.bordered).controlSize(.small)
        }

        // Rotation
        HStack(spacing: 6) {
            Text("Rotate")
                .font(.system(size: 11))
                .frame(width: 48, alignment: .leading)
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
        }

        // Custom interval
        if item.rotationInterval == "custom" {
            HStack(spacing: 6) {
                Text("Every")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { item.customRotationSeconds },
                    set: { manager.setCustomRotationSeconds(item.id, $0) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 60)
                Text("seconds")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
            actionLink("Rename…") {
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
                actionLink("Replace…") {
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

            actionLink("Duplicate") {
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

    private func compactToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
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
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
            Text(format(value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func actionLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
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
