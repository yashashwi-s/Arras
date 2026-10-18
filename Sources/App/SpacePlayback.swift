import Foundation

/// The order in which a Space chooses its next stored image.
///
/// This is intentionally a persisted enum rather than a UI-only picker value. `PhotoItem` keeps
/// its own order and selection state, so two Spaces can use different policies and relaunch
/// without losing a partially consumed no-repeat cycle.
enum SpacePlaybackOrder: String, Codable, CaseIterable, Identifiable, Hashable {
    case ordered
    case random
    case newestFirst
    case noRepeat

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ordered: return "Ordered"
        case .random: return "Random"
        case .newestFirst: return "Newest First"
        case .noRepeat: return "No Repeat"
        }
    }

    /// Accept the human-readable spellings used by early development builds as well as the
    /// canonical JSON values. Unknown values intentionally fall back to `.ordered`: a future
    /// policy must never make the entire photos store unreadable to an older build.
    init?(persistedValue: String) {
        switch persistedValue {
        case "ordered", "inOrder", "in-order": self = .ordered
        case "random": self = .random
        case "newestFirst", "newest-first", "newest": self = .newestFirst
        case "noRepeat", "no-repeat", "noRepeats": self = .noRepeat
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(persistedValue: raw) ?? .ordered
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // Short aliases keep call sites readable without introducing alternate persisted values.
    static var newest: Self { .newestFirst }
    static var noRepeats: Self { .noRepeat }
}

/// The state needed to make random and no-repeat selection continue identically after a save
/// and relaunch. It is kept as a value type so the selection algorithm is pure and easy to test.
struct SpacePlaybackSelection: Equatable {
    let index: Int
    let step: UInt64
    let history: [String]
}

/// Pure, deterministic Space selection. No system RNG or Swift `Hasher` is used here: both can
/// vary between processes, which would make a persisted playback policy impossible to reason
/// about after relaunch. The caller persists `step` and `history` on the owning `PhotoItem`.
enum SpacePlaybackSelector {
    static func nextSelection(
        filenames: [String],
        currentIndex: Int,
        order: SpacePlaybackOrder,
        seed: UInt64 = 0,
        step: UInt64 = 0,
        history: [String] = []
    ) -> SpacePlaybackSelection? {
        guard !filenames.isEmpty else { return nil }

        let current = filenames.indices.contains(currentIndex) ? currentIndex : filenames.startIndex
        let nextStep = step &+ 1

        switch order {
        case .ordered:
            return SpacePlaybackSelection(
                index: filenames.index(after: current) == filenames.endIndex
                    ? filenames.startIndex
                    : filenames.index(after: current),
                step: nextStep,
                history: []
            )

        case .newestFirst:
            let newestToOldest = Array(filenames.indices.reversed())
            let position = newestToOldest.firstIndex(of: current) ?? newestToOldest.startIndex
            let nextPosition = position + 1 == newestToOldest.endIndex
                ? newestToOldest.startIndex
                : position + 1
            return SpacePlaybackSelection(
                index: newestToOldest[nextPosition],
                step: nextStep,
                history: []
            )

        case .random:
            // A rotation must visibly advance when more than one image is available. Random
            // still permits repeats across rotations; users who need a complete cycle before a
            // repeat can select `.noRepeat`.
            let candidateCount = filenames.count - (filenames.count > 1 ? 1 : 0)
            let offset = Int(mixed(seed: seed, step: step) % UInt64(candidateCount))
            let index = filenames.count == 1 || offset < current ? offset : offset + 1
            return SpacePlaybackSelection(index: index, step: nextStep, history: [])

        case .noRepeat:
            return noRepeatSelection(
                filenames: filenames,
                currentIndex: current,
                seed: seed,
                step: step,
                history: history
            )
        }
    }

    /// Previous/next controls are deliberately symmetric for deterministic policies. Random and
    /// no-repeat do not have a meaningful inverse without replaying a whole history, so the
    /// manager keeps their established raw-index previous behavior and resets the no-repeat bag.
    static func previousIndex(
        filenames: [String],
        currentIndex: Int,
        order: SpacePlaybackOrder
    ) -> Int? {
        guard !filenames.isEmpty else { return nil }
        let current = filenames.indices.contains(currentIndex) ? currentIndex : filenames.startIndex
        switch order {
        case .newestFirst:
            return current == filenames.index(before: filenames.endIndex)
                ? filenames.startIndex
                : filenames.index(after: current)
        case .ordered, .random, .noRepeat:
            return current == filenames.startIndex ? filenames.index(before: filenames.endIndex) : filenames.index(before: current)
        }
    }

    // MARK: - Deterministic pseudo-random helpers

    private static func noRepeatSelection(
        filenames: [String],
        currentIndex: Int,
        seed: UInt64,
        step: UInt64,
        history: [String]
    ) -> SpacePlaybackSelection {
        let currentName = filenames[currentIndex]
        let validNames = Set(filenames)

        // Preserve insertion order while removing stale/duplicate history entries. Stale names
        // are expected after appending, replacing, or importing Space media.
        var seen: Set<String> = []
        var normalizedHistory = history.filter { name in
            validNames.contains(name) && seen.insert(name).inserted
        }
        if !seen.contains(currentName) {
            normalizedHistory.append(currentName)
            seen.insert(currentName)
        }

        var candidates = filenames.enumerated().filter { !seen.contains($0.element) }
        if candidates.isEmpty {
            // Exhaustion starts a new bag. Avoid repeating the image currently on screen at the
            // boundary whenever the Space has another image; a one-image Space necessarily
            // selects itself.
            normalizedHistory = [currentName]
            seen = [currentName]
            candidates = filenames.enumerated().filter { $0.element != currentName }
            if candidates.isEmpty {
                candidates = Array(filenames.enumerated())
            }
        }

        let selected = candidates.min { lhs, rhs in
            let left = score(filename: lhs.element, position: lhs.offset, seed: seed, step: step)
            let right = score(filename: rhs.element, position: rhs.offset, seed: seed, step: step)
            if left == right { return lhs.offset < rhs.offset }
            return left < right
        } ?? candidates[0]

        if !normalizedHistory.contains(selected.element) {
            normalizedHistory.append(selected.element)
        }
        return SpacePlaybackSelection(
            index: selected.offset,
            step: step &+ 1,
            history: normalizedHistory
        )
    }

    private static func score(filename: String, position: Int, seed: UInt64, step: UInt64) -> UInt64 {
        var value = mixed(seed: seed ^ UInt64(position) &* 0xD6E8FEB86659FD93, step: step)
        for byte in filename.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100000001B3
        }
        return mixed(seed: value, step: UInt64(position))
    }

    private static func mixed(seed: UInt64, step: UInt64) -> UInt64 {
        var value = seed &+ 0x9E3779B97F4A7C15 &+ step &* 0xD1B54A32D192ED03
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

enum SpacePlaybackSeed {
    /// UUIDs give independent Spaces independent deterministic streams without relying on a
    /// wall-clock value. The UUID string bytes also make this helper platform-independent.
    static func forID(_ id: UUID) -> UInt64 {
        var value: UInt64 = 14695981039346656037
        for byte in id.uuidString.utf8 {
            value ^= UInt64(byte)
            value &*= 1099511628211
        }
        return value
    }
}
