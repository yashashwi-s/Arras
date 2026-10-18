import Foundation

/// Every UI test owns a UUID directory. Only Store Debug grants its runner access
/// to the dedicated shared fixture root; production entitlements exclude it.
func uiTestStorage(prefix: String) -> URL {
    #if ARRAS_APP_STORE
    let parent = URL(fileURLWithPath: "/private/tmp/ArrasAppStoreUITests", isDirectory: true)
    #else
    let parent = FileManager.default.temporaryDirectory
    #endif
    return parent.appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
}
