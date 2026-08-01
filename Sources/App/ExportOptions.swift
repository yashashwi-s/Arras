import AppKit

/// Accessory view for the export save panel: which parts of a backup to write.
///
/// Plain AppKit controls rather than an `NSHostingView`. The SwiftUI version updated its model
/// on click but did not reflect it until the panel was closed and reopened. I could not isolate
/// why — a harness proved a hosted SwiftUI view *does* repaint inside `runModal`'s modal run
/// loop, so the obvious explanation was wrong — and an accessory view is four checkboxes and a
/// caption. This is less code than the thing it replaces, and it matches how the import dialog
/// next door already builds its checkbox.
///
/// App settings default to *off*: a file meant for sharing shouldn't carry the author's login
/// item, global shortcut and privacy choices unless they say so.
final class ExportOptionsView: NSView {
    private let appSettingsBox = NSButton(checkboxWithTitle: "App settings", target: nil, action: nil)
    private var groupBoxes: [(group: ExportedPreferences.Group, button: NSButton)] = []

    /// Which preference groups the user has asked for. Empty means "widgets only".
    var selectedGroups: Set<ExportedPreferences.Group> {
        guard appSettingsBox.state == .on else { return [] }
        return Set(groupBoxes.filter { $0.button.state == .on }.map(\.group))
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 10))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let always = NSButton(checkboxWithTitle: "Widgets, positions and appearance", target: nil, action: nil)
        always.state = .on
        always.isEnabled = false
        always.toolTip = "Always included — it's what a Tableau backup is for"
        stack.addArrangedSubview(always)

        appSettingsBox.state = .off
        appSettingsBox.target = self
        appSettingsBox.action = #selector(appSettingsToggled)
        stack.addArrangedSubview(appSettingsBox)

        for group in ExportedPreferences.Group.allCases {
            let box = NSButton(checkboxWithTitle: group.title, target: nil, action: nil)
            box.state = .on
            box.isEnabled = false
            let row = NSStackView(views: [box])
            row.orientation = .horizontal
            row.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
            stack.addArrangedSubview(row)
            groupBoxes.append((group, box))
        }

        let caption = NSTextField(wrappingLabelWithString:
            "Positions are stored relative to the screen, so this opens correctly on a Mac with different displays.")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .tertiaryLabelColor
        caption.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(caption)
        stack.setCustomSpacing(10, after: groupBoxes.last?.button.superview ?? appSettingsBox)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func appSettingsToggled() {
        let enabled = appSettingsBox.state == .on
        for entry in groupBoxes {
            entry.button.isEnabled = enabled
        }
    }
}
