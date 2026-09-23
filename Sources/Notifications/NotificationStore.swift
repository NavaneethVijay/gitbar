import AppKit
import Foundation
import Observation

/// The unread inbox across every account whose provider and token can read
/// notifications. Polls on its own cadence — the provider's requested poll
/// interval (GitHub: 60s), never faster — and unchanged inboxes come back as
/// ETag 304s, so polling is effectively free. Raises a macOS alert only for
/// threads that are new or newly updated since the last one it alerted on.
@MainActor
@Observable
final class NotificationStore {
    struct Entry: Identifiable, Equatable, Sendable {
        let accountID: UUID
        let item: InboxItem
        var id: String { "\(accountID.uuidString)|\(item.id)" }
        var repo: RepoRef { RepoRef(accountID: accountID, path: item.repoPath) }
    }

    /// Unread threads, newest first.
    private(set) var entries: [Entry] = []
    private(set) var isLoading = false
    /// Accounts whose token can't read notifications — for the inbox's
    /// explanation, and Settings.
    private(set) var unsupportedAccountIDs: Set<UUID> = []
    private(set) var lastError: String?

    var unreadCount: Int { entries.count }

    func unreadCount(for repo: RepoRef) -> Int {
        entries.reduce(0) { $0 + ($1.repo == repo ? 1 : 0) }
    }

    @ObservationIgnored let alerter = NotificationAlerter()
    @ObservationIgnored private let accountStore: AccountStore
    @ObservationIgnored private var clientCache: [UUID: any ProviderClient] = [:]
    @ObservationIgnored private var itemsByAccount: [UUID: [InboxItem]] = [:]
    @ObservationIgnored private var nextPollAt: [UUID: Date] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private static let minimumPollInterval: TimeInterval = 60
    /// Thread id → the `updatedAt` last alerted on, so nothing alerts twice.
    private static let seenKey = "gitbar.notifications.seen"
    /// Accounts whose inbox has been seen once: their first fetch sets a
    /// baseline silently instead of alerting on the whole backlog.
    private static let baselinedKey = "gitbar.notifications.baselined"

    init(accountStore: AccountStore) {
        self.accountStore = accountStore
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.minimumPollInterval), tolerance: .seconds(10))
            }
        }
    }

    /// Polls every eligible account whose poll interval has elapsed.
    /// `force` (a manual refresh, a settings change) ignores the interval.
    func refresh(force: Bool = false) async {
        if let inFlight = refreshTask {
            await inFlight.value
            return
        }
        let task = Task { await performRefresh(force: force) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh(force: Bool) async {
        guard NotificationSettings.isEnabled else {
            clearAll()
            return
        }
        if !force, ProcessInfo.processInfo.isLowPowerModeEnabled, !entries.isEmpty { return }

        let accounts = accountStore.accounts
        let liveIDs = Set(accounts.map(\.id))
        itemsByAccount = itemsByAccount.filter { liveIDs.contains($0.key) }

        var unsupported = unsupportedAccountIDs.intersection(liveIDs)
        var errors: [String] = []
        let now = Date()
        var didPoll = false

        for account in accounts {
            guard let client = client(for: account), client.capabilities.supportsNotifications,
                  account.access?.notifications != .no else {
                unsupported.insert(account.id)
                itemsByAccount[account.id] = nil
                continue
            }
            if !force, let next = nextPollAt[account.id], next > now { continue }

            if !didPoll { didPoll = true; assign(\.isLoading, true) }
            do {
                let fetch = try await client.notifications(participatingOnly: NotificationSettings.participatingOnly)
                unsupported.remove(account.id)
                itemsByAccount[account.id] = fetch.items.filter(\.isUnread)
                nextPollAt[account.id] = Date().addingTimeInterval(max(fetch.pollInterval ?? 0, Self.minimumPollInterval))
                alertIfNew(fetch.items.filter(\.isUnread), account: account)
            } catch ProviderError.forbidden {
                unsupported.insert(account.id)
                itemsByAccount[account.id] = nil
                // The token lost (or never had) access — re-read what it can do.
                Task { await accountStore.refreshAccess(for: account) }
            } catch {
                nextPollAt[account.id] = Date().addingTimeInterval(Self.minimumPollInterval)
                errors.append((error as? LocalizedError)?.errorDescription ?? "Couldn't load notifications.")
            }
        }

        assign(\.unsupportedAccountIDs, unsupported)
        assign(\.lastError, errors.first)
        publishEntries()
        if didPoll { assign(\.isLoading, false) }
    }

    // MARK: - Actions

    func entry(withID id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Optimistic: the thread leaves the inbox immediately; the provider
    /// call happens behind it (and the next poll corrects any failure).
    func markRead(_ entry: Entry) async {
        itemsByAccount[entry.accountID]?.removeAll { $0.id == entry.item.id }
        publishEntries()
        alerter.removeDelivered(entryIDs: [entry.id])
        guard let account = accountStore.accounts.first(where: { $0.id == entry.accountID }),
              let client = client(for: account) else { return }
        try? await client.markNotificationRead(id: entry.item.id)
    }

    func markAllRead() async {
        let accountIDs = Set(entries.map(\.accountID))
        alerter.removeDelivered(entryIDs: entries.map(\.id))
        for id in accountIDs { itemsByAccount[id] = [] }
        publishEntries()
        for account in accountStore.accounts where accountIDs.contains(account.id) {
            try? await client(for: account)?.markAllNotificationsRead()
        }
    }

    // MARK: - Internals

    private func client(for account: Account) -> (any ProviderClient)? {
        if let cached = clientCache[account.id] { return cached }
        guard let client = accountStore.client(for: account) else { return nil }
        clientCache[account.id] = client
        return client
    }

    private func clearAll() {
        itemsByAccount = [:]
        publishEntries()
        assign(\.isLoading, false)
    }

    private func publishEntries() {
        let all = itemsByAccount.flatMap { accountID, items in items.map { Entry(accountID: accountID, item: $0) } }
        assign(\.entries, all.sorted { $0.item.updatedAt > $1.item.updatedAt })
    }

    /// Alerts on threads that are new, or updated since last alerted —
    /// except on an account's first fetch, which only records a baseline.
    private func alertIfNew(_ items: [InboxItem], account: Account) {
        let defaults = UserDefaults.standard
        var seen = defaults.dictionary(forKey: Self.seenKey) as? [String: Double] ?? [:]
        var baselined = Set(defaults.stringArray(forKey: Self.baselinedKey) ?? [])
        let isBaseline = !baselined.contains(account.id.uuidString)
        let reasons = NotificationSettings.alertReasons
        let alertsOn = NotificationSettings.alertsEnabled && !isBaseline

        if alertsOn { alerter.requestAuthorizationIfNeeded() }
        for item in items {
            let entry = Entry(accountID: account.id, item: item)
            let stamp = item.updatedAt.timeIntervalSince1970
            if let last = seen[entry.id], last >= stamp { continue }
            seen[entry.id] = stamp
            if alertsOn, reasons.contains(item.reason) { alerter.post(entry) }
        }

        // Keep only this account's current threads plus other accounts' entries.
        let prefix = account.id.uuidString + "|"
        let current = Set(items.map { Entry(accountID: account.id, item: $0).id })
        seen = seen.filter { !$0.key.hasPrefix(prefix) || current.contains($0.key) }
        defaults.set(seen, forKey: Self.seenKey)
        if isBaseline {
            baselined.insert(account.id.uuidString)
            defaults.set(Array(baselined), forKey: Self.baselinedKey)
        }
    }

    /// Writes only when the value actually changed (see `LiveRepoStore.assign`).
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<NotificationStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
