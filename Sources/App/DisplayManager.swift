import AppKit
import CoreGraphics

/// Identifies displays stably across reconnects and reboots, and tracks connect/disconnect
/// transitions so `PhotoManager` can hide/restore photos as their monitor comes and goes.
///
/// `CGDirectDisplayID` (exposed via `NSScreen.deviceDescription["NSScreenNumber"]`) is assigned
/// by the WindowServer at connect time and is **not** guaranteed stable across a reconnect, a
/// reboot, or even a sleep/wake cycle on some GPU/dock configurations — so it can't be persisted
/// as a key. Instead we fingerprint the physical panel using CGDisplayVendorNumber /
/// CGDisplayModelNumber / CGDisplaySerialNumber, which come from the display's EDID and stay
/// constant for as long as it's the same physical monitor. A handful of virtual displays
/// (Sidecar, some KVMs, AirPlay-to-Mac receivers) report zero for all three, so in that case we
/// fall back to `localizedName` — it won't disambiguate two identical external monitors, but
/// it's good enough to tell "the built-in display" apart from "the LG UltraFine".
@MainActor
final class DisplayManager {
    static let shared = DisplayManager()

    /// Identifiers seen as of the last `diffScreens()` call (or app launch).
    private(set) var knownIdentifiers: Set<String> = []

    private init() {
        knownIdentifiers = Set(NSScreen.screens.map(Self.identifier(for:)))
    }

    static func identifier(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.localizedName
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        guard vendor != 0 || model != 0 || serial != 0 else {
            return screen.localizedName
        }
        return "display-\(vendor)-\(model)-\(serial)"
    }

    /// Returns the currently-connected screen matching a saved identifier, if any is attached.
    func screen(for identifier: String) -> NSScreen? {
        NSScreen.screens.first { Self.identifier(for: $0) == identifier }
    }

    /// Diffs the current screen list against the last known set, returning identifiers that
    /// newly appeared / disappeared since the previous call. Intended to be called once per
    /// `NSApplication.didChangeScreenParametersNotification`.
    func diffScreens() -> (connected: Set<String>, disconnected: Set<String>) {
        let current = Set(NSScreen.screens.map(Self.identifier(for:)))
        let connected = current.subtracting(knownIdentifiers)
        let disconnected = knownIdentifiers.subtracting(current)
        knownIdentifiers = current
        return (connected, disconnected)
    }
}
