import SwiftUI
import AppKit

@MainActor
final class CollageEditorDraft: ObservableObject {
    @Published var settings: DesktopCollageSettings
    @Published var depth: WidgetDepth
    @Published var isSpaceBound: Bool
    private let openingSettings: DesktopCollageSettings
    private let openingDepth: WidgetDepth
    private let openingSpaceBound: Bool

    init(item: PhotoItem?) {
        let settings = item?.desktopCollage ?? DesktopCollageSettings()
        self.settings = settings; openingSettings = settings
        let depth = item?.depth ?? .onDesktop
        self.depth = depth; openingDepth = depth
        let spaceBound = item?.isSpaceBound ?? false
        isSpaceBound = spaceBound; openingSpaceBound = spaceBound
    }

    func hasChanges(compositionScale: CGFloat) -> Bool {
        func comparable(_ value: DesktopCollageSettings) -> DesktopCollageSettings {
            var value = value
            value.compositionScale = compositionScale
            value.normalize()
            if value.captionStyle.placement == .caption { value.freeCaptionBandHeight = nil }
            return value
        }
        return comparable(settings) != comparable(openingSettings) || depth != openingDepth || isSpaceBound != openingSpaceBound
    }
}

/// The controller and controls share one draft so native close actions see the
/// latest edits, including depth and Space preferences staged outside the preview.
@MainActor
final class CollageEditorWindowController: NSWindowController, NSWindowDelegate {
    let collageID: UUID
    let editorDraft: CollageEditorDraft
    private weak var manager: PhotoManager?
    private var onClose: (() -> Void)?
    private let previewSession = UUID()
    private var previewObserver: NSObjectProtocol?
    private var afterClose: (() -> Void)?
    private var closing = false
    private var didClose = false
    private var waitingForSheet = false
    private(set) var activeAlert: NSAlert?
    typealias AlertPresenter = (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    var presentAlert: AlertPresenter = { alert, window, completion in alert.beginSheetModal(for: window, completionHandler: completion) }

    var hasUnsavedChanges: Bool {
        guard let item = manager?.photos.first(where: { $0.id == collageID }), let settings = item.desktopCollage else { return false }
        return editorDraft.hasChanges(compositionScale: settings.compositionScale)
    }

    init(manager: PhotoManager, id: UUID, onClose: @escaping () -> Void) {
        collageID = id
        editorDraft = CollageEditorDraft(item: manager.photos.first { $0.id == id })
        self.manager = manager
        self.onClose = onClose
        let height = min(640, max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 140))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Edit Collage"
        window.identifier = NSUserInterfaceItemIdentifier("collage-editor-" + id.uuidString)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        manager.beginCollageAppearancePreview(id, session: previewSession)
        previewObserver = NotificationCenter.default.addObserver(forName: .collageAppearancePreviewInvalidated, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? UUID == self.previewSession else { return }
                self.afterClose = nil
                self.closeWithoutPrompt()
            }
        }
        window.contentView = NSHostingView(rootView: CollageSettingsView(manager: manager, id: id, previewSession: previewSession,
            editorDraft: editorDraft, onClose: { [weak self] in self?.requestClose() }, onApply: { [weak self] in self?.applyAndClose() }))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func close() { requestClose() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if activeAlert != nil || sender.attachedSheet != nil { requestClose(); return false }
        sender.makeFirstResponder(nil)
        guard hasUnsavedChanges else { return true }
        requestClose()
        return false
    }

    func requestClose(onClosed: (() -> Void)? = nil) {
        guard !closing, !didClose, let window else { return }
        if let onClosed { afterClose = onClosed }
        guard activeAlert == nil else { return }
        // A label wizard may cancel its placement edits as it closes. Decide
        // whether to ask only after that sheet has finished updating the draft.
        if window.attachedSheet != nil { waitingForSheet = true; return }
        window.makeFirstResponder(nil)
        guard hasUnsavedChanges else { closeWithoutPrompt(); return }
        let alert = AppDialog.make(
            title: "Apply Changes to This Collage?",
            message: "Your edits haven’t been saved. Apply them, discard them, or keep editing.",
            actions: [.init(title: "Apply"), .init(title: "Discard Changes", role: .destructive), .init(title: "Keep Editing", role: .cancel)]
        )
        activeAlert = alert
        presentAlert(alert, window) { [weak self, weak alert] response in
            guard let self, !self.closing, !self.didClose, self.activeAlert === alert else { return }
            self.activeAlert = nil
            switch response {
            case .alertFirstButtonReturn: self.applyAndClose()
            case .alertSecondButtonReturn: self.closeWithoutPrompt()
            default: self.afterClose = nil
            }
        }
    }

    func applyAndClose() {
        guard !closing, !didClose, activeAlert == nil, let manager, let window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(nil)
        guard manager.applyCollageSettings(collageID, settings: editorDraft.settings,
                                          depth: editorDraft.depth, isSpaceBound: editorDraft.isSpaceBound) else {
            let alert = AppDialog.make(title: "Couldn’t Save Collage",
                                      message: "Your saved collage is unchanged. Your edits are still here; try Apply again or discard them.",
                                      style: .warning, actions: [.init(title: "Keep Editing")])
            activeAlert = alert
            presentAlert(alert, window) { [weak self, weak alert] _ in
                guard let self, self.activeAlert === alert else { return }
                self.activeAlert = nil
                self.afterClose = nil
            }
            return
        }
        closeWithoutPrompt()
    }

    private func closeWithoutPrompt() {
        guard !closing, !didClose else { return }
        closing = true
        waitingForSheet = false
        if let alert = activeAlert {
            activeAlert = nil
            if alert.window.sheetParent === window { window?.endSheet(alert.window, returnCode: .abort) }
        }
        super.close()
    }

    func windowDidEndSheet(_ notification: Notification) {
        guard waitingForSheet else { return }
        waitingForSheet = false
        DispatchQueue.main.async { [weak self] in self?.requestClose() }
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        window?.makeFirstResponder(nil)
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver); self.previewObserver = nil }
        manager?.endCollageAppearancePreview(collageID, session: previewSession)
        if manager?.collageEditorID == collageID { manager?.collageEditorID = nil }
        // This controller is single-use. AppKit can retain its closed window;
        // release the hosted graph and observed manager before notifying the owner.
        window?.contentView = nil
        let callback = onClose
        onClose = nil
        callback?()
        let next = afterClose
        afterClose = nil
        next?()
    }
}

struct CollageSettingsView: View {
    @ObservedObject var manager: PhotoManager
    let id: UUID
    let previewSession: UUID
    var onClose: () -> Void
    @ObservedObject var editorDraft: CollageEditorDraft
    var onApply: () -> Void
    @State private var selectedLabel = CollageTextLabel.captionID
    @State private var sheet: LabelSheet?
    private enum LabelSheet: String, Identifiable { case arrange, fonts; var id: String { rawValue } }

    init(manager: PhotoManager, id: UUID, previewSession: UUID, editorDraft: CollageEditorDraft, onClose: @escaping () -> Void, onApply: @escaping () -> Void) {
        self.manager = manager; self.id = id; self.previewSession = previewSession
        self.editorDraft = editorDraft; self.onClose = onClose; self.onApply = onApply
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your collage").font(.system(size: 20, weight: .semibold))
                    Text("Drag the background to move your collage. Drag a photo to rearrange it or pull it out. Use the corner handles to resize.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Label("Changes preview on your desktop", systemImage: "eye")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text("Choose a look").font(.system(size: 12, weight: .semibold))
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(CollagePreset.allCases) { preset in
                            lookButton(preset)
                        }
                    }
                    control("Photo gap", value: $editorDraft.settings.gap, range: 0...100)
                    control("Outer margin", value: $editorDraft.settings.padding, range: 12...80)
                    if editorDraft.settings.skin == .transparent {
                        Text("No backdrop or shadow. Your photos stay grouped; drag an empty area to move them together.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    CollageDetails("Advanced collage settings", identifier: "collage-advanced-toggle") {
                        if editorDraft.settings.skin == .glass {
                            Picker("Glass appearance", selection: $editorDraft.settings.glassStyle) {
                                ForEach(CollageGlassStyle.allCases) { style in Text(style.title).tag(style) }
                            }.pickerStyle(.segmented).accessibilityIdentifier("collage-glass-appearance")
                            HStack {
                                Toggle("Custom tint", isOn: $editorDraft.settings.usesCustomTint)
                                    .accessibilityIdentifier("collage-custom-tint")
                                Spacer()
                                Button("Use System Glass") {
                                    editorDraft.settings.glassStyle = .system
                                    editorDraft.settings.usesCustomTint = false
                                    editorDraft.settings.tintStrength = 0.16
                                }.controlSize(.small)
                            }
                        }
                        control("Outer border", value: $editorDraft.settings.borderWidth, range: 0...12)
                            .help("A border around the whole collage. Set to zero for no border.")
                        if editorDraft.settings.borderWidth > 0 {
                            ColorPicker("Border color", selection: colorBinding($editorDraft.settings.borderColorHex), supportsOpacity: false)
                                .accessibilityIdentifier("collage-border-color")
                        }
                        if editorDraft.settings.skin != .transparent || editorDraft.settings.borderWidth > 0 {
                            control("Roundness", value: $editorDraft.settings.cornerRadius, range: 0...60)
                        }
                        if editorDraft.settings.skin != .transparent && (editorDraft.settings.skin != .glass || editorDraft.settings.usesCustomTint) {
                            ColorPicker("Tint", selection: Binding(get: { Color(nsColor: NSColor.fromHex(editorDraft.settings.tintHex) ?? .white) }, set: { color in
                                if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                                    editorDraft.settings.tintHex = String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                                }
                            }), supportsOpacity: false)
                            if editorDraft.settings.skin == .glass {
                                HStack {
                                    Text("Tint strength").frame(width: 100, alignment: .leading)
                                    Slider(value: $editorDraft.settings.tintStrength, in: 0...1).accessibilityLabel("Tint strength")
                                    Text("\(Int(editorDraft.settings.tintStrength * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                                }.font(.system(size: 12))
                            }
                        }
                        Divider()
                        Text("Placement for the whole collage")
                            .font(.system(size: 12, weight: .semibold))
                        Picker("Depth", selection: $editorDraft.depth) {
                            ForEach(WidgetDepth.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }.accessibilityIdentifier("collage-group-depth")
                        if let caveat = editorDraft.depth.caveat {
                            Text(caveat).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("Pin the whole collage to this desktop Space", isOn: $editorDraft.isSpaceBound)
                            .accessibilityIdentifier("collage-group-space")
                        Text("Photos keep their own depth and Space settings for when they leave the collage.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    CollageLabelControls(settings: $editorDraft.settings, selection: $selectedLabel,
                                         arrange: { sheet = .arrange }, chooseFont: { sheet = .fonts })
                    Text("Apply saves your edits. Closing asks before discarding unsaved changes.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(22)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancel-collage-settings")
                Button("Apply", action: onApply).keyboardShortcut(.defaultAction).accessibilityIdentifier("apply-collage-settings")
            }.padding(18)
        }
        .frame(width: 500, height: min(640, max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 140)))
        .onAppear { manager.previewCollageAppearance(id, session: previewSession, settings: editorDraft.settings) }
        .onChange(of: editorDraft.settings) { _, settings in manager.previewCollageAppearance(id, session: previewSession, settings: settings) }
        .onChange(of: manager.photos.map(\.id)) { _, ids in if !ids.contains(id) { onClose() } }
        .onChange(of: manager.photos.first(where: { $0.id == id })?.desktopCollage?.compositionScale) { _, scale in
            if let scale { editorDraft.settings.compositionScale = scale }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .arrange:
                CollageLabelWizard(manager: manager, id: id, settings: $editorDraft.settings, selection: $selectedLabel, onClose: { sheet = nil })
            case .fonts:
                CollageFontPicker(storage: manager.storageDir, retainedFontFiles: {
                    Set(manager.photos.flatMap { $0.desktopCollage?.fontFileNames ?? [] })
                        .union(manager.collageAppearanceDrafts.values.flatMap { $0.settings.fontFileNames })
                        .union(editorDraft.settings.fontFileNames)
                }, selectedStyle: editorDraft.settings.labelStyle(for: selectedLabel), onChoose: { name, file in
                    var style = editorDraft.settings.labelStyle(for: selectedLabel)
                    style.font = .custom; style.fontName = name; style.fontFileName = file
                    style.weight = .original
                    style.italic = NSFont(name: name, size: style.fontSize).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
                    editorDraft.settings.setLabelStyle(style, for: selectedLabel)
                    sheet = nil
                }, onClose: { sheet = nil })
            }
        }
    }

    private func lookButton(_ preset: CollagePreset) -> some View {
        var candidate = editorDraft.settings
        candidate.applyPreset(preset)
        let selected = candidate == editorDraft.settings
        let fill = candidate.skin == .transparent ? Color.clear
            : candidate.skin == .glass ? Color.white.opacity(0.4)
            : Color(nsColor: NSColor.fromHex(candidate.tintHex) ?? .white)
        return Button { editorDraft.settings.applyPreset(preset) } label: {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.29, green: 0.36, blue: 0.39))
                    RoundedRectangle(cornerRadius: candidate.cornerRadius / 4)
                        .fill(fill).padding(5)
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.75, green: 0.48, blue: 0.35))
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.80, green: 0.74, blue: 0.61))
                            RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.43, green: 0.54, blue: 0.52))
                        }
                    }.padding(12)
                }.frame(height: 52).accessibilityHidden(true)
                Text(preset.title).font(.system(size: 10, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.center).frame(height: 26, alignment: .top)
            }
            .padding(5).frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Preview this look on your desktop. Apply saves it; Cancel restores your previous look.")
        .accessibilityIdentifier("collage-preset-" + preset.rawValue)
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor.fromHex(hex.wrappedValue) ?? .white) }, set: { color in
            if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                hex.wrappedValue = String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
            }
        })
    }

    private func control(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range, step: 1).accessibilityLabel(label)
            Text("\(Int(value.wrappedValue * editorDraft.settings.compositionScale)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
        }.font(.system(size: 12))
    }
}

/// Keep detailed controls on the same grid, with the whole row reachable by
/// pointer or keyboard. Expanding details is view state, never an unsaved edit.
struct CollageDetails<Content: View>: View {
    let title: String
    let identifier: String
    let content: Content
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.identifier = identifier; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer()
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title)
                .accessibilityValue(expanded ? "expanded" : "collapsed")
                .accessibilityIdentifier(identifier)
            if expanded { content }
        }
    }
}

struct DesktopCollageRow: View {
    let item: PhotoItem
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?
    var onEditSlideshow: ((UUID) -> Void)?
    var searchText = ""
    var listFilter: WidgetListFilter = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded || !searchText.isEmpty || listFilter != .all {
                let members = manager.collageMembers(item.id).filter {
                    manager.matchesWidgetList(item, query: searchText, filter: listFilter)
                        || manager.matchesWidgetList($0, query: searchText, filter: listFilter)
                }
                if members.isEmpty {
                    Text("Drag a desktop widget onto this collage to add it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 32).padding(.bottom, 12)
                } else {
                    VStack(spacing: 4) {
                        ForEach(members) { member in
                            VStack(alignment: .leading, spacing: 0) {
                                PhotoRowView(item: member, displayTitle: memberTitle(member), manager: manager, onMenuUpdate: onMenuUpdate, onEditSlideshow: onEditSlideshow)

                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("collage-member-" + member.id.uuidString)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
        .settingsSectionSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("collage-group-" + item.id.uuidString)
        .alert("Remove Collage?", isPresented: $confirmingRemoval) {
            Button("Remove Collage, Keep Photos", role: .destructive) { manager.removePhoto(item.id); onMenuUpdate?() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its photos will stay on your desktop. The collage’s appearance and labels will be removed.") }
    }

    private func memberTitle(_ member: PhotoItem) -> String {
        let name = manager.label(for: member)
        let prefix = (item.customName ?? "Collage") + " · "
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0)).foregroundStyle(.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                        let photos = Array(manager.collageMembers(item.id).prefix(3))
                        if photos.isEmpty {
                            Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 2) {
                                ForEach(photos) { photo in
                                    if let thumbnail = manager.thumbnail(for: photo, size: 80) {
                                        Image(nsImage: thumbnail).resizable().scaledToFill()
                                            .frame(width: 14, height: 34).clipped()
                                    }
                                }
                            }.clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }.frame(width: 48, height: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.customName ?? "Collage").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        let count = manager.collageMembers(item.id).count
                        Text("\(item.desktopCollage?.skin.title ?? "") · \(count == 0 ? "Drop a widget here" : "\(count) photos")")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(item.customName ?? "Collage")")
            Spacer()
            Button { manager.requestCollageEditor(item.id) } label: { Image(systemName: "slider.horizontal.3") }
                .help("Edit collage appearance, depth, Space and labels").accessibilityLabel("Edit collage")
                .accessibilityIdentifier("edit-collage-" + item.id.uuidString)
            Button { manager.toggleVisibility(item.id) } label: { Image(systemName: item.isVisible ? "eye" : "eye.slash") }
                .accessibilityLabel(item.isVisible ? "Hide collage" : "Show collage")
            Button { manager.toggleLock(item.id) } label: { Image(systemName: item.isLocked ? "lock.fill" : "lock.open") }
                .accessibilityLabel(item.isLocked ? "Unlock collage" : "Lock collage")
            Menu {
                Button("Edit Collage…") { manager.requestCollageEditor(item.id) }
                Divider()
                Button("Remove Collage, Keep Photos", role: .destructive) { confirmingRemoval = true }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Collage actions")
        }
        .buttonStyle(.borderless).controlSize(.small).padding(10)
    }
}

@MainActor
final class CollagePreviewView: NSView {
    private weak var manager: PhotoManager?
    private var id = UUID()
    private var settings = DesktopCollageSettings()
    private let board = NSView()
    private let labelsView = CollageTextView(frame: .zero)
    private let selectionOutline = CAShapeLayer()
    private let guides = CAShapeLayer()
    var onSelectLabel: ((UUID) -> Void)?
    var onMoveLabel: ((UUID, CGPoint) -> Void)?
    var onRestoreLabel: ((UUID, CollageLabelStyle) -> Void)?
    private var selectedLabel: UUID?
    private var dragLabel: UUID?
    private var dragPointer = CGPoint.zero
    private var dragCenter = CGPoint.zero
    private var dragBody = CGRect.zero
    private var dragStyle: CollageLabelStyle?
    private(set) var labelLayouts: [CollageLabelLayout] = []
    private var projectedBody = CGRect.zero
    private let picturesHost = NSView()
    private var pictures: [UUID: (snapshot: Data, view: DraggablePhotoView)] = [:]
    var previewPhotos: [DraggablePhotoView] { picturesHost.subviews.compactMap { $0 as? DraggablePhotoView } }
    private var renderPending = false
    private var renderedBounds: CGRect?
    private var configurationSignature: Data?
    private(set) var renderGeneration = 0
    private let snapshotEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        board.wantsLayer = true
        board.layer?.borderWidth = 1
        board.layer?.borderColor = NSColor.separatorColor.cgColor
        board.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(board)
        addSubview(picturesHost)
        addSubview(labelsView)
        selectionOutline.fillColor = nil
        selectionOutline.strokeColor = NSColor.controlAccentColor.cgColor
        selectionOutline.lineWidth = 1
        selectionOutline.lineDashPattern = [4, 3]
        layer?.addSublayer(selectionOutline)
        guides.fillColor = nil
        guides.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
        guides.lineWidth = 1
        layer?.addSublayer(guides)
        picturesHost.autoresizesSubviews = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { onMoveLabel == nil ? nil : (bounds.contains(convert(point, from: superview)) ? self : nil) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { onMoveLabel != nil }
    override func layout() {
        super.layout()
        // AppKit can call this while SwiftUI is updating constraints. Changing
        // the view hierarchy, material, or labels here recursively invalidates
        // those constraints and crashed the editor. Queue one render only when
        // the bounds change; mutations from that render cannot start a loop.
        if renderedBounds != bounds { scheduleRender() }
    }

    func configure(manager: PhotoManager, id: UUID, settings: DesktopCollageSettings, selectedLabel: UUID? = nil) {
        let items = manager.photos.filter { $0.id == id || $0.collageParentID == id }.map { item in
            var snapshot = item
            snapshot.frameString = NSStringFromRect(manager.collageFrame(item))
            return snapshot
        }
        let signature = try? snapshotEncoder.encode(items)
        guard self.manager !== manager || self.id != id || self.settings != settings || configurationSignature != signature || self.selectedLabel != selectedLabel else { return }
        self.manager = manager
        self.id = id
        self.settings = settings
        self.selectedLabel = selectedLabel
        configurationSignature = signature
        scheduleRender()
    }

    private func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderPending = false
            self.renderScene()
        }
    }

    private func renderScene() {
        renderGeneration += 1
        renderedBounds = bounds
        guard let manager, let parent = manager.photos.first(where: { $0.id == id }) else { return }
        let children = manager.collageLayoutMembers(id)
        let layout = manager.collageAppearanceLayout(id, settings: settings)
        let scene = layout?.bounds ?? CollageGeometry.enclosing(children.map(manager.collageFootprint), fallback: manager.collageFrame(parent), settings: settings)
        guard scene.width > 0, scene.height > 0, bounds.width > 32, bounds.height > 28 else { return }
        let scale = min((bounds.width - 32) / scene.width, (bounds.height - 28) / scene.height)
        let origin = CGPoint(x: bounds.midX - scene.width * scale / 2, y: bounds.midY - scene.height * scale / 2)
        let projected = CGRect(origin: origin, size: CGSize(width: scene.width * scale, height: scene.height * scale))
        projectedBody = projected
        board.frame = projected
        board.layer?.backgroundColor = (settings.skin == .glass ? NSColor.windowBackgroundColor : (NSColor.fromHex(settings.tintHex) ?? .white)).cgColor
        board.layer?.cornerRadius = settings.effectiveCornerRadius * scale
        labelsView.frame = bounds
        labelsView.showsContrastBacking = onMoveLabel != nil
        labelsView.selectedLabel = onMoveLabel != nil ? selectedLabel : nil
        labelLayouts = CollageLabelLayout.layouts(settings: layout?.settings ?? settings, in: projected, previewScale: scale)
        labelsView.layouts = labelLayouts
        selectionOutline.path = nil
        if let selected = labelLayouts.first(where: { $0.label.id == selectedLabel }) {
            var transform = CGAffineTransform(translationX: selected.rect.midX, y: selected.rect.midY).rotated(by: selected.rotation)
            selectionOutline.path = CGPath(rect: CGRect(x: -selected.rect.width / 2 - 3, y: -selected.rect.height / 2 - 3,
                                                       width: selected.rect.width + 6, height: selected.rect.height + 6), transform: &transform)
        }
        // The placement canvas shows arrangement. The actual desktop collage owns
        // material preview, avoiding false blur/refraction at miniature scale.
        picturesHost.frame = projected
        picturesHost.bounds = scene
        let ids = Set(children.map(\.id))
        for id in Array(pictures.keys) where !ids.contains(id) {
            pictures.removeValue(forKey: id)?.view.removeFromSuperview()
        }
        for child in children {
            let rect = layout?.frames[child.id] ?? manager.collageFrame(child)
            var snapshot = child
            snapshot.frameString = NSStringFromRect(rect)
            guard let encoded = try? snapshotEncoder.encode(snapshot) else { continue }
            if pictures[child.id]?.snapshot == encoded { continue }
            guard let image = manager.thumbnail(for: child, size: 300) else { continue }
            let inset = PhotoCanvas.inset(photoSize: rect.size, shadowEnabled: child.shadowEnabled, shadowBlur: child.shadowBlur, matWidth: child.matWidth, tiltDegrees: CGFloat(child.tiltDegrees))
            let canvas = rect.insetBy(dx: -inset, dy: -inset)
            let view = DraggablePhotoView(frame: canvas, content: .still(image), locked: true, canvasInset: inset, settings: child)
            view.updateLayout(view.frame.size)
            // updateLayout resets the origin for desktop window content views.
            view.setFrameOrigin(canvas.origin)
            pictures.removeValue(forKey: child.id)?.view.removeFromSuperview()
            picturesHost.addSubview(view)
            pictures[child.id] = (encoded, view)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard onMoveLabel != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = labelLayouts.reversed().first(where: { $0.contains(point) }) else { return }
        dragLabel = hit.label.id
        dragPointer = point
        dragCenter = CGPoint(x: hit.rect.midX, y: hit.rect.midY)
        dragBody = projectedBody
        dragStyle = hit.label.style
        window?.makeFirstResponder(self)
        onSelectLabel?(hit.label.id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let label = dragLabel, dragBody.width > 0, dragBody.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        var center = CGPoint(x: dragCenter.x + point.x - dragPointer.x, y: dragCenter.y + point.y - dragPointer.y)
        let path = CGMutablePath()
        if !event.modifierFlags.contains(.option) {
            if abs(center.x - dragBody.midX) < 5 {
                center.x = dragBody.midX; path.move(to: CGPoint(x: center.x, y: dragBody.minY)); path.addLine(to: CGPoint(x: center.x, y: dragBody.maxY))
            }
            if abs(center.y - dragBody.midY) < 5 {
                center.y = dragBody.midY; path.move(to: CGPoint(x: dragBody.minX, y: center.y)); path.addLine(to: CGPoint(x: dragBody.maxX, y: center.y))
            }
        }
        guides.path = path
        let normalized = CGPoint(x: min(1, max(0, (center.x - dragBody.minX) / dragBody.width)),
                                 y: min(1, max(0, (center.y - dragBody.minY) / dragBody.height)))
        onMoveLabel?(label, normalized)
    }

    override func mouseUp(with event: NSEvent) { dragLabel = nil; dragStyle = nil; guides.path = nil }
    override func cancelOperation(_ sender: Any?) {
        if let label = dragLabel, let style = dragStyle { onRestoreLabel?(label, style) }
        dragLabel = nil; dragStyle = nil; guides.path = nil
    }
}
