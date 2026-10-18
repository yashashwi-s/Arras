import AppKit

@MainActor
extension PhotoManager {
    var telemetryFacts: TelemetryFacts {
        var counts: [TelemetryWidgetType: Int] = [:]
        for item in photos {
            let kind: TelemetryWidgetType
            if item.desktopCollage != nil { kind = .collage }
            else if item.liveFolderSource != nil { kind = .linkedFolder }
            else if item.photosLibrarySource != nil { kind = .photosCollection }
            else if !item.spaceImageFilenames.isEmpty { kind = .slideshow }
            else {
                switch item.media.kind {
                case .animatedImage: kind = .animatedImage
                case .video: kind = .video
                case .livePhoto: kind = .livePhoto
                case .still: kind = .photo
                }
            }
            counts[kind, default: 0] += 1
        }
        return TelemetryFacts(counts: counts)
    }
}

/// The only bridge out of the model is a value containing broad type counts.
/// Disk and network work execute on the telemetry actor, away from UI work.
@MainActor
final class TelemetryRuntime {
    private let engine: Task<TelemetryEngine?, Never>
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(manager: PhotoManager, configuration: TelemetryConfiguration) {
        let directory = configuration.storageDirectory(in: manager.storageDir)
        let metadata = TelemetryMetadata.current
        let initial = manager.telemetryFacts
        engine = Task.detached(priority: .utility) {
            guard let engine = try? TelemetryEngine(directory: directory, metadata: metadata, configuration: configuration) else { return nil }
            await engine.start(with: initial)
            return engine
        }
        manager.lastTelemetryFacts = initial
        manager.onTelemetryFactsChanged = { [weak self] facts in self?.observe(facts) }
        // Give the first import a chance to join the first batch. No launch wait,
        // termination flush or per-interaction request is introduced.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.tick(manager: manager)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self, weak manager] _ in
            MainActor.assumeIsolated { if let manager { self?.tick(manager: manager) } }
        }
        timer?.tolerance = 300
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self, weak manager] _ in
            MainActor.assumeIsolated { if let manager { self?.tick(manager: manager) } }
        }
    }
    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    private func observe(_ facts: TelemetryFacts) {
        let engine = engine
        Task { if let engine = await engine.value { await engine.observe(facts) } }
    }
    private func tick(manager: PhotoManager) {
        let facts = manager.telemetryFacts, engine = engine
        Task {
            guard let engine = await engine.value else { return }
            await engine.observe(facts)
            await engine.flush()
        }
    }
}
