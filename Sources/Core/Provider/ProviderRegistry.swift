import Foundation

/// The one place that knows which module backs which `ProviderKind`.
/// Adding a provider = one case here plus its module under
/// `Sources/Providers/`; nothing else in the app switches on the kind to
/// reach provider code.
enum ProviderRegistry {
    static func isAvailable(_ kind: ProviderKind) -> Bool {
        switch kind {
        case .github: return true
        case .gitlab, .bitbucket: return false
        }
    }

    static func makeClient(kind: ProviderKind, host: String, token: String) throws -> any ProviderClient {
        switch kind {
        case .github: return GitHubClient(host: host, token: token)
        case .gitlab, .bitbucket: throw ProviderError.unsupported(kind)
        }
    }
}
