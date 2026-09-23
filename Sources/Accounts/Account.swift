import Foundation

/// One connected account on one provider/host — metadata only, never the
/// token (that lives in `KeychainStore`, keyed by `id.uuidString`).
struct Account: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var provider: ProviderKind
    /// Normalized host ("github.com", or a self-hosted instance) — see
    /// `ProviderKind.normalizeHost`.
    var host: String
    var login: String
    var name: String?
    var avatarURL: URL?
    /// What the token can do, from the last check (`nil` until checked).
    var access: TokenAccess?

    /// On the provider's own hosted service, rather than a self-hosted instance.
    var isCloud: Bool { host == provider.defaultHost }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return login
    }

    init(id: UUID, provider: ProviderKind, host: String, login: String, name: String?, avatarURL: URL?, access: TokenAccess? = nil) {
        self.id = id
        self.provider = provider
        self.host = host
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.access = access
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, host, login, name, avatarURL, access
    }

    /// Accounts saved before providers existed have no `provider`/`host` —
    /// they were all github.com, so that's what they decode as. No
    /// re-connect needed; the Keychain token is keyed by the same `id`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decodeIfPresent(ProviderKind.self, forKey: .provider) ?? .github
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? provider.defaultHost
        login = try container.decode(String.self, forKey: .login)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        access = try container.decodeIfPresent(TokenAccess.self, forKey: .access)
    }
}
