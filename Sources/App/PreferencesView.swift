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
    @ObservedObject private var activation = AppActivation.shared
    @ObservedObject private var menuBar = MenuBarCustomization.shared
    @ObservedObject private var updater = Updater.shared

    @State private var snapEnabled = SnapEngine.shared.isEnabled

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

            Toggle("Show in Dock & App Switcher", isOn: Binding(
                get: { activation.showsInDock },
                set: { activation.showsInDock = $0; onMenuUpdate?() }
            ))
            // Worth saying out loud: people look for these as two settings.
            .accessibilityHint("macOS ties these together — an app in the app switcher always has a Dock icon")
            caption("macOS ties these together. An app that appears in ⌘Tab always has a Dock icon.")

            Toggle("Snap to Edges", isOn: $snapEnabled)
                .onChange(of: snapEnabled) { _, value in SnapEngine.shared.isEnabled = value }
                .accessibilityHint("Aligns photos to screen edges and other photos while you drag")
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

    // MARK: - Backup

    private var backup: some View {
        section("SETTINGS BACKUP") {
            caption("Save these settings to a file, or load them on another Mac. Photos are exported separately from the Layout menu.")

            HStack(spacing: 8) {
                Button("Export Settings…") { exportSettings() }
                    .controlSize(.small)
                Button("Import Settings…") { importSettings() }
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Tableau Settings.json"
        panel.prompt = "Export"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let prefs = ExportedPreferences.current(launchAtLogin: manager.launchAtLogin)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(prefs) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(ExportedPreferences.self, from: data) else { return }

        // Same reasoning as importing a layout: these are system-wide, so confirm
        // before rebinding somebody's global shortcut or login item.
        let alert = NSAlert()
        alert.messageText = "Apply these settings?"
        alert.informativeText = "This will change: \(prefs.summary)."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        manager.applyImportedPreferences(prefs)
        snapEnabled = SnapEngine.shared.isEnabled
        onMenuUpdate?()
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
