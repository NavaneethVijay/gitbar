import Foundation

/// Every failure a provider call can surface, in provider-neutral terms —
/// the store and UI switch on these, never on a module's own error types.
/// Messages name the provider ("Couldn't reach GitLab") since several can
/// be connected at once.
enum ProviderError: Error, LocalizedError {
    case invalidToken(ProviderKind)
    /// `retryAfter` when the provider said how long to wait.
    case rateLimited(ProviderKind, retryAfter: TimeInterval?)
    case network(ProviderKind, Error)
    case decoding(ProviderKind, Error)
    case unexpectedStatus(ProviderKind, Int)
    /// The provider rejected a write and said why (e.g. "Can not approve
    /// your own pull request") — shown verbatim.
    case validationFailed(String)
    /// No module exists for this provider yet.
    case unsupported(ProviderKind)
    /// The account (or its stored token) is gone — disconnected meanwhile.
    case accountUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "That token doesn't look valid — check it has at least read access to your repos."
        case .rateLimited(let kind, let retryAfter?):
            return "\(kind.displayName) asked us to slow down — retrying in \(Int(retryAfter))s."
        case .rateLimited(let kind, nil):
            return "\(kind.displayName) rate-limited this token. Wait a bit and try again."
        case .network(let kind, let error):
            return "Couldn't reach \(kind.displayName): \(error.localizedDescription)"
        case .decoding(let kind, _):
            return "\(kind.displayName) sent back something this build doesn't understand yet."
        case .unexpectedStatus(let kind, let code):
            return "\(kind.displayName) returned an unexpected response (HTTP \(code))."
        case .validationFailed(let message):
            return message
        case .unsupported(let kind):
            return "\(kind.displayName) isn't supported yet."
        case .accountUnavailable:
            return "This account isn't connected anymore — reconnect it in Settings."
        }
    }
}
