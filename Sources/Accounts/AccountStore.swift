import Foundation

/// Connected accounts, across every provider — metadata persisted to
/// `UserDefaults`, tokens only ever in `KeychainStore`.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []

    private static let defaultsKey = "gitbar.accounts"

    init() {
        load()
    }

    func accounts(for provider: ProviderKind) -> [Account] {
        accounts.filter { $0.provider == provider }
    }

    /// Validates before storing. Re-adding an existing account (same provider,
    /// host and login) just replaces its — possibly rotated — token.
    @discardableResult
    func addAccount(provider: ProviderKind, host rawHost: String, token: String) async throws -> Account {
        let host = provider.normalizeHost(rawHost)
        let client = try ProviderRegistry.makeClient(kind: provider, host: host, token: token)
        let profile = try await client.validate()
        // Best-effort: an account works without it; Settings can re-check.
        let access = try? await client.tokenAccess()
        if let index = accounts.firstIndex(where: {
            $0.provider == provider && $0.host == host && $0.login == profile.login
        }) {
            KeychainStore.store(token: token, for: accounts[index].id.uuidString)
            accounts[index].access = access
            persist()
            return accounts[index]
        }
        let account = Account(id: UUID(), provider: provider, host: host, login: profile.login,
                              name: profile.name, avatarURL: profile.avatarURL, access: access)
        KeychainStore.store(token: token, for: account.id.uuidString)
        accounts.append(account)
        persist()
        return account
    }

    /// Re-reads what the token can do (e.g. after editing its scopes on the
    /// provider's site) — and fills it in for accounts added before this existed.
    @discardableResult
    func refreshAccess(for account: Account) async -> TokenAccess? {
        guard let client = client(for: account), let access = try? await client.tokenAccess(),
              let index = accounts.firstIndex(where: { $0.id == account.id }) else { return nil }
        if accounts[index].access != access {
            accounts[index].access = access
            persist()
        }
        return access
    }

    /// Checks every account that hasn't been checked yet — once at launch.
    func refreshMissingAccess() async {
        for account in accounts where account.access == nil {
            await refreshAccess(for: account)
        }
    }

    func removeAccount(_ account: Account) {
        KeychainStore.delete(for: account.id.uuidString)
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    /// A fresh client, or `nil` without a token or module. Keep the instance
    /// for repeated requests — rate-limit and ETag state live on it.
    func client(for account: Account) -> (any ProviderClient)? {
        guard let token = KeychainStore.read(for: account.id.uuidString) else { return nil }
        return try? ProviderRegistry.makeClient(kind: account.provider, host: account.host, token: token)
    }

    /// Every repo the account can see — the Settings favorites picker.
    func repositories(for account: Account) async throws -> [RemoteRepo] {
        guard let client = client(for: account) else { throw ProviderError.accountUnavailable }
        return try await client.repositories()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data)
        else { return }
        accounts = decoded
    }
}
