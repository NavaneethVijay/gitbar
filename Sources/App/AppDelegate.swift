import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock tile or ⌘-Tab entry.
        NSApp.setActivationPolicy(.accessory)
        AppearanceMode.stored.apply()
        statusItemController = StatusItemController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
