import AppKit
import SwiftUI

struct SavedDesktopSetup: Codable, Identifiable {
    var id = UUID()
    var name: String
    var savedAt = Date()
    var photos: [PhotoItem]
}

struct DesktopSetupLibrary: Codable {
    var version = 1
    var setups: [SavedDesktopSetup] = []
    var previous: SavedDesktopSetup?
    var removed: RemovedWidgets?

    static func read(in storage: URL) throws -> Self {
        let url = storage.appendingPathComponent("setups.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let library = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard library.version == 1,
              Set(library.setups.map(\.id)).count == library.setups.count,
              (library.setups + [library.previous].compactMap { $0 }).allSatisfy({
                  Set($0.photos.map(\.id)).count == $0.photos.count
              }), Set(library.removed?.photos.map(\.id) ?? []).count == (library.removed?.photos.count ?? 0) else { throw SetupError.unreadable }
        return library
    }

    func write(in storage: URL) throws {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: storage.appendingPathComponent("setups.json"), options: .atomic)
    }

    var retainedPhotos: [PhotoItem] { setups.flatMap(\.photos) + (previous?.photos ?? []) + (removed?.photos ?? []) }
}

enum SetupError: LocalizedError {
    case unreadable, missing, emptyName, missingMedia, couldNotSave, unfinishedEdit, unfinishedArrangement
    var errorDescription: String? {
        switch self {
        case .unreadable: return "The saved setups could not be read. Their files have been preserved."
        case .missing: return "This setup is no longer available."
        case .emptyName: return "Give this setup a name."
        case .missingMedia: return "Some photos or fonts in this saved copy are missing or unreadable. Your current desktop has not changed."
        case .couldNotSave: return "The desktop could not be saved. Check available disk space and try again."
        case .unfinishedEdit: return "Apply or cancel your open collage appearance edit before saving or switching setups."
        case .unfinishedArrangement: return "Finish the affected move, resize or collage appearance edit, then restore the removed widgets again."
        }
    }
}

@MainActor
extension PhotoManager {
    func validateStoredPhotos(_ items: [PhotoItem]) throws {
        for item in items {
            for name in storedFilenames(in: item) where !name.isEmpty {
                guard name == URL(fileURLWithPath: name).lastPathComponent,
                      FileManager.default.fileExists(atPath: storageDir.appendingPathComponent(name).path) else { throw SetupError.missingMedia }
            }
            for name in item.desktopCollage?.fontFileNames ?? [] {
                guard CollageFontLibrary.isManagedFilename(name),
                      FileManager.default.fileExists(atPath: CollageFontLibrary.directory(in: storageDir).appendingPathComponent(name).path) else { throw SetupError.missingMedia }
            }
            if item.desktopCollage == nil {
                let names = item.spaceImageFilenames.isEmpty ? [item.filename] : item.spaceImageFilenames
                for name in names {
                    guard loadMediaContent(for: item, primaryURL: storageDir.appendingPathComponent(name)) != nil else {
                        throw SetupError.missingMedia
                    }
                }
            }
        }
    }

    @discardableResult
    func saveDesktopSetup(named name: String) throws -> UUID {
        guard collageAppearanceDrafts.isEmpty else { throw SetupError.unfinishedEdit }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SetupError.emptyName }
        var library = try DesktopSetupLibrary.read(in: storageDir)
        let setup = SavedDesktopSetup(name: String(trimmed.prefix(100)), photos: photos)
        library.setups.append(setup)
        try library.write(in: storageDir)
        // Save committed destinations before settling their live gesture. A
        // failed setup write must leave the user's provisional placement intact.
        cancelCollageInteractions(endAppearancePreviews: true)
        return setup.id
    }

    func renameDesktopSetup(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SetupError.emptyName }
        var library = try DesktopSetupLibrary.read(in: storageDir)
        guard let index = library.setups.firstIndex(where: { $0.id == id }) else { throw SetupError.missing }
        library.setups[index].name = String(trimmed.prefix(100))
        try library.write(in: storageDir)
    }

    func duplicateDesktopSetup(_ id: UUID) throws {
        var library = try DesktopSetupLibrary.read(in: storageDir)
        guard var setup = library.setups.first(where: { $0.id == id }) else { throw SetupError.missing }
        setup.id = UUID()
        setup.name += " Copy"
        setup.savedAt = Date()
        library.setups.append(setup)
        try library.write(in: storageDir)
    }

    func deleteDesktopSetup(_ id: UUID) throws {
        var library = try DesktopSetupLibrary.read(in: storageDir)
        guard let setup = library.setups.first(where: { $0.id == id }) else { throw SetupError.missing }
        library.setups.removeAll { $0.id == id }
        try library.write(in: storageDir)
        for filename in setup.photos.flatMap({ storedFilenames(in: $0) }) {
            removeStoredFileIfUnreferenced(filename)
        }
    }

    func activateDesktopSetup(_ id: UUID? = nil) throws {
        guard collageAppearanceDrafts.isEmpty else { throw SetupError.unfinishedEdit }
        var library = try DesktopSetupLibrary.read(in: storageDir)
        guard let setup = id.flatMap({ id in library.setups.first { $0.id == id } }) ?? (id == nil ? library.previous : nil) else {
            throw SetupError.missing
        }
        try validateStoredPhotos(setup.photos)
        // Write recovery before replacing the desktop. A failed second write leaves
        // the current desktop intact and a valid recovery copy, never lost media.
        let expiredRecovery = library.previous?.photos ?? []
        library.previous = SavedDesktopSetup(name: "Before switching setups", photos: photos)
        try library.write(in: storageDir)
        // The desktop installer settles old interactions after the active model
        // commits. Neither recovery-write nor active-save failure may cancel them.
        guard restoreDesktopSetupItems(setup.photos) else { throw SetupError.couldNotSave }
        for filename in expiredRecovery.flatMap({ storedFilenames(in: $0) }) {
            removeStoredFileIfUnreferenced(filename)
        }
    }
}

struct SavedSetupsView: View {
    @ObservedObject var manager: PhotoManager
    var onChange: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var library = DesktopSetupLibrary()
    @State private var name = ""
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var deleting: SavedDesktopSetup?
    @State private var error: String?
    @State private var discardingRecovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Saved Setups").font(.headline)
                Spacer()
            }
            Text("Save a desktop you like. Switch back whenever you need it.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                TextField("Setup name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save Current", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if library.setups.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No saved setups yet").font(.subheadline.bold())
                        Text("Name your current desktop above to save its photos and arrangement.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                List(library.setups) { setup in
                    HStack(spacing: 12) {
                        if let photo = setup.photos.first(where: { $0.desktopCollage == nil }),
                           let image = manager.thumbnail(for: photo) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 48, height: 40)
                        } else {
                            Image(systemName: "rectangle.stack").frame(width: 48, height: 40)
                        }
                        VStack(alignment: .leading) {
                            Text(setup.name).font(.headline)
                            let count = setup.photos.filter { $0.desktopCollage == nil }.count
                            Text("\(count) \(count == 1 ? "photo" : "photos") · \(setup.savedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use Setup") { perform { try manager.activateDesktopSetup(setup.id) } }
                        Menu {
                            Button("Duplicate") { perform { try manager.duplicateDesktopSetup(setup.id) } }
                            Button("Rename…") { renameText = setup.name; renameID = setup.id }
                            Button("Delete Saved Setup…", role: .destructive) { deleting = setup }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Actions for \(setup.name)")
                    }
                }
            }
            if library.previous != nil {
                Button("Restore Previous Desktop") { perform { try manager.activateDesktopSetup() } }
            }
            if library.removed != nil {
                HStack {
                    Button("Restore Removed Widgets") { perform { try manager.restoreRemovedWidgets() } }
                    Button("Discard Removal Recovery…", role: .destructive) { discardingRecovery = true }
                }
                .controlSize(.small)
            }
            Divider()
            HStack(alignment: .center, spacing: 20) {
                Text("Switching keeps your previous desktop recoverable. Export an .arras backup to transfer between Macs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 500)
        .frame(height: library.setups.isEmpty ? nil : 440)
        .onAppear { reload() }
        .alert("Discard Removal Recovery?", isPresented: $discardingRecovery) {
            Button("Discard Recovery", role: .destructive) { perform { try manager.discardRemovedWidgets() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The last removed widgets will no longer be recoverable here. Photos referenced by saved setups or your current desktop stay available.") }
        .alert("Rename Setup", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameID { perform { try manager.renameDesktopSetup(id, to: renameText) } }
                renameID = nil
            }
            Button("Cancel", role: .cancel) { renameID = nil }
        }
        .alert("Delete Saved Setup?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Saved Setup", role: .destructive) {
                if let setup = deleting { perform { try manager.deleteDesktopSetup(setup.id) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Your current desktop stays unchanged. This saved setup cannot be recovered after deletion.") }
        .alert("Couldn’t Change Setups", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() {
        perform { _ = try manager.saveDesktopSetup(named: name); name = "" }
    }
    private func reload() {
        do { library = try DesktopSetupLibrary.read(in: manager.storageDir) }
        catch { self.error = error.localizedDescription }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); reload(); onChange?() }
        catch { self.error = error.localizedDescription }
    }
}
