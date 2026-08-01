import SwiftUI
import UniformTypeIdentifiers

/// App-wide settings.
///
/// These used to be crammed into the photo list's footer, which made a per-photo
/// screen also the home for global switches. Splitting them out is what lets the
/// footer go back to being a footer.
struct PreferencesView: View {
    @ObservedObject var manager: PhotoManager
    var onMenuUpdate: (() -> Void)?

    @ObservedObject private var hotKeys = HotKeyManager.shared
    @ObservedObject private var menuBar = MenuBarCustomization.shared
    @ObservedObject private var updater = Updater.shared

    @State private var snapEnabled = SnapEngine.shared.isEnabled
    @State private var snapOtherApps = SnapEngine.shared.includesOtherApps

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                general
                shortcut
                menuBarSection
                updates
                backup
            }
            .padding(16)
        }
    }

    // MARK: - General

    private var general: some View {
        section("GENERAL") {
            Toggle("Launch at Login", isOn: Binding(
                get: { manager.launchAtLogin },
                set: { manager.setLaunchAtLogin($0); onMenuUpdate?() }
            ))
            .accessibilityHint("Starts \(Constants.appName) automatically when you log in")

            Toggle("Snap to Edges", isOn: $snapEnabled)
                .onChange(of: snapEnabled) { _, value in SnapEngine.shared.isEnabled = value }
                .accessibilityHint("Aligns photos to screen edges and other photos while you drag")

            Toggle("Also snap to other apps' windows", isOn: $snapOtherApps)
                .onChange(of: snapOtherApps) { _, value in SnapEngine.shared.includesOtherApps = value }
                .disabled(!snapEnabled)
                .accessibilityHint("Aligns photos to other applications' windows and to the system's desktop widgets")
            caption("Reads window positions only. No permissions are needed and no window contents are read.")
        }
    }

    // MARK: - Shortcut

    private var shortcut: some View {
        section("GLOBAL SHORTCUT") {
            HStack(spacing: 8) {
                Toggle("Show / hide all photos", isOn: Binding(
                    get: { hotKeys.isEnabled },
                    set: { hotKeys.isEnabled = $0; onMenuUpdate?() }
                ))

                ShortcutRecorder(
                    shortcut: Binding(
                        get: { hotKeys.shortcut },
                        set: { hotKeys.shortcut = $0; onMenuUpdate?() }
                    ),
                    isEnabled: hotKeys.isEnabled
                )

                if hotKeys.isEnabled && !hotKeys.isRegistered {
                    Label("In use by another app", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
            }
        }
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        section("MENU BAR") {
            caption("Choose what appears in the menu bar. Add Photo, Settings and Quit are always there.")

            ForEach(MenuBarCustomization.Item.allCases) { item in
                Toggle(isOn: Binding(
                    get: { menuBar.isVisible(item) },
                    set: { menuBar.setVisible(item, $0); onMenuUpdate?() }
                )) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title)
                        Text(item.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Updates

    private var updates: some View {
        section("UPDATES") {
            HStack(spacing: 8) {
                Picker("Check for updates", selection: Binding(
                    get: { updater.checkFrequency },
                    set: { updater.checkFrequency = $0 }
                )) {
                    ForEach(Updater.CheckFrequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Button("Check Now") {
                    Task { await updater.check(userInitiated: true) }
                }
                .controlSize(.small)

                Spacer()
            }

            caption(lastCheckedDescription)
        }
    }

    // MARK: - Backup & transfer

    /// One command, one file format, one place.
    ///
    /// There used to be two mechanisms: "Export Layout…", hidden behind an unlabelled glyph in
    /// the Photos tab, which carried the widgets and had the only "include app settings"
    /// checkbox; and "Export Settings…" here, which was named for settings, offered no options
    /// at all, and silently wrote five of them. People looking for the checkbox looked at the
    /// button that says Settings and did not find it.
    private var backup: some View {
        section("BACKUP & TRANSFER") {
            caption("Save your widgets and settings to a single file, or restore them on another Mac.")

            HStack(spacing: 8) {
                Button("Export Backup…") { exportBackup() }
                    .controlSize(.small)
                Button("Import Backup…") { importBackup() }
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tableau") ?? .data]
        panel.nameFieldStringValue = "Tableau Backup.tableau"
        panel.prompt = "Export"
        panel.message = "Choose what this backup should contain"
        let options = ExportOptionsView()
        panel.accessoryView = options

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try manager.exportLayout(to: url, preferenceGroups: options.selectedGroups)
        } catch {
            presentAlert("Couldn't Export Backup", error.localizedDescription, .warning)
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tableau") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a Tableau backup"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Read the manifest first so the dialog can describe what is actually inside, rather
        // than asking the user to commit to an opaque file.
        let manifest = try? PhotoManager.inspect(url)

        let alert = NSAlert()
        alert.messageText = "Import Backup"

        var details: [String] = []
        if let manifest {
            let count = manifest.itemCount ?? manifest.photos.count
            details.append("\(count) widget\(count == 1 ? "" : "s")")
            details.append("from Tableau \(manifest.appVersion)")
            details.append(manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))
        }
        let provenance = details.isEmpty ? "" : details.joined(separator: " · ") + "\n\n"

        alert.informativeText = provenance + (manager.photos.isEmpty
            ? "Add the widgets from this backup to your desktop."
            : "Add these widgets to what you already have, or replace your current layout entirely? Replacing removes your existing widgets and can't be undone.")

        // Only offered when the file carries them, and never on by default — importing
        // somebody else's backup must not silently rebind this Mac's global shortcut.
        var prefsBox: NSButton?
        if let preferences = manifest?.preferences, !preferences.groups.isEmpty {
            let box = NSButton(
                checkboxWithTitle: "Also apply app settings (\(preferences.summary))",
                target: nil,
                action: nil
            )
            box.state = .off
            alert.accessoryView = box
            prefsBox = box
        }

        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace Everything")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        let mode: PhotoManager.LayoutImportMode
        switch alert.runModal() {
        case .alertFirstButtonReturn: mode = .merge
        case .alertSecondButtonReturn: mode = .replace
        default: return
        }

        do {
            let count = try manager.importLayout(from: url, mode: mode)
            if prefsBox?.state == .on, let preferences = manifest?.preferences {
                manager.applyImportedPreferences(preferences)
                snapEnabled = SnapEngine.shared.isEnabled
            }
            onMenuUpdate?()
            if count == 0 {
                presentAlert("Nothing to Import", "That backup didn't contain any widgets with valid images.", .informational)
            }
        } catch {
            presentAlert("Couldn't Import Backup", error.localizedDescription, .warning)
        }
    }

    private func presentAlert(_ title: String, _ message: String, _ style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private var lastCheckedDescription: String {
        guard let date = updater.lastChecked else { return "Never checked." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))."
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            content()
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
