import AppKit
import Sparkle

/// Sparkle owns checking, verifying, replacing, and relaunching.
final class UpdateController: NSObject, NSMenuItemValidation {
    static let shared = UpdateController()

    #if DEBUG && !UPDATER_TEST
    // A build from Xcode has the release's bundle ID and must never be replaced by a download.
    private let controller: SPUStandardUpdaterController? = nil
    #else
    private let controller: SPUStandardUpdaterController? = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    #if UPDATER_TEST
    func debugCheckInBackground() -> String {
        guard let updater = controller?.updater else { return "no updater" }
        updater.checkForUpdatesInBackground()
        return "version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "") feed=\(updater.feedURL?.absoluteString ?? "nil") canCheck=\(updater.canCheckForUpdates)"
    }
    #endif
}
