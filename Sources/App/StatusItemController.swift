import AppKit
import SwiftUI

/// The menu bar icon and its popover — stock AppKit, so show/close and
/// outside-click dismissal come from the system.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let repoStore: LiveRepoStore
    private let model: MenuViewModel
    private var appearanceObservation: NSKeyValueObservation?
    private var refreshScheduler: RefreshScheduler?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The same store instances the Settings window edits — one source of truth.
        let settings = SettingsWindowController.shared
        repoStore = LiveRepoStore(accountStore: settings.accountStore, favoriteStore: settings.favoriteStore)
        model = MenuViewModel(repoStore: repoStore)
        super.init()

        Task { await repoStore.refresh() }

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "chevron.left.forwardslash.chevron.right",
                accessibilityDescription: "gitbar"
            )
            button.action = #selector(togglePopover)
            button.target = self
        }

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
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // No navigation reset: it reopens where it was left. An accessory
            // app must activate first or the popover can layer behind others.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Throttled — a no-op if something refreshed in the last minute.
            Task { await repoStore.refresh() }
        }
    }

    /// No first responder at show time, so no stray focus ring. Done here
    /// rather than after `show()`: AppKit reassigns one once the window is key.
    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }
}
