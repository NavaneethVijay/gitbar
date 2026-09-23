import Foundation

/// Notification preferences (Settings → Notifications), in `UserDefaults`.
enum NotificationSettings {
    static let enabledKey = "gitbar.notifications.enabled"
    static let participatingOnlyKey = "gitbar.notifications.participatingOnly"
    static let alertsKey = "gitbar.notifications.alerts"
    static let alertReasonsKey = "gitbar.notifications.alertReasons"

    /// Reasons that raise a macOS alert by default — the ones asking you to act.
    static let defaultAlertReasons: [InboxItem.Reason] = [.reviewRequested, .mention, .teamMention, .assign]

    static var isEnabled: Bool { bool(enabledKey, default: true) }
    /// Only threads you're directly involved in (GitHub's `participating`).
    static var participatingOnly: Bool { bool(participatingOnlyKey, default: true) }
    static var alertsEnabled: Bool { bool(alertsKey, default: true) }

    static var alertReasons: Set<InboxItem.Reason> {
        guard let raw = UserDefaults.standard.stringArray(forKey: alertReasonsKey) else {
            return Set(defaultAlertReasons)
        }
        return Set(raw.compactMap(InboxItem.Reason.init(rawValue:)))
    }

    static func setAlert(_ reason: InboxItem.Reason, enabled: Bool) {
        var reasons = alertReasons
        if enabled { reasons.insert(reason) } else { reasons.remove(reason) }
        UserDefaults.standard.set(reasons.map(\.rawValue).sorted(), forKey: alertReasonsKey)
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

extension InboxItem.Reason {
    var label: String {
        switch self {
        case .reviewRequested: return "Review requested"
        case .mention: return "Mentioned"
        case .teamMention: return "Team mentioned"
        case .assign: return "Assigned"
        case .author: return "Your activity"
        case .comment: return "Commented"
        case .ciActivity: return "CI activity"
        case .stateChange: return "State changed"
        case .subscribed: return "Watching"
        case .manual: return "Subscribed"
        case .securityAlert: return "Security alert"
        case .other: return "Other"
        }
    }
}
