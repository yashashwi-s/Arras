import AppKit

/// The outcome of one user-initiated import batch.
///
/// Keeping the source and reason alongside the status lets each importer expose the same
/// accepted/skipped/failed contract without forcing callers to infer failures from a count.
/// Unsupported inputs are skipped; an input that was eligible but could not be read, decoded,
/// or saved is failed.
struct ImportBatchResult: Equatable {
    enum Status: String, Equatable {
        case accepted
        case skipped
        case failed
    }

    struct Entry: Equatable {
        let source: String
        let status: Status
        let reason: String?

        init(source: String, status: Status, reason: String? = nil) {
            self.source = source
            self.status = status
            self.reason = reason
        }
    }

    private(set) var entries: [Entry]

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    var accepted: [Entry] { entries.filter { $0.status == .accepted } }
    var skipped: [Entry] { entries.filter { $0.status == .skipped } }
    var failed: [Entry] { entries.filter { $0.status == .failed } }

    var acceptedCount: Int { accepted.count }
    var skippedCount: Int { skipped.count }
    var failedCount: Int { failed.count }
    var totalCount: Int { entries.count }
    var hasFailures: Bool { failedCount > 0 }
    var isEmpty: Bool { entries.isEmpty }

    mutating func append(source: String, status: Status, reason: String? = nil) {
        entries.append(Entry(source: source, status: status, reason: reason))
    }

    mutating func append(contentsOf other: ImportBatchResult) {
        entries.append(contentsOf: other.entries)
    }

    /// One consistent sentence format for picker, pasteboard, Photos, drop, and Space UI.
    /// Counts stay consistent across all import paths.
    func summary(for noun: String = "photo") -> String {
        guard !entries.isEmpty else { return "No \(plural(noun, count: 2)) were selected." }

        var parts = [
            "Accepted \(acceptedCount) \(plural(noun, count: acceptedCount))."
        ]
        if skippedCount > 0 {
            parts.append("Skipped \(skippedCount).")
        }
        if failedCount > 0 {
            parts.append("Failed \(failedCount).")
        }
        return parts.joined(separator: " ")
    }

    /// Explain actionable problems without turning a large import into an oversized alert.
    /// Failures take precedence over skipped files so an error is never buried by a batch limit.
    func presentationMessage(for noun: String = "photo") -> String {
        let problems = (failed + skipped).compactMap { entry -> String? in
            guard let reason = entry.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reason.isEmpty else { return nil }
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            return source.isEmpty ? reason : "\(source): \(reason)"
        }
        guard !problems.isEmpty else { return summary(for: noun) }
        var details = Array(problems.prefix(3))
        let remaining = problems.count - details.count
        if remaining > 0 {
            details.append("Plus \(remaining) more \(remaining == 1 ? "issue" : "issues").")
        }
        return summary(for: noun) + "\n\n" + details.joined(separator: "\n")
    }

    private func plural(_ noun: String, count: Int) -> String {
        guard count != 1 else { return noun }
        if noun.hasSuffix("s") { return noun }
        return noun + "s"
    }
}

/// Presents the shared import summary from AppKit and SwiftUI call sites alike.
@MainActor
enum ImportBatchPresenter {
    static func present(_ result: ImportBatchResult, title: String, noun: String = "photo") {
        guard !result.isEmpty else { return }

        AppDialog.inform(title: title, message: result.presentationMessage(for: noun),
                         style: result.hasFailures ? .warning : .informational)
    }
}
