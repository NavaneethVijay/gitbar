import AppKit
import SwiftUI

/// The menu bar icon and its popover — stock AppKit, so show/close and
/// outside-click dismissal come from the system.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let repoStore: LiveRepoStore
    private let notificationStore: NotificationStore
    private let model: MenuViewModel
    private let plainIcon: NSImage? = StatusItemController.makeIcon(badged: false)
    private let badgedIcon: NSImage? = StatusItemController.makeIcon(badged: true)
    private var appearanceObservation: NSKeyValueObservation?
    private var refreshScheduler: RefreshScheduler?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The same store instances the Settings window edits — one source of truth.
        let settings = SettingsWindowController.shared
        repoStore = LiveRepoStore(accountStore: settings.accountStore, favoriteStore: settings.favoriteStore)
        notificationStore = settings.notificationStore
        model = MenuViewModel(repoStore: repoStore, notificationStore: notificationStore)
        super.init()

        Task { await repoStore.refresh() }
        Task {
            // Accounts added before token checks existed get checked once.
            await settings.accountStore.refreshMissingAccess()
            notificationStore.startPolling()
        }
        notificationStore.alerter.onOpen = { [weak self] entryID, url in
            self?.showPopover()
            self?.model.openNotification(id: entryID, fallbackURL: url)
        }

        if let button = statusItem.button {
            button.image = plainIcon
            button.action = #selector(togglePopover)
            button.target = self
        }
        observeUnreadBadge()

        let hosting = NSHostingController(rootView: MenuContentView(model: model))
        // Keeps `preferredContentSize` in sync from the first frame; otherwise
        // the popover positions itself from a stale size, away from the icon.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        popover.behavior = .transient
        popover.delegate = self
        // Left alone, the popover inherits the menu bar's appearance (dark over
        // a dark wallpaper whatever the app theme); follow the app's instead.
        popover.appearance = NSApp.effectiveAppearance

        refreshScheduler = RefreshScheduler { [weak self] in
            await self?.backgroundRefresh()
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            MainActor.assumeIsolated {
                self?.popover.appearance = app.effectiveAppearance
            }
        }
    }

    /// The repo list, plus the visible repo/PR screen while the popover is open.
    private func backgroundRefresh() async {
        if popover.isShown {
            repoStore.refreshVisibleScreen(repoID: model.selectedRepoID, prID: model.selectedPullRequestID)
        }
        await repoStore.refresh()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        // No navigation reset: it reopens where it was left. An accessory
        // app must activate first or the popover can layer behind others.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Both throttled — no-ops if they refreshed recently.
        Task { await repoStore.refresh() }
        Task { await notificationStore.refresh() }
    }

    // MARK: - Menu bar icon

    /// Re-arms after every change: `withObservationTracking` fires once.
    private func observeUnreadBadge() {
        withObservationTracking {
            statusItem.button?.image = notificationStore.unreadCount > 0 ? badgedIcon : plainIcon
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeUnreadBadge() }
        }
    }

    /// Template image (macOS tints it like its own icons). The unread badge is
    /// a dot cut out of the top-right corner, so it reads at any tint.
    private static func makeIcon(badged: Bool) -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon") else { return nil }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            guard badged else { return true }
            let center = NSPoint(x: rect.maxX - 3.4, y: rect.maxY - 3.4)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: center.x - 4.4, y: center.y - 4.4, width: 8.8, height: 8.8)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badged ? "gitbar — unread notifications" : "gitbar"
        return image
    }

    /// No first responder at show time, so no stray focus ring. Done here
    /// rather than after `show()`: AppKit reassigns one once the window is key.
    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }
}
