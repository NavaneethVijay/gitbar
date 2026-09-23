import Foundation

/// Every git host the app knows about — the identity, wording and defaults
/// for each. Whether one actually works is `ProviderRegistry`'s call (a
/// module has to exist for it); this is just what the UI needs to present
/// it, so a "coming soon" provider can still be listed properly.
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case github
    case gitlab
    case bitbucket

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .bitbucket: return "Bitbucket"
        }
    }

    /// The cloud host; self-hosted accounts store their own.
    var defaultHost: String {
        switch self {
        case .github: return "github.com"
        case .gitlab: return "gitlab.com"
        case .bitbucket: return "bitbucket.org"
        }
    }

    var isAvailable: Bool { ProviderRegistry.isAvailable(self) }

    // MARK: Token entry

    var tokenPlaceholder: String {
        switch self {
        case .github: return "ghp_…"
        case .gitlab: return "glpat-…"
        case .bitbucket: return "App password"
        }
    }

    /// Where to create a token on `host` — the Add Account screen links it.
    func tokenHelpURL(host: String) -> URL? {
        switch self {
        case .github: return URL(string: "https://\(host)/settings/tokens")
        case .gitlab: return URL(string: "https://\(host)/-/user_settings/personal_access_tokens")
        case .bitbucket: return URL(string: "https://\(host)/account/settings/app-passwords/")
        }
    }

    // MARK: Terminology

    /// "Pull Requests" / "Merge Requests" — tab titles.
    var pullRequestsTitle: String {
        self == .gitlab ? "Merge Requests" : "Pull Requests"
    }

    /// "pull request" / "merge request" — running text.
    var pullRequestNoun: String {
        self == .gitlab ? "merge request" : "pull request"
    }

    /// "PR" / "MR" — buttons and compact labels.
    var pullRequestShort: String {
        self == .gitlab ? "MR" : "PR"
    }

    /// How a PR number is written: GitHub/Bitbucket `#12`, GitLab `!12`.
    func formatNumber(_ number: Int) -> String {
        (self == .gitlab ? "!" : "#") + String(number)
    }

    // MARK: Hosts

    /// The provider's own name for its hosted service.
    var cloudName: String {
        switch self {
        case .github: return "GitHub.com"
        case .gitlab: return "GitLab.com"
        case .bitbucket: return "Bitbucket Cloud"
        }
    }

    /// The provider's own name for an instance you run yourself.
    var selfHostedName: String {
        switch self {
        case .github: return "GitHub Enterprise Server"
        case .gitlab: return "GitLab Self-Managed"
        case .bitbucket: return "Bitbucket Data Center"
        }
    }

    /// An example host for the self-hosted server field.
    var selfHostedExample: String {
        switch self {
        case .github: return "github.example.com"
        case .gitlab: return "gitlab.example.com"
        case .bitbucket: return "bitbucket.example.com"
        }
    }

    /// "https://GitHub.Example.com/" → "github.example.com" — what's stored
    /// on the account and compared for duplicates. Empty input means the
    /// cloud host.
    func normalizeHost(_ input: String) -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) {
            host.removeFirst(scheme.count)
        }
        while host.hasSuffix("/") { host.removeLast() }
        return host.isEmpty ? defaultHost : host
    }
}
