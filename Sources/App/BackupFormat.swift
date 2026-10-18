import Foundation
import UniformTypeIdentifiers

/// File extensions for the layout bundle.
///
/// New backups are written as `.arras`. `.tableau` is still accepted on import: the format
/// did not change with the rename, and refusing a file somebody exported last week because
/// the app has a different name now would be a poor trade for consistency.
enum BackupFormat {
    static let currentExtension = "arras"
    static let legacyExtension = "tableau"
    static let typeIdentifier = "com.yashashwi.arras.layout"

    /// One declared type covers both the current extension and pre-rename backups. Keeping this
    /// in code as well as the app's Info.plist makes panel filtering and Finder-open routing use
    /// the same contract.
    static var layoutType: UTType {
        UTType(exportedAs: typeIdentifier, conformingTo: .data)
    }

    static var exportType: UTType {
        layoutType
    }

    static var importTypes: [UTType] {
        var types = [layoutType]
        types.append(contentsOf: [currentExtension, legacyExtension].compactMap { UTType(filenameExtension: $0) })
        types.append(.data)
        return types
    }

    static func isArchiveURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == currentExtension || ext == legacyExtension
    }
}
