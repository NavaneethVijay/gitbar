// A PR in its own resizable window, outside the popover — same screen, same
// store, just room to read a long description or thread.
import AppKit
import SwiftUI

/// One window per PR: opening a PR that already has one brings it forward.
@MainActor
final class PRWindowManager: NSObject, NSWindowDelegate {
    private let repoStore: LiveRepoStore
    private var windows: [PRRef: NSWindow] = [:]

    init(repoStore: LiveRepoStore) {
        self.repoStore = repoStore
    }

    /// PRs with a window open — the background refresh keeps them fresh.
    var openPullRequests: [PRRef] { Array(windows.keys) }

    func open(repoID: RepoRef, prID: Int) {
        let key = PRRef(repo: repoID, number: prID)
        // An accessory app must activate first, or the window opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: PRWindowContent(repoStore: repoStore, repoID: repoID, prID: prID))
        // The window owns its size; the content fills it.
        hosting.sizingOptions = []
        // SwiftUI's toolbar and navigation title/subtitle go into the
        // unified titlebar — glass buttons beside the traffic lights, like
        // the Settings window and System Settings.
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "\(repoID.path) \(repoStore.provider(for: repoID).formatNumber(prID))"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 460, height: 480)
        window.setContentSize(NSSize(width: 680, height: 780))
        if let previous = windows.values.first(where: \.isVisible) {
            // Cascade from an existing PR window rather than stacking exactly on it.
            let topLeft = NSPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else {
            window.center()
        }
        window.delegate = self
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }
}

/// Looks the PR up live in the store, so it updates with every refresh; if a
/// refresh drops it from the loaded list (merged, closed), the last version
/// seen stays on screen rather than blanking the window.
private struct PRWindowContent: View {
    let repoStore: LiveRepoStore
    let repoID: RepoRef
    let prID: Int

    @State private var lastKnown: RepoPullRequest?

    private var livePR: RepoPullRequest? {
        repoStore.detailPullRequests[repoID]?.first { $0.id == prID }
    }

    var body: some View {
        Group {
            if let pr = livePR ?? lastKnown {
                PRDetailScreen(repoStore: repoStore, repoID: repoID, pr: pr, isWindowed: true)
            } else {
                // Still gets a toolbar item: with none, SwiftUI drops the
                // toolbar and the traffic lights fall back to a plain titlebar.
                ProgressView().controlSize(.small)
                    .frame(minWidth: 460, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                    .navigationTitle(repoStore.provider(for: repoID).formatNumber(prID))
                    .navigationSubtitle(repoID.path)
                    .toolbar {
                        ToolbarItem {
                            Button("Refresh", systemImage: "arrow.clockwise") {}
                                .disabled(true)
                        }
                    }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: livePR, initial: true) { _, pr in
            if let pr { lastKnown = pr }
        }
    }
}
