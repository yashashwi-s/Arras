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
    var displayTitle: String? = nil
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?
    var onEditSlideshow: ((UUID) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @State private var isHovering = false
    @State private var showingFrameSheet = false
    @State private var showingReferenceSheet = false
    @State private var showingMoreOptions = false
    @AppStorage("backup.archivalQuality") private var archivalQuality = false

    private var collageParent: PhotoItem? {
        guard let id = item.collageParentID else { return nil }
        return manager.photos.first { $0.id == id && $0.desktopCollage != nil }
    }
    private var effectiveDepth: WidgetDepth { collageParent?.depth ?? item.depth }
    private var inheritedLock: Bool { collageParent?.isLocked ?? false }
    private var effectiveLock: Bool { item.isLocked || inheritedLock }

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
        .sheet(isPresented: $showingReferenceSheet) {
            ReferenceInspector(item: item, manager: manager)
        }

    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Button(action: selectFromRow) {
                Image(systemName: manager.selectedPhotoIDs.contains(item.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(manager.selectedPhotoIDs.contains(item.id) ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(manager.selectedPhotoIDs.contains(item.id) ? "Selected" : "Select")
            .accessibilityLabel(manager.selectedPhotoIDs.contains(item.id) ? "Deselect \(manager.label(for: item))" : "Select \(manager.label(for: item))")
            .accessibilityValue(manager.selectedPhotoIDs.contains(item.id) ? "Selected" : "Not selected")
            .accessibilityHint("Click to toggle selection; Shift-click selects a range")
            .accessibilityIdentifier("photo-row-selection-\(item.id.uuidString)")

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
                            Text(displayTitle ?? manager.label(for: item))
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
                    effectiveLock ? "lock.fill" : "lock.open",
                    tint: effectiveLock ? .orange : .secondary,
                    tip: inheritedLock ? "Unlock collage" : (item.isLocked ? "Unlock position" : "Lock position"),
                    hint: inheritedLock ? "This widget is locked by its collage. Unlock the whole collage." : (item.isLocked ? "Allows this photo to be dragged and resized again" : "Stops this photo being dragged or resized")
                ) {
                    manager.toggleLock(item.id)
                    onMenuUpdate?()
                }
                .disabled(!effectiveDepth.isInteractive)

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
                    if item.collageParentID != nil {
                        Button("Remove from Collage") {
                            if manager.removeFromCollage(item.id) { onMenuUpdate?() }
                            else { AppDialog.inform(title: "Couldn’t Remove from Collage", message: "Your changes couldn’t be saved. Please try again.") }
                        }
                        .accessibilityIdentifier("detach-collage-member-" + item.id.uuidString)
                    }
                    if item.allowsManualMediaEditing {
                        Button(replaceTitle) { replace() }
                    }
                    Button("Duplicate") {
                        manager.duplicatePhoto(item.id)
                        onMenuUpdate?()
                    }
                    Divider()
                    Button("Reference Tools…") { showingReferenceSheet = true }
                    Divider()
                    Button("Copy Appearance") { _ = manager.copyAppearance(of: item.id) }
                        .help("Copy the frame, colors, shadow, opacity and hover behavior")
                    Button("Paste Appearance") {
                        _ = manager.pasteAppearance(to: [item.id])
                        onMenuUpdate?()
                    }
                    .disabled(!manager.canPasteAppearance(to: [item.id]))
                    if manager.selectedPhotoIDs.count > 1 {
                        Button("Paste Appearance to Selected Photos") {
                            _ = manager.pasteSelectedStyle()
                            onMenuUpdate?()
                        }
                        .disabled(!manager.canPasteSelectedAppearance)
                    }
                    Divider()
                    Button("Export .arras…") { exportWidget() }
                    Divider()
                    Button("Reveal in Finder") { revealInFinder() }
                    Divider()
                    Button("Remove", role: .destructive) {
                        if RemovalConfirmation.confirm(count: 1, name: manager.label(for: item), origin: .settings) {
                            manager.removePhoto(item.id)
                            onMenuUpdate?()
                        }
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
                .accessibilityHint("Copy or paste appearance, rename, replace, duplicate, export, reveal, or remove this photo")
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

    /// Keep frequent actions close; placement, playback and appearance detail are opt-in.
    private var expandedPanel: some View { photoExpandedPanel }

    private var photoExpandedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Appearance…") { showingFrameSheet = true }
                    .controlSize(.small)
                    .accessibilityIdentifier("photo-frame-inspector")
                    .accessibilityLabel("Edit frame")
                    .accessibilityHint("Shape, corners, shadow, mat, border and tilt")
                if !item.spaceImageFilenames.isEmpty {
                    Button("Edit Slideshow…") { onEditSlideshow?(item.id) }
                        .controlSize(.small)
                        .accessibilityIdentifier("edit-slideshow")
                }
                Spacer()
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

            if let collageParent {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Controlled by collage").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button("Edit Collage…") { manager.requestCollageEditor(collageParent.id) }
                            .controlSize(.small)
                            .accessibilityIdentifier("edit-member-collage-" + item.id.uuidString)
                    }
                    Text("\(collageParent.depth.displayName) · \(collageParent.isSpaceBound ? "This Space" : "All Spaces")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityLabel("Collage depth: \(collageParent.depth.displayName). \(collageParent.isSpaceBound ? "Pinned to this Space" : "All Spaces")")
                    Text("Depth and Space apply to the whole collage. This photo’s standalone settings return when detached.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("collage-shared-placement-" + item.id.uuidString)
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { showingMoreOptions.toggle() }
            } label: {
                Label(showingMoreOptions ? "Fewer options" : "More options",
                      systemImage: showingMoreOptions ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("photo-more-options-\(item.id.uuidString)")
            .accessibilityValue(showingMoreOptions ? "expanded" : "collapsed")

            if showingMoreOptions {
                SettingRow("Opacity", value: "\(Int(item.opacity * 100))%") {
                    Slider(value: Binding(
                        get: { item.opacity },
                        set: { manager.setOpacity(item.id, $0) }
                    ), in: 0.1...1.0)
                    .controlSize(.small)
                    .accessibilityLabel("Opacity")
                    .accessibilityValue("\(Int(item.opacity * 100)) percent")
                }

                SettingRow("Reveal") {
                    Toggle("On hover", isOn: Binding(
                        get: { item.revealOnHover },
                        set: { manager.setRevealOnHover(item.id, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(!effectiveDepth.isInteractive)
                    .help(effectiveDepth.isInteractive
                        ? "Hide this widget until the pointer moves over it."
                        : "Behind Icons cannot reveal on hover because macOS does not deliver pointer events at that depth.")
                    .accessibilityLabel("Reveal on hover")
                    .accessibilityHint(effectiveDepth.isInteractive
                        ? "Hides this photo until the pointer moves over it"
                        : "Unavailable Behind Icons because macOS does not deliver pointer events there")
                }

                if collageParent == nil {
                    SettingRow("Depth") {
                        Picker("", selection: Binding(
                            get: { effectiveDepth },
                            set: { manager.setDepth(item.id, $0); onMenuUpdate?() }
                        )) {
                            ForEach(WidgetDepth.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel("Stacking depth")
                        .accessibilityHint("Where this photo sits relative to desktop icons, the system's desktop widgets, and app windows")
                    }

                    if let caveat = effectiveDepth.caveat {
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
                }

                SettingRow("Double-click") {
                    Picker("", selection: Binding(
                        get: { item.clickAction },
                        set: { manager.setClickAction(item.id, $0); onMenuUpdate?() }
                    )) {
                        ForEach(WidgetClickAction.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Double-click action")
                    .accessibilityHint("Choose what this widget does when double-clicked")
                    .accessibilityIdentifier("photo-click-action")
                }

                if item.media.kind.isVideoKind {
                    separator.padding(.vertical, 2)
                    videoPlaybackControls
                }

                if !item.spaceImageFilenames.isEmpty || item.liveFolderSource != nil || item.photosLibrarySource != nil {
                    separator.padding(.vertical, 2)
                    smartCanvasControls
                }

            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo-expanded-settings-\(item.id.uuidString)")
    }

    @ViewBuilder
    private var videoPlaybackControls: some View {
        SettingRow("Playback", value: manager.mediaPlaybackStatus(for: item.id).displayName) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.media.kind.displayName)
                    .font(.system(size: 11))
                Text("Muted · loops while visible")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Pauses when covered, hidden, sleeping, or under system energy pressure.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.media.kind.displayName) playback")
            .accessibilityValue("\(manager.mediaPlaybackStatus(for: item.id).displayName), muted, loops while visible")
            Spacer()
        }
    }

    // MARK: Smart Canvas

    @ViewBuilder
    private var smartCanvasControls: some View {
        let count = manager.folderImageCount(item.id)

        if let source = item.liveFolderSource {
            HStack(spacing: 6) {
                Image(systemName: source.status.needsRelink ? "exclamationmark.triangle" : "folder.badge.gearshape")
                    .foregroundStyle(source.status.needsRelink ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live folder: \(source.displayName)")
                        .font(.system(size: 11))
                    Text(source.status.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(source.status.needsRelink ? Color.orange : Color(nsColor: .tertiaryLabelColor))
                }
                Spacer()
                Button(source.status.needsRelink ? "Relink Folder…" : "Refresh") {
                    if source.status.needsRelink {
                        relinkFolder()
                    } else {
                        Task { @MainActor in
                            _ = await manager.reconcileLiveFolder(item.id)
                            onMenuUpdate?()
                        }
                    }
                }
                .controlSize(.small)
                .accessibilityLabel(source.status.needsRelink ? "Relink live folder" : "Refresh live folder")
                .accessibilityHint(source.status.needsRelink
                                   ? "Choose the folder again to resume live updates"
                                   : "Scan the folder for additions, removals, and renames")
            }
            .padding(.leading, Metrics.label + 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("live-folder-status-\(item.id.uuidString)")
        }

        if let source = item.photosLibrarySource {
            HStack(spacing: 6) {
                Image(systemName: source.status.needsRelink ? "exclamationmark.triangle" : "photo.stack")
                    .foregroundStyle(source.status.needsRelink ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photos: \(source.displayName)")
                        .font(.system(size: 11))
                    Text(source.status.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(source.status.needsRelink ? Color.orange : Color(nsColor: .tertiaryLabelColor))
                    if let error = source.lastError, !error.isEmpty {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button(source.status.needsRelink ? "Choose Collection…" : "Refresh") {
                    if source.status.needsRelink {
                        PhotosLibraryCollectionPicker.present(
                            manager: manager,
                            existingWidgetID: item.id,
                            onMenuUpdate: onMenuUpdate
                        )
                    } else {
                        Task { @MainActor in
                            let result = await manager.refreshPhotosLibraryCollection(item.id)
                            onMenuUpdate?()
                            ImportBatchPresenter.present(result, title: "Photos Collection Refresh", noun: "asset")
                        }
                    }
                }
                .controlSize(.small)
                .accessibilityLabel(source.status.needsRelink ? "Choose Photos collection" : "Refresh Photos collection")
                .accessibilityHint(source.status.needsRelink
                                   ? "Choose an Album, Smart Album, or Shared Album to relink this saved snapshot"
                                   : "Download changes from the selected Photos collection")
            }
            .padding(.leading, Metrics.label + 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("photos-library-status-\(item.id.uuidString)")
        }

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

        SettingRow("Order") {
            Picker("", selection: Binding(
                get: { item.playbackOrder },
                set: { manager.setPlaybackOrder(item.id, $0); onMenuUpdate?() }
            )) {
                ForEach(SpacePlaybackOrder.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Slideshow playback order")
            .accessibilityHint("Controls which image appears next")
            .accessibilityIdentifier("space-playback-order")
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

        if item.allowsManualMediaEditing {
            HStack {
                Button("Add Photos…") { appendPhotos() }
                    .controlSize(.small)
                    .accessibilityHint("Adds more images to this slideshow")
                Spacer()
            }
        }
    }

    // MARK: Chrome

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(manager.selectedPhotoIDs.contains(item.id)
                  ? Color.accentColor.opacity(0.12)
                  : (isHovering ? Color.primary.opacity(0.035) : Color.clear))
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
        if let reason = manager.visibilityExplanation(for: item) { parts.append(reason) }
        if item.media.kind.isVideoKind {
            parts.append("\(item.media.kind.displayName) · muted · \(manager.mediaPlaybackStatus(for: item.id).displayName.lowercased())")
        }
        if let source = item.liveFolderSource {
            parts.append("Live Folder · \(source.status.displayName) · \(manager.folderImageCount(item.id)) images")
        } else if let source = item.photosLibrarySource {
            parts.append("Photos · \(source.status.displayName) · \(manager.folderImageCount(item.id)) assets")
        } else if !item.spaceImageFilenames.isEmpty {
            parts.append("Slideshow · \(manager.folderImageCount(item.id)) images")
        }
        if effectiveDepth != .onDesktop { parts.append(effectiveDepth.displayName.lowercased()) }
        if inheritedLock { parts.append("locked by collage") } else if item.isLocked { parts.append("locked") }
        if item.opacity < 1.0 { parts.append("\(Int(item.opacity * 100))%") }
        return parts.isEmpty ? "On desktop" : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var replaceTitle: String {
        if item.media.kind.isVideoKind { return "Replace Video…" }
        return item.spaceImageFilenames.isEmpty ? "Replace Image…" : "Replace Current Slideshow Image…"
    }

    private func selectFromRow() {
        var modifiers = WidgetSelectionModifiers(eventFlags: NSEvent.modifierFlags)
        modifiers.insert(.command)
        manager.selectPhoto(item.id, modifiers: modifiers)
    }

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
        Task { @MainActor in
            let result = await manager.replacePhoto(item.id, with: url)
            onMenuUpdate?()
            ImportBatchPresenter.present(result, title: "Replace Media")
        }
    }

    private func revealInFinder() {
        manager.revealStoredMedia(item.id)
    }

    private func exportWidget() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [BackupFormat.exportType]
        let label = manager.label(for: item)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(label).\(BackupFormat.currentExtension)"
        panel.prompt = "Export"
        panel.message = "Export this widget and all of its stored media as an Arras archive"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = try manager.exportWidget(item.id, to: url, archivalQuality: archivalQuality)
            LayoutArchiveExportFlow.present(report, title: "Widget Export Complete")
        } catch {
            LayoutArchiveExportFlow.present(error: error, title: "Couldn't Export Widget")
        }
    }

    private func appendPhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PhotoManager.importableTypes
        panel.prompt = "Add to Slideshow"
        panel.message = "Choose images to append to this slideshow"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { @MainActor in
                let result = await manager.appendPhotosToSpace(item.id, urls: urls)
                onMenuUpdate?()
                ImportBatchPresenter.present(result, title: "Slideshow Import")
            }
        }
    }

    private func relinkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink Folder"
        panel.message = "Choose the folder to use for this live Space."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task { @MainActor in
            let result = await manager.relinkLiveFolder(item.id, to: folderURL)
            onMenuUpdate?()
            ImportBatchPresenter.present(result, title: "Folder Space Relink")
        }
    }
}
