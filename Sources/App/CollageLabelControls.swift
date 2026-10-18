import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CollageLabelControls: View {
    @Binding var settings: DesktopCollageSettings
    @Binding var selection: UUID
    var arrange: () -> Void
    var chooseFont: () -> Void

    private var style: Binding<CollageLabelStyle> {
        Binding(get: { settings.labelStyle(for: selection) }, set: { settings.setLabelStyle($0, for: selection) })
    }
    private func field<Value>(_ key: WritableKeyPath<CollageLabelStyle, Value>) -> Binding<Value> {
        Binding(get: { style.wrappedValue[keyPath: key] }, set: { value in
            var changed = style.wrappedValue; changed[keyPath: key] = value; style.wrappedValue = changed
        })
    }
    private var text: Binding<String> {
        Binding(get: { settings.textLabels.first { $0.id == selection }?.text ?? "" }, set: { settings.setLabelText($0, for: selection) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Labels").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Add Label") {
                    let label = CollageTextLabel()
                    settings.labels.append(label)
                    selection = label.id
                }.disabled(settings.labels.count >= 12)
                if selection != CollageTextLabel.captionID {
                    Button { settings.labels.removeAll { $0.id == selection }; selection = CollageTextLabel.captionID } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remove selected label")
                }
            }
            if !settings.labels.isEmpty {
                Picker("Editing", selection: $selection) {
                    ForEach(settings.textLabels) { label in
                        Text(label.id == CollageTextLabel.captionID ? "Main caption" : String(label.text.prefix(26))).tag(label.id)
                    }
                }
            }
            TextField("A memory, date, or a few words…", text: text, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Label text")
                .accessibilityIdentifier(selection == CollageTextLabel.captionID ? "collage-caption" : "collage-label-text")
            Picker("Font", selection: Binding(get: { style.wrappedValue.font }, set: { font in
                var changed = style.wrappedValue; changed.font = font
                if font != .custom && changed.weight == .original { changed.weight = .regular }
                style.wrappedValue = changed
            })) {
                ForEach(CollageLabelFont.allCases.filter { $0 != .custom }) { Text($0.title).tag($0) }
                if style.wrappedValue.font == .custom {
                    Text(style.wrappedValue.fontName ?? "Another Font").tag(CollageLabelFont.custom)
                }
            }
            slider("Size", value: field(\.fontSize), range: 10...96, display: "\(Int(style.wrappedValue.fontSize * settings.compositionScale)) pt")
            HStack {
                Button("Arrange Labels…", action: arrange)
                    .accessibilityIdentifier("arrange-collage-labels")
                Spacer()
                if selection == CollageTextLabel.captionID {
                    Button("Return to Caption Strip") {
                        var changed = style.wrappedValue; changed.placement = .caption; changed.rotationDegrees = 0
                        style.wrappedValue = changed
                    }.disabled(style.wrappedValue.placement == .caption && style.wrappedValue.rotationDegrees == 0)
                }
            }
            CollageDetails("Advanced text settings", identifier: "collage-text-advanced-toggle") {
                Button("More Fonts…", action: chooseFont)
                HStack {
                    Picker("Weight", selection: field(\.weight)) {
                        ForEach(CollageLabelWeight.allCases.filter { $0 != .original || style.wrappedValue.font == .custom }) { Text($0.title).tag($0) }
                    }
                    Toggle("Italic", isOn: field(\.italic)).toggleStyle(.checkbox)
                    Toggle("Shadow", isOn: field(\.shadow)).toggleStyle(.checkbox)
                }
                HStack {
                    Toggle("Automatic color", isOn: Binding(get: { style.wrappedValue.colorHex == nil }, set: { automatic in
                        var changed = style.wrappedValue; changed.colorHex = automatic ? nil : "#202226"; style.wrappedValue = changed
                    })).toggleStyle(.checkbox)
                    Spacer()
                    if style.wrappedValue.colorHex != nil {
                        ColorPicker("Color", selection: Binding(get: { Color(nsColor: NSColor.fromHex(style.wrappedValue.colorHex ?? "#202226") ?? .labelColor) }, set: { color in
                            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                            var changed = style.wrappedValue
                            changed.colorHex = String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                            style.wrappedValue = changed
                        }), supportsOpacity: false)
                    }
                }
                Picker("Alignment", selection: field(\.alignment)) {
                    ForEach(CollageLabelAlignment.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                slider("Opacity", value: field(\.opacity), range: 0...1, display: "\(Int(style.wrappedValue.opacity * 100))%")
                slider("Letter spacing", value: field(\.tracking), range: -2...12, display: String(format: "%.1f pt", style.wrappedValue.tracking * settings.compositionScale))
                slider("Line spacing", value: field(\.lineSpacing), range: 0...32, display: "\(Int(style.wrappedValue.lineSpacing * settings.compositionScale)) pt")
                slider("Text width", value: field(\.widthFraction), range: 0.15...1, display: "\(Int(style.wrappedValue.widthFraction * 100))%")
                Text("Up to 180 characters per label. Long labels fit down inside the collage.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .onChange(of: settings.labels.map(\.id)) { _, ids in
            if selection != CollageTextLabel.captionID && !ids.contains(selection) { selection = CollageTextLabel.captionID }
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, display: String) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel("Label " + title.lowercased())
            Text(display).monospacedDigit().frame(width: 55, alignment: .trailing)
        }
    }
}

struct CollageFontPicker: View {
    let storage: URL
    var retainedFontFiles: () -> Set<String>
    let selectedStyle: CollageLabelStyle
    var onChoose: (String, String?) -> Void
    var onClose: () -> Void
    @State private var search = ""
    @State private var names = NSFontManager.shared.availableFonts.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    @State private var selected = ""
    @State private var importedFiles: [String: String] = [:]
    @State private var fontError: String?
    private var filtered: [String] { search.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a font").font(.system(size: 18, weight: .semibold))
            TextField("Search fonts on your Mac", text: $search).textFieldStyle(.roundedBorder)
            List(filtered, id: \.self, selection: $selected) { name in
                HStack {
                    Text(NSFont(name: name, size: 14)?.displayName ?? name).font(.system(size: 12))
                    Spacer()
                    Text("Aa").font(Font(NSFont(name: name, size: 22) ?? .systemFont(ofSize: 22)))
                }.tag(name)
            }.frame(height: 245)
            Text("A good day, kept close.")
                .font(Font(NSFont(name: selected, size: 26) ?? .systemFont(ofSize: 26)))
                .frame(maxWidth: .infinity, minHeight: 55)
            HStack {
                Button("Import Font…", action: importFont)
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Use Font") {
                    onChoose(selected, importedFiles[selected] ?? (selected == selectedStyle.fontName ? selectedStyle.fontFileName : nil))
                }.keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
            Button("Remove Unused Imports") {
                do {
                    var retained = retainedFontFiles()
                    if let current = importedFiles[selected] { retained.insert(current) }
                    _ = try CollageFontLibrary.removeUnused(in: storage, retaining: retained)
                    importedFiles = CollageFontLibrary.filesByFontName(in: storage)
                    names = NSFontManager.shared.availableFonts.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                } catch { fontError = error.localizedDescription }
            }
            Text("Imported fonts stay in your library even if you cancel editing. Used fonts are included in backups. Remove Unused Imports keeps fonts used by saved collages, open drafts, and your current selection.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(22).frame(width: 500)
        .onAppear {
            selected = CollageTypography.font(for: selectedStyle).fontName
            importedFiles = CollageFontLibrary.filesByFontName(in: storage)
        }
        .alert("Couldn’t Add Font", isPresented: Binding(get: { fontError != nil }, set: { if !$0 { fontError = nil } })) {
            Button("OK", role: .cancel) { fontError = nil }
        } message: { Text(fontError ?? "Choose another font file.") }
    }

    private func importFont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.font]
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Font"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try CollageFontLibrary.importFont(from: url, into: storage)
            for name in imported.names { importedFiles[name] = imported.fileName }
            names = Array(Set(names + imported.names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            selected = imported.names[0]
        } catch { fontError = error.localizedDescription }
    }
}
