import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut, stored as Carbon key code + modifier mask.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …), not `NSEvent.ModifierFlags`.
    var carbonModifiers: UInt32

    /// ⌥⌘P — unclaimed by macOS and by the apps this is most likely to sit behind.
    static let `default` = Shortcut(
        keyCode: UInt32(kVK_ANSI_P),
        carbonModifiers: UInt32(optionKey | cmdKey)
    )

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Builds a shortcut from a captured key event. Returns nil unless at least
    /// one non-shift modifier is held — a bare letter would swallow that key
    /// system-wide, which is never what the user meant.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        let anchoring: UInt32 = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard carbon & anchoring != 0 else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
    }

    /// Human-readable form, e.g. "⌥⌘P".
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    /// Maps a virtual key code to the glyph shown in menus. Covers the keys a
    /// shortcut is plausibly bound to; anything else falls back to the code.
    private static func keyName(for code: UInt32) -> String {
        let names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_Delete: "⌫", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]
        return names[Int(code)] ?? "Key \(code)"
    }
}

/// Owns the app's single global hotkey.
///
/// Uses Carbon's `RegisterEventHotKey` rather than
/// `NSEvent.addGlobalMonitorForEvents`, because the latter needs the
/// Accessibility (TCC) permission — far too invasive a prompt for a
/// show/hide convenience, and an extra hurdle in a sandboxed app.
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    /// Four-char code identifying our hotkey in the Carbon event stream ("TBLU").
    private static let signature: OSType = 0x54424C55

    /// Invoked on the main queue whenever the shortcut fires.
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private let enabledKey = "globalHotKeyEnabled"
    private let shortcutKey = "globalHotKeyShortcut"

    private init() {}

    // MARK: - Persisted settings

    var isEnabled: Bool {
        get {
            // Opt-in: a shortcut the user never chose shouldn't claim a system-wide
            // key combination behind their back.
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            apply()
        }
    }

    var shortcut: Shortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: shortcutKey),
                  let decoded = try? JSONDecoder().decode(Shortcut.self, from: data) else {
                return .default
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: shortcutKey)
            }
            apply()
        }
    }

    // MARK: - Registration

    /// Installs the Carbon event handler and registers the shortcut if enabled.
    /// Safe to call once at launch.
    func start() {
        installHandlerIfNeeded()
        apply()
    }

    /// Brings the live registration in line with the current settings.
    private func apply() {
        unregister()
        guard isEnabled else { return }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotKeyRef = ref
        } else {
            // Almost always means another app already owns the combination.
            // Leave the preference on so the user can pick a different one.
            NSLog("Tableau: could not register hotkey \(shortcut.displayString) (error \(status))")
        }
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Whether the last `apply()` actually claimed the combination.
    var isRegistered: Bool { hotKeyRef != nil }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The callback is a C function pointer, so it can't capture self —
        // it routes through the singleton instead.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr, id.signature == HotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { HotKeyManager.shared.onTrigger?() }
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef
        )
    }
}
