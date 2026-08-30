import AppKit
import SwiftUI

/// Shared Settings warning and recovery surface for the JSON store and imported media.
///
/// This is deliberately a view over `PhotoManager` rather than an alert fired from a write
/// callback. Persistence can fail while Settings is closed (for example during a drag), and a
/// persistent, dismissible notice is the only way to make that diagnosis available when the
/// user next opens the app.
struct PersistenceStatusView: View {
    @ObservedObject var manager: PhotoManager
    var showFailures = true
    var showRecoveryWhenHealthy = true

    @State private var confirmingRestore = false

    /// The banner owns recovery while the store is blocked. Preferences exposes the same
    /// revisions only when the store is healthy, so a save/media warning can never suggest a
    /// restore and a load warning can never render two restore buttons.
    private var shouldShowRecovery: Bool {
        guard !manager.availableRevisions.isEmpty else { return false }
        if manager.isStoreLoadBlocked {
            return !showRecoveryWhenHealthy
        }
        return showRecoveryWhenHealthy && manager.persistenceFailures.isEmpty
    }

    var body: some View {
        if (showFailures && !manager.persistenceFailures.isEmpty) || shouldShowRecovery {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(manager.persistenceFailures) { failure in
                    failureCard(failure)
                }

                if shouldShowRecovery, let latest = manager.availableRevisions.first {
                    recoveryCard(latest: latest)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .confirmationDialog(
                "Restore the previous widget layout?",
                isPresented: $confirmingRestore,
                titleVisibility: .visible
            ) {
                Button("Restore Previous Layout", role: .destructive) {
                    _ = manager.restoreLatestRevision()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This replaces your current widgets, positions, and appearance settings with the most recently saved earlier layout. It does not use or change any exported .arras backup file.")
            }
        }
    }

    private func failureCard(_ failure: PersistenceFailure) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(failure.title, systemImage: failure.kind.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(failure.kind == .mediaImport ? Color.orange : Color.primary)

            Text(failure.detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Dismiss") {
                    manager.dismissPersistenceFailure(failure.id)
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
                .accessibilityHint("Hides this notice without changing the saved photo layout")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func recoveryCard(latest: PhotoStoreRevision) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Undo a recent layout change", systemImage: "arrow.counterclockwise.circle")
                .font(.system(size: 11, weight: .semibold))

            Text("\(manager.availableRevisions.count) earlier layout\(manager.availableRevisions.count == 1 ? "" : "s") saved on this Mac. Most recent: \(latest.createdAt.formatted(date: .abbreviated, time: .shortened)).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button("Restore Previous Layout…") {
                confirmingRestore = true
            }
            .controlSize(.small)
            .accessibilityLabel("Restore previous widget layout")
            .accessibilityHint("Replaces the current widgets with the most recently saved earlier layout")
        }
        .accessibilityElement(children: .contain)
    }
}
