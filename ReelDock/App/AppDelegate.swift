import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppModel?
    #if DEBUG
    private var debugDriver: DebugDriver?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit test host only needs the code, not windows or saved state.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = true
        let app = AppModel()
        self.app = app
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["REELDOCK_PROJECT_ROOT"], app.projectRootURL == nil {
            app.setProjectRoot(URL(fileURLWithPath: root, isDirectory: true))
        }
        #endif
        app.restoreSession()
        NSApp.activate()
        #if DEBUG
        debugDriver = DebugDriver(app: app)
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let app, app.controllers.isEmpty { app.restoreSession() }
        return true
    }

    /// Quitting during an import asks first, then lets the copy clean up its temporary file.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app, app.queue.isActive || app.transfers.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = app.queue.isActive ? "Quit and cancel the import?" : "Quit and cancel the copy?"
        alert.informativeText = "The file being copied will be discarded. Files already finished are safe."
        alert.addButton(withTitle: "Keep Copying")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        app.queue.cancelAll()
        app.transfers.cancelAll()
        Task {
            while app.queue.isActive || app.transfers.isActive {
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        app?.saveNow()
    }

    @objc func showSettings(_ sender: Any?) {
        app?.showSettings()
    }

    @objc func newWindow(_ sender: Any?) {
        app?.addWindow()
    }

    /// Handles New Tab when no window is open to receive it.
    @IBAction func newWindowForTab(_ sender: Any?) {
        app?.addWindow()
    }
}
