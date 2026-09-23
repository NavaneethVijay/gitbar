import AppKit
import ServiceManagement
import SwiftUI

/// System / Light / Dark for the whole app — the Settings window and the
/// popover both follow `NSApp.appearance`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "gitbar.appearance"
    static let solidBackgroundKey = "gitbar.solidBackground"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static var stored: AppearanceMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppearanceMode.init) ?? .system
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var updater: AppUpdater

    @AppStorage(AppearanceMode.defaultsKey) private var appearance: AppearanceMode = .system
    @AppStorage(AppearanceMode.solidBackgroundKey) private var solidBackground = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(RefreshScheduler.intervalKey) private var refreshInterval: Double = RefreshScheduler.defaultInterval

    private static let refreshOptions: [(label: String, seconds: Double)] = [
        ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300),
        ("10 minutes", 600), ("15 minutes", 900), ("30 minutes", 1800),
        ("Manually", RefreshScheduler.manualInterval),
    ]

    // `SMAppService` is the source of truth, not a stored flag — the user
    // can also flip this in System Settings › General › Login Items.
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Solid background", isOn: reduceTransparency ? .constant(true) : $solidBackground)
                    .disabled(reduceTransparency)
            } header: {
                Text("Appearance")
            } footer: {
                Text(reduceTransparency
                     ? "On because Reduce transparency is enabled in System Settings › Accessibility › Display."
                     : "Replaces the translucent glass behind the menu with a solid color — lighter on the graphics card.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Refresh every", selection: $refreshInterval) {
                    ForEach(Self.refreshOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
            } header: {
                Text("Background Refresh")
            } footer: {
                Text("Only changed data is re-downloaded, so polling is cheap. Paused in Low Power Mode. \u{201C}Manually\u{201D} only refreshes when you open the menu.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
                    set: setOpenAtLogin
                ))
                if loginItemStatus == .requiresApproval {
                    HStack {
                        Label("Needs approval in System Settings", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemError {
                    Label(loginItemError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.automaticallyDownloadsUpdates = $0 }
                ))
                .disabled(!updater.automaticallyChecksForUpdates)
                LabeledContent("Last checked") {
                    if let date = updater.lastUpdateCheckDate {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Never")
                    }
                }
            } header: {
                Text("Updates")
            }

            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Author") {
                    Link("NavaneethVijay", destination: URL(string: "https://github.com/NavaneethVijay")!)
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .toolbar {
            ToolbarItem {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .onChange(of: appearance) { _, mode in mode.apply() }
        .onAppear { loginItemStatus = SMAppService.mainApp.status }
        // Catch changes made in System Settings while this window was away.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}
