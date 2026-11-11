import Foundation

enum OpenAICreditSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case brave, costsAPI, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brave: return "Brave · Credit Grants"
        case .costsAPI: return "Estimated (Costs API)"
        case .manual: return "Manual balance"
        }
    }
}

struct OpenAICreditConfiguration: Codable, Equatable, Sendable {
    var source: OpenAICreditSource
    var total: Double
    var manualRemaining: Double
    var startsAt: Date
    var expiresAt: Date
    var organizationID: String
    var savedAt: Date

    static var braveSession: OpenAICreditConfiguration {
        OpenAICreditConfiguration(source: .brave, total: 0, manualRemaining: 0, startsAt: .distantPast,
                                  expiresAt: .distantFuture, organizationID: "", savedAt: .now)
    }

    func validationError(now: Date = .now) -> String? {
        if source == .brave { return nil }
        guard total.isFinite, total > 0 else { return "Enter a credit total greater than zero." }
        guard manualRemaining.isFinite, (0...total).contains(manualRemaining) else {
            return "Remaining credits must be between zero and the credit total."
        }
        guard startsAt <= now else { return "The credit start date cannot be in the future." }
        guard expiresAt > startsAt else { return "The expiry must be after the credit start date." }
        guard organizationID.isEmpty || (organizationID.hasPrefix("org-") && organizationID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) })) else {
            return "Enter an organization ID beginning with org-, or leave it empty."
        }
        return nil
    }
}

struct OpenAICreditGrant: Codable, Sendable {
    var receivedAt: Date
    var state: String
    var remaining: Double
    var total: Double
    var expiresAt: Date?
    var isAvailable: Bool { state.lowercased() == "available" }
}

struct OpenAICreditSnapshot: Codable, Sendable {
    var configuration: OpenAICreditConfiguration
    var used: Double
    var grants: [OpenAICreditGrant] = []
    var consumedPercent: Double { configuration.total > 0 ? min(100, max(0, used / configuration.total * 100)) : 0 }
    var displayExpiry: Date? {
        guard configuration.source == .brave else { return configuration.expiresAt }
        let available = grants.filter(\.isAvailable)
        return available.isEmpty ? grants.compactMap(\.expiresAt).max() : available.compactMap(\.expiresAt).min()
    }
    func isExpired(at now: Date) -> Bool {
        if configuration.source == .brave { return !grants.isEmpty && !grants.contains(where: \.isAvailable) }
        return now >= configuration.expiresAt
    }
    func remaining(at now: Date) -> Double {
        isExpired(at: now) ? 0 : max(0, configuration.total - used)
    }
    func remainingPercent(at now: Date) -> Double { configuration.total > 0 ? remaining(at: now) / configuration.total * 100 : 0 }
}

struct OpenAICreditState: Sendable {
    var snapshot: OpenAICreditSnapshot?
    var status: ProviderStatus = .waiting
    var detail = "Set up your API credits in Settings."
    var updatedAt: Date?
    var isStale: Bool { snapshot != nil && status != .connected }
}
