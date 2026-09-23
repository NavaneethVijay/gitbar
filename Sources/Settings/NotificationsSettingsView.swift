import AppKit
import SwiftUI
import UserNotifications

/// Settings → Notifications: what shows in the inbox, what raises a macOS
/// alert, and which accounts can read notifications at all.
struct NotificationsSettingsView: View {
    @ObservedObject var accountStore: AccountStore
    let notificationStore: NotificationStore

    @AppStorage(NotificationSettings.enabledKey) private var enabled = true
    @AppStorage(NotificationSettings.participatingOnlyKey) private var participatingOnly = true
    @AppStorage(NotificationSettings.alertsKey) private var alertsEnabled = true
    /// Mirror of the stored reason set, so toggles redraw.
    @State private var alertReasons = NotificationSettings.alertReasons
    @State private var permission: UNAuthorizationStatus = .notDetermined

    /// The reasons worth a toggle, most actionable first.
    private static let reasons: [InboxItem.Reason] = [
        .reviewRequested, .mention, .teamMention, .assign, .comment,
        .stateChange, .ciActivity, .author, .securityAlert, .subscribed, .manual,
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: $enabled)
                Toggle("Only threads I'm participating in", isOn: $participatingOnly)
                    .disabled(!enabled)
            } footer: {
                Text("Participating: review requests, mentions, assignments and threads you've commented on or opened. Off: everything you watch, too.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show macOS alerts for new notifications", isOn: $alertsEnabled)
                    .disabled(!enabled)
                if permission == .denied {
                    HStack {
                        Label("Alerts are turned off for gitbar in System Settings", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open…") { openSystemNotificationSettings() }
                    }
                }
                ForEach(Self.reasons, id: \.self) { reason in
                    Toggle(reason.label, isOn: Binding(
                        get: { alertReasons.contains(reason) },
                        set: { isOn in
                            NotificationSettings.setAlert(reason, enabled: isOn)
                            alertReasons = NotificationSettings.alertReasons
                        }
                    ))
                    .disabled(!enabled || !alertsEnabled)
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Alerts only fire for new or updated threads. Everything still appears in the inbox.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if accountStore.accounts.isEmpty {
                    Text("No accounts connected.").foregroundStyle(.secondary)
                }
                ForEach(accountStore.accounts) { account in
                    LabeledContent {
                        accountStatus(account)
                    } label: {
                        Text(account.displayName)
                        Text("\(account.provider.displayName) · @\(account.login)")
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("GitHub needs a classic token with the notifications (or repo) scope — fine-grained tokens can't read notifications.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .task { permission = await notificationStore.alerter.authorizationStatus() }
        .onChange(of: enabled) { _, _ in Task { await notificationStore.refresh(force: true) } }
        .onChange(of: participatingOnly) { _, _ in Task { await notificationStore.refresh(force: true) } }
        .onChange(of: alertsEnabled) { _, isOn in
            if isOn { notificationStore.alerter.requestAuthorizationIfNeeded() }
        }
        // Catch a permission change made in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { permission = await notificationStore.alerter.authorizationStatus() }
        }
    }

    @ViewBuilder
    private func accountStatus(_ account: Account) -> some View {
        switch account.access?.notifications {
        case .yes?:
            Label("Supported", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .no?:
            Label("Token can't read them", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown?, nil:
            Label("Unknown", systemImage: "questionmark.circle.fill").foregroundStyle(.orange)
        }
    }

    private func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
