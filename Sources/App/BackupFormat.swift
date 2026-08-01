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

    static var exportType: UTType {
        UTType(filenameExtension: currentExtension) ?? .data
    }

    static var importTypes: [UTType] {
        [currentExtension, legacyExtension].compactMap { UTType(filenameExtension: $0) } + [.data]
    }
}
