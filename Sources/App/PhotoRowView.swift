import SwiftUI
import AppKit

// MARK: - Shared control grid

/// One geometry for every labelled control in the settings panel.
///
/// The panel used to mix three different layouts: slider rows reserved a 48pt label gutter and
/// a 30pt value column, mat and border rows reserved 26pt, picker rows reserved nothing, and
/// switch rows put their label to the *right* of the control with no gutter at all — so eight
/// of fifteen rows broke the column and the right edge was ragged at three widths. Everything
/// goes through `settingRow` now, including the switches.
private enum Metrics {
    static let label: CGFloat = 68
    static let value: CGFloat = 46
    /// Wide enough for a real `ColorPicker` well. At 22pt the well overflowed its column and
    /// painted straight over the value to its left.
    static let accessory: CGFloat = 46
}

/// label · control · value · optional colour well. The value and accessory columns are always
/// reserved, so a row never reflows when a value appears or a colour well is revealed.
struct SettingRow<Control: View, Accessory: View>: View {
    let label: String
    var value: String?
    @ViewBuilder var control: () -> Control
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.label, alignment: .leading)
                .accessibilityHidden(true)

            control()

            Text(value ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.value, alignment: .trailing)
                .accessibilityHidden(true)

            accessory()
                .frame(width: Metrics.accessory, alignment: .trailing)
        }
    }
}

extension SettingRow where Accessory == EmptyView {
    init(_ label: String, value: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(label: label, value: value, control: control, accessory: { EmptyView() })
    }
}

extension SettingRow {
    init(_ label: String, value: String? = nil, @ViewBuilder control: @escaping () -> Control, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init(label: label, value: value, control: control, accessory: accessory)
    }
}

// MARK: - Photo Row

struct PhotoRowView: View {
    let item: PhotoItem
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @State private var isHovering = false
    @State private var showingFrameSheet = false
    @State private var showingRemoveConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                VStack(spacing: 0) {
                    separator
                    expandedPanel
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(rowBackground)
        .onHover { isHovering = $0 }
        .sheet(isPresented: $showingFrameSheet) {
            FrameInspector(item: item, manager: manager)
        }
        .confirmationDialog(
            "Remove Photo?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Photo", role: .destructive) {
                manager.removePhoto(item.id)
                onMenuUpdate?()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Remove \(manager.label(for: item)) and its saved frame from this Mac? This cannot be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isExpanded)
                        .frame(width: 8)

                    thumbnailView

                    VStack(alignment: .leading, spacing: 2) {
                        if isRenaming {
                            // Editing happens where the name already is. It used to open a
                            // modal alert, which is a lot of ceremony for changing a label.
                            TextField("", text: $draftName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .focused($nameFocused)
                                .onSubmit(commitRename)
                                .onExitCommand { isRenaming = false }
                                .onChange(of: nameFocused) { _, focused in
                                    if !focused { commitRename() }
                                }
                                .accessibilityLabel("Photo name")
                        } else {
                            Text(manager.label(for: item))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(item.isVisible ? .primary : .secondary)
                                .lineLimit(1)
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
            .allowsHitTesting(!isRenaming)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("photo-row-toggle-\(item.id.uuidString)")
            .accessibilityLabel(manager.label(for: item))
            .accessibilityValue("\(collapsedStatus), \(isExpanded ? "Expanded" : "Collapsed")")
            .accessibilityHint(isExpanded ? "Double-tap to collapse settings" : "Double-tap to expand settings")

            HStack(spacing: 4) {
                // Promoted from the status menu: the row already showed a lock *badge* for a
                // state there was no way to change from this window.
                iconButton(
                    item.isLocked ? "lock.fill" : "lock.open",
                    tint: item.isLocked ? .orange : .secondary,
                    tip: item.isLocked ? "Unlock position" : "Lock position",
                    hint: item.isLocked ? "Allows this photo to be dragged and resized again" : "Stops this photo being dragged or resized"
                ) {
                    manager.toggleLock(item.id)
                    onMenuUpdate?()
                }
                .disabled(!item.depth.isInteractive)

                iconButton(
                    item.isVisible ? "eye" : "eye.slash",
                    tint: item.isVisible ? .secondary : Color.secondary.opacity(0.4),
                    tip: item.isVisible ? "Hide" : "Show",
                    hint: item.isVisible ? "Hides this photo from the desktop" : "Shows this photo on the desktop"
                ) {
                    manager.toggleVisibility(item.id)
                    onMenuUpdate?()
                }

                Menu {
                    Button("Rename") { beginRename() }
                    Button(
                        item.spaceImageFilenames.isEmpty
                            ? "Replace Image…"
                            : "Replace Current Space Image…"
                    ) { replace() }
                    Button("Duplicate") {
                        manager.duplicatePhoto(item.id)
                        onMenuUpdate?()
                    }
                    Divider()
                    Button("Reveal in Finder") { revealInFinder() }
                    Divider()
                    Button("Remove", role: .destructive) {
                        showingRemoveConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .accessibilityLabel("More actions")
                .accessibilityHint("Rename, duplicate, reveal, replace, or remove this photo")
                .accessibilityIdentifier("photo-more-actions")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func iconButton(_ icon: String, tint: Color, tip: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tip)
        .accessibilityLabel(tip)
        .accessibilityHint(hint)
    }

    // MARK: Expanded panel

    /// Five controls at rest, down from fifteen. Everything that shapes how the photo is
    /// *drawn* moved into the Frame inspector, which has the width to lay it out properly;
    /// what stays here is what people change repeatedly.
    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Frame…") { showingFrameSheet = true }
                    .controlSize(.small)
                    .accessibilityIdentifier("photo-frame-inspector")
                    .accessibilityLabel("Edit frame")
                    .accessibilityHint("Shape, corners, shadow, mat, border and tilt")
                Spacer()
            }

            separator.padding(.vertical, 2)

            SettingRow("Style") {
                Picker("", selection: Binding(
                    get: { item.stylePreset.flatMap(StylePreset.init(rawValue:)) },
                    set: { if let preset = $0 { manager.applyPreset(item.id, preset) } }
                )) {
                    Text("Custom").tag(StylePreset?.none)
                    ForEach(StylePreset.allCases, id: \.self) { Text($0.displayName).tag(StylePreset?.some($0)) }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Style preset")
                .accessibilityHint("Applies a matching set of mat, border, shape and shadow settings in one step")
            }

            SettingRow("Size", value: "\(Int(item.widgetWidth)) px") {
                Slider(value: Binding(
                    get: { item.widgetWidth },
                    set: { manager.resize(item.id, to: $0) }
                ), in: 80...1200)
                .controlSize(.small)
                .accessibilityLabel("Width")
                .accessibilityValue("\(Int(item.widgetWidth)) pixels")
            }

            SettingRow("Opacity", value: "\(Int(item.opacity * 100))%") {
                Slider(value: Binding(
                    get: { item.opacity },
                    set: { manager.setOpacity(item.id, $0) }
                ), in: 0.1...1.0)
                .controlSize(.small)
                .accessibilityLabel("Opacity")
                .accessibilityValue("\(Int(item.opacity * 100)) percent")
            }

            SettingRow("Depth") {
                Picker("", selection: Binding(
                    get: { item.depth },
                    set: { manager.setDepth(item.id, $0); onMenuUpdate?() }
                )) {
                    ForEach(WidgetDepth.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Stacking depth")
                .accessibilityHint("Where this photo sits relative to desktop icons, the system's desktop widgets, and app windows")
            }

            if let caveat = item.depth.caveat {
                Text(caveat)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Metrics.label + 8)
            }

            SettingRow("Space") {
                Toggle("Pin to this Space", isOn: Binding(
                    get: { item.isSpaceBound },
                    set: { manager.setSpaceBound(item.id, $0); onMenuUpdate?() }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .accessibilityHint("Shows this photo only on the Space it currently sits on, instead of every Space")
                Spacer()
            }

            if !item.spaceImageFilenames.isEmpty {
                separator.padding(.vertical, 2)
                smartCanvasControls
            }

        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo-expanded-settings-\(item.id.uuidString)")
    }

    // MARK: Smart Canvas

    @ViewBuilder
    private var smartCanvasControls: some View {
        let count = manager.folderImageCount(item.id)

        SettingRow("Image", value: "\(item.folderImageIndex + 1)/\(count)") {
            HStack(spacing: 4) {
                Button { manager.prevFolderImage(item.id); onMenuUpdate?() }
                    label: { Image(systemName: "chevron.left").font(.system(size: 9)) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Previous image")
                Button { manager.nextFolderImage(item.id); onMenuUpdate?() }
                    label: { Image(systemName: "chevron.right").font(.system(size: 9)) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Next image")
                Spacer()
            }
        }

        SettingRow("Rotate") {
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
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Rotation interval")
        }

        if item.rotationInterval == "custom" {
            SettingRow("Every", value: "sec") {
                TextField("", value: Binding(
                    get: { item.customRotationSeconds },
                    set: { manager.setCustomRotationSeconds(item.id, $0) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 64)
                .accessibilityLabel("Custom rotation interval in seconds")
                Spacer()
            }
        }

        SettingRow("Fit") {
            Picker("", selection: Binding(
                get: { item.folderSizeMode },
                set: { manager.setFolderSizeMode(item.id, $0) }
            )) {
                Text("Dynamic").tag("dynamic")
                Text("Fixed").tag("fixed")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Sizing mode")
            .accessibilityHint("Dynamic resizes each image to fit without cropping. Fixed keeps the widget size and crops images to fill it")
        }

        HStack {
            Button("Add Photos…") { appendPhotos() }
                .controlSize(.small)
                .accessibilityHint("Adds more images to this rotating space")
            Spacer()
        }
    }

    // MARK: Chrome

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isExpanded
                  ? Color(nsColor: .controlBackgroundColor)
                  : (isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: isHovering)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isExpanded)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let thumb = manager.thumbnail(for: item) {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.gray.opacity(0.2))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 0.5)
    }

    /// One line that says everything the badges used to say in icons, in words VoiceOver can
    /// read and a sighted user doesn't have to decode.
    private var collapsedStatus: String {
        var parts: [String] = []
        if !item.isVisible { parts.append("Hidden") }
        if !item.spaceImageFilenames.isEmpty {
            parts.append("Space · \(manager.folderImageCount(item.id)) images")
        }
        if item.depth != .onDesktop { parts.append(item.depth.displayName.lowercased()) }
        if item.isLocked { parts.append("locked") }
        if item.opacity < 1.0 { parts.append("\(Int(item.opacity * 100))%") }
        return parts.isEmpty ? "On desktop" : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func beginRename() {
        draftName = manager.label(for: item)
        isRenaming = true
        // Focus has to wait a turn: the field does not exist until the view re-renders.
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != manager.label(for: item) else { return }
        manager.renamePhoto(item.id, to: trimmed)
        onMenuUpdate?()
    }

    private func replace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.allowsMultipleSelection = false
        panel.prompt = "Replace"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else {
            manager.recordMediaImportFailure("The selected image \(url.lastPathComponent) could not be decoded.")
            return
        }
        manager.replacePhoto(item.id, with: image)
        onMenuUpdate?()
    }

    private func revealInFinder() {
        let filename: String
        if !item.spaceImageFilenames.isEmpty {
            let index = min(item.folderImageIndex, item.spaceImageFilenames.count - 1)
            filename = item.spaceImageFilenames[index]
        } else {
            filename = item.filename
        }
        NSWorkspace.shared.selectFile(
            manager.storageDir.appendingPathComponent(filename).path,
            inFileViewerRootedAtPath: ""
        )
    }

    private func appendPhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.prompt = "Add to Space"
        panel.message = "Choose images to append to this rotating space"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            manager.appendPhotosToSpace(item.id, urls: panel.urls)
            onMenuUpdate?()
        }
    }
}
