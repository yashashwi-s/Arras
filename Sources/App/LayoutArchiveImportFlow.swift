import AppKit

/// Accessible checklist used after archive preflight. Each row names the widget type, preserves
/// the user's label, and reports the number of staged media files before any merge/replace choice
/// can mutate the current layout.
private final class ArchiveImportSelectionView: NSView {
    private let candidates: [LayoutImportCandidate]
    private var checkboxes: [Int: NSButton] = [:]
    private(set) var selectedIDs: Set<Int>

    init(candidates: [LayoutImportCandidate]) {
        self.candidates = candidates
        self.selectedIDs = Set(candidates.map(\.id))

        let rowHeight: CGFloat = 28
        let contentHeight = max(rowHeight, CGFloat(candidates.count) * rowHeight)
        let viewportHeight = min(contentHeight, 280)
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: viewportHeight + 34))

        let selectAllButton = NSButton(
            title: "Select All",
            target: self,
            action: #selector(selectAllCandidates(_:))
        )
        selectAllButton.bezelStyle = NSButton.BezelStyle.rounded
        selectAllButton.controlSize = NSControl.ControlSize.small
        selectAllButton.identifier = NSUserInterfaceItemIdentifier("arras-import-select-all")
        selectAllButton.setAccessibilityLabel("Select all widgets")
        selectAllButton.setAccessibilityHelp("Includes every validated widget in this archive")

        let selectNoneButton = NSButton(
            title: "Select None",
            target: self,
            action: #selector(selectNoCandidates(_:))
        )
        selectNoneButton.bezelStyle = NSButton.BezelStyle.rounded
        selectNoneButton.controlSize = NSControl.ControlSize.small
        selectNoneButton.identifier = NSUserInterfaceItemIdentifier("arras-import-select-none")
        selectNoneButton.setAccessibilityLabel("Select no widgets")
        selectNoneButton.setAccessibilityHelp("Clears the widget selection")

        let controls = NSStackView(views: [selectAllButton, selectNoneButton])
        controls.orientation = NSUserInterfaceLayoutOrientation.horizontal
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        let stack = NSStackView()
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.frame = NSRect(x: 0, y: 0, width: 520, height: contentHeight)
        stack.autoresizingMask = [.width]

        for candidate in candidates {
            let mediaWord = candidate.mediaCount == 1 ? "media file" : "media files"
            let checkbox = NSButton(
                checkboxWithTitle: "\(candidate.typeName) — \(candidate.displayName) · \(candidate.mediaCount) \(mediaWord)",
                target: self,
                action: #selector(toggleSelection(_:))
            )
            checkbox.state = .on
            checkbox.tag = candidate.id
            checkbox.font = .systemFont(ofSize: 12)
            checkbox.cell?.lineBreakMode = .byTruncatingTail
            checkbox.setContentHuggingPriority(.defaultLow, for: .horizontal)
            checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            checkbox.identifier = NSUserInterfaceItemIdentifier("arras-import-widget-\(candidate.id)")
            checkbox.setAccessibilityLabel(
                "\(candidate.typeName), \(candidate.displayName), \(candidate.mediaCount) \(mediaWord)"
            )
            checkbox.setAccessibilityValue("Selected")
            checkbox.setAccessibilityHelp("Toggles whether this widget is imported")
            checkboxes[candidate.id] = checkbox
            stack.addArrangedSubview(checkbox)
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: viewportHeight))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = contentHeight > viewportHeight
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = stack
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func toggleSelection(_ sender: NSButton) {
        if sender.state == .on {
            selectedIDs.insert(sender.tag)
            sender.setAccessibilityValue("Selected")
        } else {
            selectedIDs.remove(sender.tag)
            sender.setAccessibilityValue("Not selected")
        }
    }

    @objc private func selectAllCandidates(_ sender: Any?) {
        selectedIDs = Set(candidates.map(\.id))
        for checkbox in checkboxes.values {
            checkbox.state = .on
            checkbox.setAccessibilityValue("Selected")
        }
    }

    @objc private func selectNoCandidates(_ sender: Any?) {
        selectedIDs.removeAll()
        for checkbox in checkboxes.values {
            checkbox.state = .off
            checkbox.setAccessibilityValue("Not selected")
        }
    }
}

/// Shared confirmation and error UI for explicit backup imports and Finder-open archives.
///
/// The app remains a menu bar agent: this is a small controller around PhotoManager's validated
/// archive API, not an NSDocument subclass or a document window lifecycle.
@MainActor
enum LayoutArchiveImportFlow {
    static func chooseBackup(manager: PhotoManager, onMenuUpdate: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BackupFormat.importTypes
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        present(url: url, manager: manager, onMenuUpdate: onMenuUpdate)
    }

    static func present(
        url: URL,
        manager: PhotoManager,
        applySettings: Bool = false,
        onMenuUpdate: (() -> Void)? = nil,
        onPreferencesApplied: (() -> Void)? = nil
    ) {
        // Finder can open several archives at once. Retain the original sequential
        // confirmation flow while each archive's file processing runs in a worker.
        pending.append {
            await presentPrepared(url: url, manager: manager, applySettings: applySettings,
                                  onMenuUpdate: onMenuUpdate, onPreferencesApplied: onPreferencesApplied)
        }
        guard presenter == nil else { return }
        presenter = Task {
            while !pending.isEmpty { await pending.removeFirst()() }
            presenter = nil
        }
    }

    private static func presentPrepared(url: URL, manager: PhotoManager, applySettings: Bool,
                                        onMenuUpdate: (() -> Void)?, onPreferencesApplied: (() -> Void)?) async {
        manager.beginMediaImport()
        defer { manager.endMediaImport() }
        let preflight: LayoutImportPreflight
        do {
            preflight = try await manager.preflightImportLayoutInBackground(from: url)
        } catch {
            presentAlert(
                title: "Couldn't Import Backup",
                message: error.localizedDescription,
                style: .warning
            )
            return
        }

        guard preflight.hasCandidates else {
            preflight.cleanup()
            let detail = preflight.skippedReasons.isEmpty
                ? "That backup didn't contain any widgets with valid images."
                : "That backup didn't contain any widgets with valid images.\n\n" + preflight.skippedReasons.joined(separator: "\n")
            presentAlert(title: "Nothing to Import", message: detail, style: .informational)
            return
        }

        let selection = ArchiveImportSelectionView(candidates: preflight.candidates)
        var selectionDetails = "Select the widgets to add to your desktop."
        if let metadata = preflight.manifest.exportMetadata {
            selectionDetails += "\n\n\(metadata.statement)"
        }
        if preflight.skippedCount > 0 {
            selectionDetails += "\n\n\(preflight.skippedCount) invalid widget\(preflight.skippedCount == 1 ? "" : "s") will be skipped."
        }
        let selectionAlert = AppDialog.make(title: "Choose Widgets to Import", message: selectionDetails,
                                            actions: [.init(title: "Continue"), .init(title: "Cancel", role: .cancel)])
        selectionAlert.accessoryView = selection
        NSApp.activate(ignoringOtherApps: true)
        guard selectionAlert.runModal() == .alertFirstButtonReturn else {
            preflight.cleanup()
            return
        }
        guard !selection.selectedIDs.isEmpty else {
            preflight.cleanup()
            presentAlert(
                title: "Nothing Selected",
                message: "Select at least one widget to continue.",
                style: .informational
            )
            return
        }

        let selectedCount = preflight.candidates.filter { selection.selectedIDs.contains($0.id) }.count
        let widgetWord = selectedCount == 1 ? "widget" : "widgets"
        let recovering = manager.libraryRecoveryRequired
        let message = recovering
            ? "Restore the selected widgets from this backup? Arras will preserve a copy of the damaged library before replacing it. Any currently loaded widgets will be replaced."
            : manager.photos.isEmpty
            ? "Add \(selectedCount) \(widgetWord) to your desktop?"
            : "Add \(selectedCount) \(widgetWord) to your current layout, or replace your existing widgets. Replacing cannot be undone."
        let canReplace = !recovering && !manager.photos.isEmpty
        var actions = [AppDialog.Action(title: recovering ? "Restore Backup" : "Add Widgets",
                                       role: recovering ? .destructive : .normal)]
        if canReplace { actions.append(.init(title: "Replace Everything", role: .destructive)) }
        actions.append(.init(title: "Cancel", role: .cancel))
        let confirmation = AppDialog.make(title: recovering ? "Restore Damaged Library?" : "Import Widgets?",
                                         message: message, actions: actions)
        NSApp.activate(ignoringOtherApps: true)

        let mode: PhotoManager.LayoutImportMode
        switch confirmation.runModal() {
        case .alertFirstButtonReturn: mode = recovering ? .recoverDamagedLibrary : .merge
        case .alertSecondButtonReturn where canReplace: mode = .replace
        default:
            preflight.cleanup()
            return
        }

        do {
            let count = try manager.commitImport(preflight, selectedIDs: selection.selectedIDs, mode: mode)
            if applySettings, let preferences = preflight.manifest.preferences {
                manager.applyImportedPreferences(preferences)
                onPreferencesApplied?()
            }
            onMenuUpdate?()
            var message = "Imported \(count) \(widgetWord)."
            if preflight.skippedCount > 0 {
                message += "\n\nSkipped \(preflight.skippedCount) invalid widget\(preflight.skippedCount == 1 ? "" : "s")."
            }
            if let metadata = preflight.manifest.exportMetadata {
                message += "\n\n\(metadata.statement)"
            }
            presentAlert(title: "Import Complete", message: message, style: .informational)
        } catch {
            preflight.cleanup()
            presentAlert(
                title: "Couldn't Import Backup",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    private static var pending: [@MainActor () async -> Void] = []
    private static var presenter: Task<Void, Never>?

    private static func presentAlert(title: String, message: String, style: NSAlert.Style) {
        AppDialog.inform(title: title, message: message, style: style)
    }
}

/// Shared success/error presentation for whole-layout and per-widget exports. The report's
/// provenance statement is shown verbatim so an archival-quality export never silently implies
/// that Arras recovered source originals it does not have.
@MainActor
enum LayoutArchiveExportFlow {
    static func present(_ report: ArchiveExportReport, title: String = "Export Complete") {
        AppDialog.inform(title: title, message: report.summary,
                         style: report.sourceStatus == .allSourceBytes ? .informational : .warning)
    }

    static func present(error: Error, title: String = "Couldn't Export") {
        AppDialog.inform(title: title, message: error.localizedDescription, style: .warning)
    }
}
