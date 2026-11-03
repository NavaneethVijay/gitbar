import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock tile or ⌘-Tab entry.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()
        AppearanceMode.stored.apply()
        statusItemController = StatusItemController()
        observeWindowsForDockPresence()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with every window minimized brings them back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in Self.appWindows() {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    // MARK: - Dock presence

    /// Menu bar only while just the popover is in use; a Dock icon (and
    /// ⌘-Tab, and the app's own menu bar) while a real window — Settings or
    /// a PR window — is open, so it can be brought back from behind other
    /// apps. Back to menu-bar-only once the last one closes.
    private func observeWindowsForDockPresence() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A closing window is still visible during `willClose`.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.updateDockPresence() }
                }
            }
        }
    }

    private func updateDockPresence() {
        let wantsDock = !Self.appWindows().isEmpty
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if wantsDock {
            // Switching to .regular doesn't hand over the menu bar until the
            // app is (re)activated.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Titled, main-capable windows that are open (on screen or minimized
    /// to the Dock) — never the popover or the status item's own window.
    private static func appWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.styleMask.contains(.titled) && window.canBecomeMain
                && (window.isVisible || window.isMiniaturized)
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    /// Shown only while a window gives the app a Dock icon; the rest of the
    /// time (popover only, accessory app) it's invisible, but its key
    /// equivalents are what route ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z to the first
    /// responder — without it those keys do nothing in text views and fields,
    /// leaving only the context menu. Also ⌘W for PR windows and Settings.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide gitbar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit gitbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenuItem(title: "gitbar", menu: appMenu))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = edit.addItem(withTitle: "Paste and Match Style",
                                      action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(title: "Edit", menu: edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenuItem(title: "Window", menu: window))
        // AppKit lists the open windows (Settings, each PR) under it.
        NSApp.windowsMenu = window

        return main
    }

    private func submenuItem(title: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
