import AppKit

/// App-wide background polling (General → "Refresh every", default 5 min).
/// Cheap: the store throttles, and unchanged responses come back as ETag 304s.
/// Skips ticks in Low Power Mode; refreshes a few seconds after wake, once
/// the network is back.
@MainActor
final class RefreshScheduler {
    static let intervalKey = "gitbar.refreshInterval"
    static let defaultInterval: TimeInterval = 300
    /// Stored for "Manually" — no background polling at all.
    static let manualInterval: TimeInterval = -1

    /// Unset reads back as 0 → the default.
    static var interval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: intervalKey)
        return stored == 0 ? defaultInterval : stored
    }

    private let tick: () async -> Void
    private var loop: Task<Void, Never>?
    private var activeInterval: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    init(tick: @escaping () async -> Void) {
        self.tick = tick
        restart()

        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.interval != self.activeInterval else { return }
                self.restart()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restart(initialDelay: 5)
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// `initialDelay` fires one tick soon (after wake) before settling into
    /// the regular interval.
    private func restart(initialDelay: TimeInterval? = nil) {
        loop?.cancel()
        activeInterval = Self.interval
        let interval = activeInterval
        guard interval > 0 else { return }

        loop = Task { [weak self] in
            var delay = initialDelay ?? interval
            while !Task.isCancelled {
                // Tolerance lets macOS coalesce this wakeup with other apps'
                // (fewer CPU wakes on battery); a few seconds either way is fine.
                try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(max(1, delay * 0.1)))
                guard !Task.isCancelled, let self else { return }
                if !ProcessInfo.processInfo.isLowPowerModeEnabled {
                    await self.tick()
                }
                delay = interval
            }
        }
    }
}
