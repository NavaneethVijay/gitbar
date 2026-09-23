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
        let profile = try await ProviderRegistry.makeClient(kind: provider, host: host, token: token).validate()
        if let existing = accounts.first(where: {
            $0.provider == provider && $0.host == host && $0.login == profile.login
        }) {
            KeychainStore.store(token: token, for: existing.id.uuidString)
            return existing
        }
        let account = Account(id: UUID(), provider: provider, host: host, login: profile.login,
                              name: profile.name, avatarURL: profile.avatarURL)
        KeychainStore.store(token: token, for: account.id.uuidString)
        accounts.append(account)
        persist()
        return account
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
