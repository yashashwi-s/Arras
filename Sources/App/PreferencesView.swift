import SwiftUI
import UniformTypeIdentifiers

/// App-wide behavior and recovery, separate from individual photo editing.
struct PreferencesView: View {
    @ObservedObject var manager: PhotoManager
    @ObservedObject var navigation: SettingsNavigation
    var onMenuUpdate: (() -> Void)?

    @ObservedObject private var hotKeys = HotKeyManager.shared
    @ObservedObject private var menuBar = MenuBarCustomization.shared
    #if !ARRAS_APP_STORE
    @ObservedObject private var updater = Updater.shared
    #endif

    @AppStorage(RemovalConfirmation.skipSettingsKey, store: RemovalConfirmation.preferenceStore) private var skipRemovalConfirmation = false

    #if ARRAS_APP_STORE
    @State private var importingExistingLibrary = false
    #endif
    @State private var showingSetups = false
    @State private var isPresented = false
    @State private var repositoryStars: Int?
    @State private var starsFocusRequest = UUID()

    private struct StarsRefreshID: Hashable {
        let tab: MainWindowView.Tab
        let focus: UUID
    }

    @State private var snapEnabled = SnapEngine.shared.isEnabled
    @State private var snapOtherApps = SnapEngine.shared.includesOtherApps

    @AppStorage("backup.includeSettings") private var includeSettingsInBackup = false
    @AppStorage("backup.archivalQuality") private var archivalQuality = false
    @AppStorage("backup.applySettingsOnImport") private var applySettingsOnImport = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Make Arras work your way").font(.title3.weight(.semibold))
                        caption("These settings apply across your desktops. Edit individual photos from the Photos tab.")
                    }
                    general
                    positioning
                    shortcut
                    #if ARRAS_APP_STORE
                    updates.id("updates")
                    #else
                    updates.id("updates")
                        .accessibilityIdentifier("settings-updates")
                    #endif
                    backup
                    menuBarSection
                    HStack {
                        Text("\(Constants.appName) \(Constants.version)").foregroundStyle(.secondary)
                        Spacer()
                        Link(destination: Constants.repositoryURL) {
                            HStack(spacing: 6) {
                                Label("Star on GitHub", systemImage: "star")
                                if let repositoryStars {
                                    Text(repositoryStars.formatted()).monospacedDigit()
                                }
                            }
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel(repositoryStars.map { "Star on GitHub, \($0) stars" } ?? "Star on GitHub")
                            .accessibilityHint("Opens the Arras repository in your browser")
                    }
                    .font(.system(size: 11))
                }
                .padding(20)
            }
            .onAppear {
                isPresented = true
                revealRequestedUpdates(using: proxy)
            }
            .onDisappear { isPresented = false }
            .task(id: StarsRefreshID(tab: navigation.selection, focus: starsFocusRequest)) {
                // Hosted view tests must not create third-party network traffic.
                guard navigation.selection == .preferences, !PhotoManager.isUnitTestHost else { return }
                let count = await RepositoryStarsStore.shared.count()
                guard !Task.isCancelled else { return }
                repositoryStars = count
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                // The managed Settings window is retained when closed. Focus
                // also refreshes its cached count when it reopens on this tab.
                guard navigation.selection == .preferences,
                      let window = note.object as? NSWindow,
                      window === AppDelegate.current?.settingsWindow else { return }
                starsFocusRequest = UUID()
            }
            .onChange(of: navigation.updatesRequest) { _, _ in
                if isPresented { revealRequestedUpdates(using: proxy) }
            }
        }
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .sheet(isPresented: $showingSetups) {
            SavedSetupsView(manager: manager, onChange: onMenuUpdate)
        }
    }

    private func revealRequestedUpdates(using proxy: ScrollViewProxy) {
        guard navigation.updatesRequest != nil else { return }
        proxy.scrollTo("updates", anchor: .top)
        navigation.updatesRequest = nil
    }

    // MARK: - General

    private var general: some View {
        section("Everyday behavior", icon: "gearshape") {
            Toggle("Launch at Login", isOn: Binding(
                get: { manager.launchAtLogin },
                set: { manager.setLaunchAtLogin($0); onMenuUpdate?() }
            ))
            .accessibilityHint("Starts \(Constants.appName) automatically when you log in")

            Toggle("Confirm removal in Settings", isOn: Binding(
                get: { !skipRemovalConfirmation }, set: { skipRemovalConfirmation = !$0 }
            ))
            .help("Menu-bar removal always asks for confirmation.")

        }
    }

    private var positioning: some View {
        section("Moving & aligning", icon: "arrow.up.left.and.arrow.down.right") {
            Toggle("Snap photos and collages into alignment", isOn: $snapEnabled)
                .onChange(of: snapEnabled) { _, value in SnapEngine.shared.isEnabled = value }
                .accessibilityHint("Aligns photos to screen edges and other photos while you drag")

            Toggle("Also snap to other apps' windows", isOn: $snapOtherApps)
                .onChange(of: snapOtherApps) { _, value in SnapEngine.shared.includesOtherApps = value }
                .disabled(!snapEnabled)
                .accessibilityHint("Aligns photos to other applications' windows and to the system's desktop widgets")
            caption("Hold Command while dragging to ignore snapping. Hold Shift to move along one axis.")
            if snapOtherApps && snapEnabled {
                caption("Uses window positions, never window contents.")
            }
        }
    }

    // MARK: - Shortcut

    private var shortcut: some View {
        section("Desktop shortcut", icon: "keyboard") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show / hide all widgets", isOn: Binding(
                    get: { hotKeys.isEnabled },
                    set: { hotKeys.isEnabled = $0; onMenuUpdate?() }
                ))

                HStack {
                    Text("Shortcut").foregroundStyle(.secondary)
                    Spacer()
                    ShortcutRecorder(
                        shortcut: Binding(
                            get: { hotKeys.shortcut },
                            set: { hotKeys.shortcut = $0; onMenuUpdate?() }
                        ),
                        isEnabled: hotKeys.isEnabled
                    )
                }

                if hotKeys.isEnabled && !hotKeys.isRegistered {
                    Label("In use by another app", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }
            caption("Temporarily clear your desktop, then bring your photos and collages back with the same shortcut.")
        }
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        section("Menu bar", icon: "menubar.rectangle") {
            caption("Quick access to clipboard images, screen capture, PDF pages and slideshows.")
            VStack(alignment: .leading, spacing: 12) {
                Text("Show in the Arras menu").font(.subheadline.weight(.medium))
                caption("Turn on a command here, then open Arras in the menu bar. Photo import commands appear under Add.")

                ForEach(MenuBarCustomization.Item.allCases) { item in
                    Toggle(isOn: Binding(
                        get: { menuBar.isVisible(item) },
                        set: { menuBar.setVisible(item, $0); onMenuUpdate?() }
                    )) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title)
                            Text(item.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Updates

    private var updates: some View {
        section("Updates", icon: "arrow.triangle.2.circlepath") {
            #if ARRAS_APP_STORE
            caption("Updates are provided by the Mac App Store. Manage automatic updates in App Store settings.")
            Button("Check for Updates") { AppStoreUpdates.checkForUpdates() }
                .controlSize(.small)
                .accessibilityIdentifier("settings-update-action")
                .accessibilityHint("Opens the Updates page in the Mac App Store")
            #else
            if !updater.updatesAllowed {
                caption("Updates are paused for this private test build. Install a newer test build when it is shared with you.")
            } else {
                Toggle("Automatically install updates", isOn: Binding(
                    get: { updater.automaticUpdatesEnabled },
                    set: { updater.automaticUpdatesEnabled = $0 }
                ))
                .accessibilityHint("Checks on the selected schedule. When enabled, installs updates after checksum and app-bundle validation. When disabled, notifies you when a new version is found.")

                caption(updater.checkFrequency == .never
                    ? "Automatic checking is off. Use Check Now to look for updates."
                    : updater.automaticUpdatesEnabled
                        ? "Checks \(updater.checkFrequency.label.lowercased()) and installs verified updates when you’re not editing."
                        : "Checks \(updater.checkFrequency.label.lowercased()) and notifies you when a newer version is found.")

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
                    .accessibilityHint("Sets the schedule for background checks. You can always check manually.")

                    UpdateActionButton()
                        .accessibilityIdentifier("settings-update-action")

                    Spacer()
                }

                UpdateStatusLine()
            }
            #endif
        }
    }

    // MARK: - Backup & transfer

    private var backup: some View {
        section("Setups & backup", icon: "externaldrive") {
            caption("Saved Setups keeps different arrangements on this Mac. A backup packages your current desktop and stored media for recovery or another Mac.")
            Button("Saved Setups…", systemImage: "rectangle.stack") { showingSetups = true }
            HStack(spacing: 8) {
                Button("Export Backup…") { exportBackup() }
                Button("Import Backup…") { importBackup() }
            }
            Divider().padding(.vertical, 2)
            #if ARRAS_APP_STORE
            VStack(alignment: .leading, spacing: 8) {
                Text("Moving from the direct-download app?").font(.subheadline.weight(.medium))
                caption("Import its library to bring over photos, saved setups and custom fonts. Your original library stays untouched. Linked folders need to be selected again.")
                HStack(spacing: 8) {
                    Button("Import Existing Arras Library…") { importExistingLibrary() }
                        .disabled(importingExistingLibrary || !manager.canImportExistingLibrary)
                        .accessibilityIdentifier("import-existing-library")
                    if importingExistingLibrary { ProgressView().controlSize(.small) }
                }
                if !importingExistingLibrary && !manager.canImportExistingLibrary {
                    caption("This desktop already has saved content. Use Import Backup to merge an exported .arras layout.")
                }
            }
            Divider().padding(.vertical, 2)
            #endif
            DisclosureGroup("Backup options") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Include app settings when exporting", isOn: $includeSettingsInBackup)
                    Toggle("Apply app settings when importing", isOn: $applySettingsOnImport)
                    #if ARRAS_APP_STORE
                    caption("Settings can include your shortcut, login behavior and privacy choices. Leave these off to transfer only the desktop.")
                    #else
                    caption("Settings can include your shortcut, login behavior, updates and privacy choices. Leave these off to transfer only the desktop.")
                    #endif
                    Toggle("Archive-quality export", isOn: $archivalQuality)
                    caption("Preserves Arras’s stored files exactly and records their quality. It cannot recover originals that were resized before storage.")
                }
            }
        }
    }

    #if ARRAS_APP_STORE
    private func importExistingLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Library"
        panel.message = "Choose the PhotoWidget folder in ~/Library/Application Support. You can use Shift–Command–G to enter that location."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importingExistingLibrary = true
        Task { @MainActor in
            defer { importingExistingLibrary = false }
            do {
                try await manager.importExistingLibrary(from: source)
                onMenuUpdate?()
                AppDialog.inform(title: "Library Imported", message: "Your photos, saved setups and fonts are ready. Your original library is unchanged. Use Relink Folder for linked slideshows.")
            } catch {
                AppDialog.inform(title: "Couldn’t Import Library", message: error.localizedDescription, style: .warning)
            }
        }
    }

    #endif

    private func exportBackup() {
        let groups: Set<ExportedPreferences.Group> =
            includeSettingsInBackup ? Set(ExportedPreferences.Group.allCases) : []

        let panel = NSSavePanel()
        panel.allowedContentTypes = [BackupFormat.exportType]
        panel.nameFieldStringValue = "Arras Backup.\(BackupFormat.currentExtension)"
        panel.prompt = "Export"
        panel.message = "Where should the backup go?"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let quality = archivalQuality
        Task { @MainActor in
            do {
                let report = try await manager.exportLayoutInBackground(to: url, preferenceGroups: groups,
                                                                        archivalQuality: quality)
                LayoutArchiveExportFlow.present(report)
            } catch {
                LayoutArchiveExportFlow.present(error: error, title: "Couldn't Export Backup")
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        // Both, so backups written before the rename still open.
        panel.allowedContentTypes = BackupFormat.importTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose an Arras backup"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LayoutArchiveImportFlow.present(
            url: url,
            manager: manager,
            applySettings: applySettingsOnImport,
            onMenuUpdate: onMenuUpdate,
            onPreferencesApplied: {
                snapEnabled = SnapEngine.shared.isEnabled
                snapOtherApps = SnapEngine.shared.includesOtherApps
            }
        )
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsSectionSurface()
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
