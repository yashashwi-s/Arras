import SwiftUI
import AppKit

/// Click-to-record control for the global shortcut.
///
/// While recording it installs a local key monitor and swallows every keystroke,
/// so pressing something like ⌘Q sets the shortcut instead of quitting the app.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    var isEnabled: Bool

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        Button(action: toggleRecording) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .frame(minWidth: 74)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isEnabled)
        .help(isRecording ? "Press a key combination, or Esc to cancel" : "Click to record a new shortcut")
        .onDisappear(perform: stopRecording)
        .onChange(of: isEnabled) { _, nowEnabled in
            if !nowEnabled { stopRecording() }
        }
    }

    private var label: String {
        if isRecording { return rejected ? "Add ⌘/⌥/⌃" : "Press keys…" }
        return shortcut.displayString
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        rejected = false

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc cancels without changing anything.
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            if let captured = Shortcut(event: event) {
                shortcut = captured
                stopRecording()
            } else {
                // A bare key would hijack that key system-wide; make the user
                // add a real modifier rather than silently ignoring the press.
                rejected = true
            }
            return nil  // swallow it either way
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        rejected = false
    }
}
