import AppKit
import IOKit.ps

/// The process-wide conditions that can make a widget's render-server animation or Space
/// rotation unnecessary. Keeping this value separate from AppKit makes the policy deterministic
/// in tests and keeps each window's occlusion bit as the only per-window input.
struct RuntimeActivityEnvironment: Equatable {
    var isLowPowerModeEnabled = false
    var isRunningOnLowBattery = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    var shouldReduceMotion = false
    var isSleeping = false
    var isPresenceSuppressed = false
}

/// Per-widget coverage combines AppKit's full occlusion signal with app-window overlap.
/// A partially covered widget also yields its decorative work until it is uncovered.
struct RuntimeActivityInput: Equatable {
    var isOccluded = false
    var environment = RuntimeActivityEnvironment()
}

/// The result consumed by both the animated image layer and the Space timer.
struct RuntimeActivityDecision: Equatable {
    enum Blocker: Hashable {
        case occluded
        case lowPowerMode
        case lowBattery
        case thermalPressure
        case reduceMotion
        case sleeping
        case presenceSuppressed
    }

    let blockers: Set<Blocker>

    var allowsExpensiveAnimation: Bool { blockers.isEmpty }
    var allowsRotation: Bool { blockers.isEmpty }
    var isPaused: Bool { !blockers.isEmpty }

    static let active = RuntimeActivityDecision(blockers: [])
}

/// Pure runtime policy. It deliberately leaves `.fair` thermal state alone: macOS describes
/// that state as a warning, while `.serious` and `.critical` are the points where this app's
/// continuous decorative work should yield to system thermal recovery.
enum RuntimeActivityPolicy {
    /// AppKit reports a partially visible window with `.visible` still set. Only a state with
    /// that bit absent is safe to classify as fully covered.
    static func isFullyOccluded(_ occlusionState: NSWindow.OcclusionState) -> Bool {
        !occlusionState.contains(.visible)
    }

    static func decision(for input: RuntimeActivityInput) -> RuntimeActivityDecision {
        var blockers: Set<RuntimeActivityDecision.Blocker> = []
        if input.isOccluded { blockers.insert(.occluded) }
        if input.environment.isLowPowerModeEnabled { blockers.insert(.lowPowerMode) }
        if input.environment.isRunningOnLowBattery { blockers.insert(.lowBattery) }
        if thermalWorkShouldPause(input.environment.thermalState) {
            blockers.insert(.thermalPressure)
        }
        if input.environment.shouldReduceMotion { blockers.insert(.reduceMotion) }
        if input.environment.isSleeping { blockers.insert(.sleeping) }
        if input.environment.isPresenceSuppressed { blockers.insert(.presenceSuppressed) }
        return RuntimeActivityDecision(blockers: blockers)
    }

    private static func thermalWorkShouldPause(_ state: ProcessInfo.ThermalState) -> Bool {
        switch state {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            // An unknown future state is safer to treat as pressure than to keep an
            // unbounded decorative workload running through it.
            return true
        }
    }
}

/// A small, deterministic policy around IOKit's power-source snapshot. Battery percentage only
/// suppresses decorative work while the Mac is actually drawing from its battery. Plugging in
/// resumes immediately even when the battery has not charged past the threshold yet.
enum BatteryActivityPolicy {
    static let lowBatteryThresholdPercent = 20

    static func shouldPause(
        isDrawingFromBattery: Bool,
        currentCapacity: Int?,
        maximumCapacity: Int?
    ) -> Bool {
        guard isDrawingFromBattery,
              let currentCapacity,
              let maximumCapacity,
              maximumCapacity > 0 else { return false }
        return currentCapacity * 100 <= maximumCapacity * lowBatteryThresholdPercent
    }
}

private enum SystemPowerSource {
    static func isRunningOnLowBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sourceType = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
        guard sourceType == kIOPSBatteryPowerValue else { return false }

        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)
                .takeUnretainedValue() as? [String: Any],
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int else { continue }
            if BatteryActivityPolicy.shouldPause(
                isDrawingFromBattery: true,
                currentCapacity: current,
                maximumCapacity: maximum
            ) { return true }
        }
        return false
    }
}

/// One shared source of process-wide runtime signals. It does not own windows: every widget
/// observes its own occlusion notification and combines it with this environment. That avoids
/// one observer per widget for power, thermal and accessibility changes while still allowing a
/// widget to stop work as soon as WindowServer says it is fully covered.
@MainActor
final class RuntimeActivityCenter {
    static let shared = RuntimeActivityCenter()

    private(set) var environment: RuntimeActivityEnvironment

    private var notificationTokens: [NSObjectProtocol] = []
    private var listeners: [UUID: (RuntimeActivityEnvironment) -> Void] = [:]
    private var systemIsSleeping = false
    private var screensAreSleeping = false
    private var powerSourceRunLoopSource: CFRunLoopSource?

    // The macOS 14 SDK exposes this public notification as a global Foundation name rather
    // than a stable `ProcessInfo` namespace, so keep the documented name local and type-safe.
    private static let powerStateDidChangeNotification = Notification.Name(
        rawValue: "NSProcessInfoPowerStateDidChangeNotification"
    )

    private init() {
        let processInfo = ProcessInfo.processInfo
        environment = RuntimeActivityEnvironment(
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            isRunningOnLowBattery: SystemPowerSource.isRunningOnLowBattery(),
            thermalState: processInfo.thermalState,
            shouldReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: Self.powerStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPowerState() }
        })
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let center = Unmanaged<RuntimeActivityCenter>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in center.refreshBatteryState() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        notificationTokens.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshThermalState() }
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshReduceMotion() }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setSystemSleeping(true) }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setSystemSleeping(false) }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setScreensSleeping(true) }
        })
        notificationTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setScreensSleeping(false) }
        })
    }

    /// Adds a process-wide listener. The initial value is delivered by the caller after it has
    /// combined this environment with its current window occlusion state.
    @discardableResult
    func addListener(_ listener: @escaping (RuntimeActivityEnvironment) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    /// PresenceMonitor already tears down windows while its fullscreen/conferencing policy is
    /// active. Mirroring that suppression here closes the short hand-off window and also keeps
    /// any surviving window from restarting decorative work before teardown completes.
    func setPresenceSuppressed(_ suppressed: Bool) {
        guard suppressed != environment.isPresenceSuppressed else { return }
        environment.isPresenceSuppressed = suppressed
        notifyListeners()
    }

    private func refreshPowerState() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard enabled != environment.isLowPowerModeEnabled else { return }
        environment.isLowPowerModeEnabled = enabled
        notifyListeners()
    }

    private func refreshBatteryState() {
        let isLow = SystemPowerSource.isRunningOnLowBattery()
        guard isLow != environment.isRunningOnLowBattery else { return }
        environment.isRunningOnLowBattery = isLow
        notifyListeners()
    }

    private func refreshThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        guard state != environment.thermalState else { return }
        environment.thermalState = state
        notifyListeners()
    }

    private func refreshReduceMotion() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard reduced != environment.shouldReduceMotion else { return }
        environment.shouldReduceMotion = reduced
        notifyListeners()
    }

    private func setSystemSleeping(_ sleeping: Bool) {
        guard sleeping != systemIsSleeping else { return }
        systemIsSleeping = sleeping
        refreshSleepingState()
    }

    private func setScreensSleeping(_ sleeping: Bool) {
        guard sleeping != screensAreSleeping else { return }
        screensAreSleeping = sleeping
        refreshSleepingState()
    }

    private func refreshSleepingState() {
        let sleeping = systemIsSleeping || screensAreSleeping
        guard sleeping != environment.isSleeping else { return }
        environment.isSleeping = sleeping
        notifyListeners()
    }

    private func notifyListeners() {
        // A listener is allowed to remove itself while handling the update, so iterate over a
        // snapshot rather than the dictionary being mutated by a window teardown.
        for listener in Array(listeners.values) {
            listener(environment)
        }
    }
}
