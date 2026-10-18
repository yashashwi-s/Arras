import AppKit
import SwiftUI

/// Shared native dialog conventions for menu commands and Settings actions.
@MainActor
enum AppDialog {
    struct Action {
        enum Role { case normal, cancel, destructive }
        let title: String
        var role: Role = .normal
    }

    static func make(title: String, message: String, style: NSAlert.Style = .informational,
                     actions: [Action] = [Action(title: "OK")]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        for action in actions {
            let button = alert.addButton(withTitle: action.title)
            button.hasDestructiveAction = action.role == .destructive
            button.keyEquivalent = ""
            if action.role == .cancel { button.keyEquivalent = "\u{1b}" }
        }
        // Return never accepts an irreversible action. Escape always cancels.
        if let index = actions.firstIndex(where: { $0.role == .normal }) {
            alert.buttons[index].keyEquivalent = "\r"
        } else {
            alert.window.defaultButtonCell = nil
        }
        return alert
    }

    static func inform(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = make(title: title, message: message, style: style)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
enum PrivacySettingsPane: String {
    case photos = "Privacy_Photos"
    case screenRecording = "Privacy_ScreenCapture"

    func open(using openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        // These pane links are macOS conventions, not a public API guarantee.
        // Always retain a general Settings fallback and a written navigation path.
        let urls = ["x-apple.systempreferences:com.apple.preference.security?\(rawValue)",
                    "x-apple.systempreferences:com.apple.preference.security"]
        for value in urls {
            if let url = URL(string: value), openURL(url) { return }
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
                                           configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

/// Native macOS disclosure labels can leave only the chevron clickable.
/// Use one keyboard-accessible button for the entire header, including its text.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
