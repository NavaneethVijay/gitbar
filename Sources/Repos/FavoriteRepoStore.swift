import Foundation

/// Favorited repo paths per account — each `(accountID, path)` is a `RepoRef`.
@MainActor
final class FavoriteRepoStore: ObservableObject {
    @Published private(set) var favoritesByAccount: [UUID: Set<String>] = [:]

    private static let defaultsKey = "gitbar.favoriteRepos.byAccount"

    init() {
        load()
    }

    func favoriteFullNames(for accountID: UUID) -> Set<String> {
        favoritesByAccount[accountID] ?? []
    }

    func toggle(_ fullName: String, for accountID: UUID) {
        var names = favoritesByAccount[accountID] ?? []
        if names.contains(fullName) {
            names.remove(fullName)
        } else {
            names.insert(fullName)
        }
        favoritesByAccount[accountID] = names
        persist()
    }

    func isFavorite(_ fullName: String, for accountID: UUID) -> Bool {
        favoritesByAccount[accountID]?.contains(fullName) ?? false
    }

    /// On disconnect, so favorites don't linger under a dead account id.
    func clearFavorites(for accountID: UUID) {
        guard favoritesByAccount[accountID] != nil else { return }
        favoritesByAccount[accountID] = nil
        persist()
    }

    private func persist() {
        let stored = favoritesByAccount.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key.uuidString] = Array(entry.value)
        }
        UserDefaults.standard.set(stored, forKey: Self.defaultsKey)
    }

    private func load() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [String]] else { return }
        favoritesByAccount = stored.reduce(into: [UUID: Set<String>]()) { result, entry in
            guard let id = UUID(uuidString: entry.key) else { return }
            result[id] = Set(entry.value)
        }
    }
}
