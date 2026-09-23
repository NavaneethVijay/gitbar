import SwiftUI

/// System Settings-style sidebar + detail: General, then one row per
/// `ProviderKind` — available ones expand to their accounts and "Add
/// Account", the rest show "Soon". A new provider module appears automatically.
struct SettingsView: View {
    @ObservedObject var accountStore: AccountStore
    @ObservedObject var favoriteStore: FavoriteRepoStore
    let updater: AppUpdater

    private enum Selection: Hashable {
        case general
        case account(UUID)
        case addAccount(ProviderKind)
        case comingSoon(ProviderKind)
    }

    @State private var selection: Selection?
    @State private var expandedProviders = Set(ProviderKind.allCases)

    var body: some View {
        NavigationSplitView {
            sidebar
                // Like System Settings: a fixed sidebar, no collapse toggle.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .onAppear {
            if selection == nil { selection = defaultSelection }
        }
        .onChange(of: accountStore.accounts.map(\.id)) { _, ids in
            // The selected account was just disconnected.
            if case .account(let id) = selection, !ids.contains(id) {
                selection = defaultSelection
            }
        }
    }

    private var defaultSelection: Selection {
        if let account = accountStore.accounts.first { return .account(account.id) }
        return .addAccount(ProviderKind.allCases.first(where: \.isAvailable) ?? .github)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Label("General", systemImage: "gearshape")
                .tag(Selection.general)
            // Providers as full rows with accounts nested beneath (Internet Accounts style).
            Section("Accounts") {
                ForEach(ProviderKind.allCases) { provider in
                    if provider.isAvailable {
                        DisclosureGroup(isExpanded: expandedBinding(provider)) {
                            ForEach(accountStore.accounts(for: provider)) { account in
                                AccountRow(account: account).tag(Selection.account(account.id))
                            }
                            Label("Add Account", systemImage: "plus.circle")
                                .tag(Selection.addAccount(provider))
                        } label: {
                            ProviderRow(provider: provider)
                        }
                    } else {
                        ProviderRow(provider: provider, isComingSoon: true)
                            .tag(Selection.comingSoon(provider))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func expandedBinding(_ provider: ProviderKind) -> Binding<Bool> {
        Binding(
            get: { expandedProviders.contains(provider) },
            set: { isExpanded in
                if isExpanded { expandedProviders.insert(provider) } else { expandedProviders.remove(provider) }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsView(updater: updater)
        case .account(let id):
            if let account = accountStore.accounts.first(where: { $0.id == id }) {
                AccountDetailView(account: account, accountStore: accountStore, favoriteStore: favoriteStore)
                    .id(account.id)
            }
        case .addAccount(let provider):
            AddAccountView(provider: provider, accountStore: accountStore) { newAccount in
                selection = .account(newAccount.id)
            }
            .id(provider)
        case .none:
            EmptyView()
        case .comingSoon(let provider):
            ContentUnavailableView {
                Label {
                    Text(provider.displayName)
                } icon: {
                    ProviderLogoView(provider: provider, size: 44)
                }
            } description: {
                Text("\(provider.displayName) support is coming soon.")
            }
            .navigationTitle(provider.displayName)
        }
    }
}

// MARK: - Sidebar rows

private struct AccountRow: View {
    let account: Account
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 0) {
                Text(account.displayName).lineLimit(1)
                // Only worth the space for a self-hosted instance.
                if !account.isCloud {
                    Text(account.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Avatar(url: account.avatarURL, size: 18)
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderKind
    var isComingSoon = false

    var body: some View {
        Label {
            Text(provider.displayName)
                .foregroundStyle(isComingSoon ? .secondary : .primary)
        } icon: {
            ProviderLogoView(provider: provider, size: 16)
        }
        .badge(isComingSoon ? Text("Soon") : nil)
    }
}

/// Brand marks from Assets.xcassets (Simple Icons, see NOTICE.md) as template
/// images: GitHub's follows the label color, the others keep brand colors.
extension ProviderKind {
    var logoAssetName: String { "logo-\(rawValue)" }

    var logoTint: Color {
        switch self {
        case .github: return .primary
        case .gitlab: return Color(hex: 0xFC6D26)
        case .bitbucket: return Color(hex: 0x2684FF)
        }
    }
}

struct ProviderLogoView: View {
    let provider: ProviderKind
    let size: CGFloat

    var body: some View {
        Image(provider.logoAssetName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(provider.logoTint)
            .frame(width: size, height: size)
    }
}

private struct Avatar: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// "Cloud · github.com" / "Self-hosted · github.example.com".
private struct HostingBadge: View {
    let account: Account

    var body: some View {
        Label {
            Text(account.isCloud ? "Cloud · \(account.host)" : "Self-hosted · \(account.host)")
        } icon: {
            Image(systemName: account.isCloud ? "cloud" : "server.rack")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary))
        .help(account.isCloud ? account.provider.cloudName : account.provider.selfHostedName)
    }
}

// MARK: - Add account

private struct AddAccountView: View {
    let provider: ProviderKind
    @ObservedObject var accountStore: AccountStore
    var onAdded: (Account) -> Void

    private enum Hosting: Hashable { case cloud, selfHosted }

    @State private var hosting: Hosting = .cloud
    /// Only used — and required — when self-hosted.
    @State private var host: String = ""
    @State private var token: String = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var resolvedHost: String {
        hosting == .cloud ? provider.defaultHost : provider.normalizeHost(trimmedHost)
    }

    private var canConnect: Bool {
        !token.isEmpty && (hosting == .cloud || !trimmedHost.isEmpty)
    }

    /// Links the token page on whichever host is entered.
    private var footer: AttributedString {
        var text = "Paste a personal access token with at least read access to repos."
        if let url = provider.tokenHelpURL(host: resolvedHost) {
            let label = url.host.map { $0 + url.path } ?? url.absoluteString
            text += " Generate one at [\(label)](\(url.absoluteString))."
        }
        text += " Already-connected accounts stay put — this just adds another."
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    var body: some View {
        Form {
            Section {
                Picker("Hosting", selection: $hosting) {
                    Text("Cloud").tag(Hosting.cloud)
                    Text("Self-hosted").tag(Hosting.selfHosted)
                }
                .pickerStyle(.segmented)
                .disabled(isConnecting)

                if hosting == .selfHosted {
                    TextField("Server", text: $host, prompt: Text(provider.selfHostedExample))
                        .disabled(isConnecting)
                } else {
                    LabeledContent("Server", value: provider.defaultHost)
                }
            } header: {
                Text("Connect a \(provider.displayName) account")
            } footer: {
                Text(hosting == .cloud
                     ? "\(provider.cloudName) — the hosted service at \(provider.defaultHost)."
                     : "\(provider.selfHostedName) — your organization's own instance. Enter its address, e.g. \(provider.selfHostedExample).")
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Token", text: $token, prompt: Text(provider.tokenPlaceholder))
                    .disabled(isConnecting)
                    .onSubmit(connect)
            } footer: {
                Text(footer)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add \(provider.displayName) Account")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Connect", action: connect)
                        .disabled(!canConnect)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func connect() {
        guard canConnect, !isConnecting else { return }
        errorMessage = nil
        isConnecting = true
        let tokenToTry = token
        let hostToTry = resolvedHost
        Task {
            do {
                let account = try await accountStore.addAccount(provider: provider, host: hostToTry, token: tokenToTry)
                token = ""
                onAdded(account)
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

// MARK: - One connected account: its info + its own repo picker

private struct AccountDetailView: View {
    let account: Account
    @ObservedObject var accountStore: AccountStore
    @ObservedObject var favoriteStore: FavoriteRepoStore

    @State private var repos: [RemoteRepo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var toast: String?
    @State private var toastDismissal: Task<Void, Never>?

    private var filteredRepos: [RemoteRepo] {
        guard !searchText.isEmpty else { return repos }
        return repos.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Form {
            Section {
                accountHeader
            }

            Section {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if repos.isEmpty, isLoading {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                } else if !searchText.isEmpty, filteredRepos.isEmpty {
                    Text("No repositories match \u{201C}\(searchText)\u{201D}.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredRepos) { repo in
                    Toggle(isOn: Binding(
                        get: { favoriteStore.isFavorite(repo.path, for: account.id) },
                        set: { _ in favoriteStore.toggle(repo.path, for: account.id) }
                    )) {
                        HStack(spacing: 6) {
                            Text(repo.path)
                            if repo.isPrivate {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Favorite Repositories")
            } footer: {
                Text("Favorited repos from @\(account.login) show up in the menu bar popover.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(account.displayName)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search repositories")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { refresh(announce: true) }
                    .disabled(isLoading)
                    .help("Reload repositories")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .floatingCapsule()
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            if repos.isEmpty { refresh() }
        }
        .onDisappear { toastDismissal?.cancel() }
    }

    private func showToast(_ message: String) {
        toastDismissal?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = message }
        toastDismissal = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { toast = nil }
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 12) {
            Avatar(url: account.avatarURL, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.headline)
                Text("@\(account.login)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HostingBadge(account: account)
                    .padding(.top, 2)
            }

            Spacer()

            Button("Disconnect", role: .destructive) {
                favoriteStore.clearFavorites(for: account.id)
                accountStore.removeAccount(account)
            }
        }
    }

    /// Only the toolbar button announces; the silent first load shows no toast.
    private func refresh(announce: Bool = false) {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                repos = try await accountStore.repositories(for: account)
                if announce {
                    showToast("Refreshed \(repos.count) repositories")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
