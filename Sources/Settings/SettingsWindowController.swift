import AppKit
import SwiftUI

/// Singleton, so "Manage this app…" brings the existing window forward.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    // Shared with `StatusItemController`'s store, so Settings edits show up
    // in the popover immediately.
    let accountStore = AccountStore()
    let favoriteStore = FavoriteRepoStore()
    let updater = AppUpdater()
    private(set) lazy var notificationStore = NotificationStore(accountStore: accountStore)

    private convenience init() {
        self.init(window: nil)

        let hosting = NSHostingController(
            rootView: SettingsView(accountStore: accountStore, favoriteStore: favoriteStore, updater: updater,
                                   notificationStore: notificationStore, navigator: navigator)
        )
        // The window owns its size: with the default options, switching detail
        // screens in the NavigationSplitView wedged layout and blanked the window.
        hosting.sizingOptions = []
        // Puts SwiftUI toolbars, search and titles in the unified titlebar.
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "gitbar Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 460)
        window.setContentSize(NSSize(width: 780, height: 540))
        window.center()
        self.window = window
    }

    /// Asks the open Settings view to switch pages (the main window's
    /// "Account Settings…", "Add Account…").
    let navigator = SettingsNavigator()

    func show() {
        // An accessory app must activate first, or this opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func show(_ selection: SettingsView.Selection) {
        navigator.request = selection
        show()
    }

    func showAccount(_ id: UUID) { show(.account(id)) }

    /// Add Account for the first provider that has a module.
    func showAddAccount() {
        show(.addAccount(ProviderKind.allCases.first(where: \.isAvailable) ?? .github))
    }
}

@MainActor
final class SettingsNavigator: ObservableObject {
    @Published var request: SettingsView.Selection?
}
