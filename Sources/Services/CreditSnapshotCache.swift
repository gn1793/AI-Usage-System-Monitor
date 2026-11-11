import Foundation

struct CachedCreditSnapshot: Codable {
    var snapshot: OpenAICreditSnapshot
    var updatedAt: Date
    func matches(_ configuration: OpenAICreditConfiguration) -> Bool {
        let saved = snapshot.configuration
        guard saved.total.isFinite, saved.total >= 0, snapshot.used.isFinite, snapshot.used >= 0 else { return false }
        return configuration.source == .brave ? saved.source == .brave : saved == configuration
    }
}

@MainActor protocol CreditSnapshotCaching {
    func load() -> CachedCreditSnapshot?
    func save(_ value: CachedCreditSnapshot)
    func clear()
}

@MainActor struct UserDefaultsCreditSnapshotCache: CreditSnapshotCaching {
    private let key = "openai.credits.lastSnapshot.v1"
    func load() -> CachedCreditSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CachedCreditSnapshot.self, from: data)
    }
    func save(_ value: CachedCreditSnapshot) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
