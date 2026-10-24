import AppKit

struct Constants {
    static let appName = "Arras"
    static let repositoryURL = URL(string: "https://github.com/yashashwi-s/Arras")!
    #if !ARRAS_APP_STORE
    static let supportPurchaseURL = URL(string: "https://apps.apple.com/app/id6824271927")!
    #endif

    /// Keep the SwiftUI root, its tab content, and the AppKit window constraint aligned so the
    /// window cannot be resized below the layout's actual minimum.
    static let settingsMinimumWidth: CGFloat = 460
    static let settingsMinimumHeight: CGFloat = 480

    /// Sheets attach below the Settings title bar. Their scrollable body must
    /// shrink before their footer runs under the Dock on a short display.
    @MainActor
    static func editorHeight(_ preferred: CGFloat) -> CGFloat {
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let screen = parent?.screen ?? NSScreen.main else { return preferred }
        let top = parent.map { $0.convertToScreen($0.contentLayoutRect).maxY } ?? screen.visibleFrame.maxY
        return editorHeight(preferred, visibleFrame: screen.visibleFrame, parentContentTop: top)
    }

    static func editorHeight(_ preferred: CGFloat, visibleFrame: CGRect, parentContentTop: CGFloat) -> CGFloat {
        let available = min(visibleFrame.height - 140, min(parentContentTop, visibleFrame.maxY) - visibleFrame.minY - 24)
        return min(preferred, max(300, available))
    }

    /// The bundle identifier deliberately still says "tableau". It is what the updater
    /// checks a downloaded build against, and what every UserDefaults key is scoped to —
    /// changing it on a rename would reject the next update and silently reset everyone's
    /// settings. Same reasoning keeps the Application Support directory named PhotoWidget.

    /// Marketing version from the bundle. Read rather than hardcoded so the UI
    /// can never drift from what was actually built.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
