import Foundation
import StoreKit

/// Requests a native Mac App Store rating once the user has genuinely settled into Arras.
///
/// The prompt is strictly gated so brand-new users and active desktop edits are never
/// interrupted: at least three distinct active days, at least two widgets or one collage,
/// and a minimum 90-day cooldown plus once-per-version cap (in addition to Apple's own
/// system-wide throttling).
@MainActor
final class AppStoreReviewPrompt {
    static let shared = AppStoreReviewPrompt()

    static let activeDaysKey = "appStoreReview.activeDayKeys"
    static let lastPromptedDateKey = "appStoreReview.lastPromptedDate"
    static let lastPromptedVersionKey = "appStoreReview.lastPromptedVersion"

    static let minimumActiveDays = 3
    static let minimumPhotoCount = 2
    static let minimumCollageCount = 1
    static let cooldownDays = 90

    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    /// Records today as an active day and returns whether a review prompt should be requested.
    @discardableResult
    func evaluate(
        photoCount: Int,
        collageCount: Int,
        currentVersion: String = Constants.version,
        now: Date = Date(),
        requestReview: @MainActor () -> Void = { SKStoreReviewController.requestReview() }
    ) -> Bool {
        let dayKey = Self.dayKey(for: now, calendar: calendar)
        var activeDays = Set(defaults.stringArray(forKey: Self.activeDaysKey) ?? [])
        if activeDays.insert(dayKey).inserted {
            defaults.set(Array(activeDays).sorted(), forKey: Self.activeDaysKey)
        }

        guard activeDays.count >= Self.minimumActiveDays else { return false }
        guard photoCount >= Self.minimumPhotoCount || collageCount >= Self.minimumCollageCount else {
            return false
        }

        if let lastVersion = defaults.string(forKey: Self.lastPromptedVersionKey),
           lastVersion == currentVersion {
            return false
        }

        if let lastPrompted = defaults.object(forKey: Self.lastPromptedDateKey) as? Date {
            let elapsedDays = calendar.dateComponents([.day], from: lastPrompted, to: now).day ?? 0
            if elapsedDays < Self.cooldownDays {
                return false
            }
        }

        defaults.set(now, forKey: Self.lastPromptedDateKey)
        defaults.set(currentVersion, forKey: Self.lastPromptedVersionKey)
        requestReview()
        return true
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
