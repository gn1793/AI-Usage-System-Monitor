import Foundation
import Security
import LocalAuthentication

enum ProviderKind: String, CaseIterable, Sendable { case codex = "Codex", claude = "Claude Code" }
struct ProviderCredential: Sendable, Equatable { let token: String; let accountID: String? }
protocol CredentialReading: Sendable { func read(_ provider: ProviderKind) async -> ProviderCredential? }
protocol QuotaFetching: Sendable { func fetch(_ provider: ProviderKind) async -> ProviderState }
protocol QuotaTransport: Sendable {
    func get(_ url: URL, credential: ProviderCredential, headers: [String: String]) async throws -> Data
}
enum QuotaError: Error { case http(Int), malformed }

/// Its actor executor performs file and Keychain I/O away from the UI actor.
actor CredentialStore: CredentialReading {
    func read(_ provider: ProviderKind) async -> ProviderCredential? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch provider {
        case .codex:
            let paths = (environment["CODEX_HOME"].map { ["\($0)/auth.json"] } ?? []) + ["\(home)/.codex/auth.json", "\(home)/.config/codex/auth.json"]
            for path in paths {
                if let credential = codex(jsonFile(path)) { return credential }
            }
            return codex(keychain("Codex Auth"))
        case .claude:
            let directory = environment["CLAUDE_CONFIG_DIR"] ?? "\(home)/.claude"
            for object in [keychain("Claude Code-credentials"), jsonFile("\(directory)/.credentials.json")] {
                let auth = (object?["claudeAiOauth"] as? [String: Any]) ?? object
                if let token = auth?["accessToken"] as? String, !token.isEmpty {
                    return ProviderCredential(token: token, accountID: nil)
                }
            }
            return nil
        }
    }
    private func codex(_ json: [String: Any]?) -> ProviderCredential? {
        guard let tokens = json?["tokens"] as? [String: Any], let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return ProviderCredential(token: token, accountID: tokens["account_id"] as? String)
    }
    private func jsonFile(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private func keychain(_ service: String) -> [String: Any]? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct HTTPQuotaTransport: QuotaTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }
    func get(_ url: URL, credential: ProviderCredential, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuotaError.malformed }
        guard (200..<300).contains(http.statusCode) else { throw QuotaError.http(http.statusCode) }
        return data
    }
}

enum QuotaParser {
    static func parse(_ provider: ProviderKind, data: Data) throws -> ProviderState {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.malformed }
        var state = ProviderState(name: provider.rawValue)
        let rows: [(String, String)] = provider == .codex ? [("primary_window", "5h"), ("secondary_window", "Weekly")] : [("five_hour", "5h"), ("seven_day", "Weekly")]
        let content = provider == .codex ? json["rate_limit"] as? [String: Any] ?? [:] : json
        for (key, defaultName) in rows {
            guard let row = content[key] as? [String: Any], let number = row[provider == .codex ? "used_percent" : "utilization"] as? NSNumber else { continue }
            let percent = number.doubleValue
            guard percent.isFinite else { continue }
            let duration = (row["limit_window_seconds"] as? NSNumber)?.intValue
            let name = duration == 604800 ? "Weekly" : duration == 18000 ? "5h" : defaultName
            state.windows.append(QuotaWindow(name: name, usedPercent: min(100, max(0, percent)), resetAt: reset(row)))
        }
        guard !state.windows.isEmpty else { throw QuotaError.malformed }
        state.status = .connected; state.detail = "Connected"; state.updatedAt = Date(); state.lastAttemptAt = Date()
        return state
    }
    private static func reset(_ row: [String: Any]) -> Date? {
        if let value = row["reset_at"] as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        if let value = row["reset_after_seconds"] as? NSNumber { return Date().addingTimeInterval(value.doubleValue) }
        if let value = row["resets_at"] as? String {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        return nil
    }
}

actor QuotaClient: QuotaFetching {
    private let credentials: any CredentialReading
    private let transport: any QuotaTransport
    init(credentials: any CredentialReading = CredentialStore(), transport: any QuotaTransport = HTTPQuotaTransport()) {
        self.credentials = credentials; self.transport = transport
    }
    func fetch(_ provider: ProviderKind) async -> ProviderState {
        var state = ProviderState(name: provider.rawValue)
        state.lastAttemptAt = Date()
        guard let credential = await credentials.read(provider) else {
            state.status = .authenticationRequired; state.detail = "Sign-in not found. " + loginHint(provider); return state
        }
        do {
            do { return try await request(provider, credential: credential) }
            catch QuotaError.http(let status) where status == 401 || status == 403 {
                // Companion tools own refresh-token rotation. Re-read their updated
                // credentials once; never race them by rotating or writing tokens.
                if let latest = await credentials.read(provider), latest != credential {
                    return try await request(provider, credential: latest)
                }
                throw QuotaError.http(status)
            }
        } catch QuotaError.http(let status) {
            if status == 401 || status == 403 {
                state.status = .authenticationRequired; state.detail = "Sign-in expired or unavailable (\(status)). " + loginHint(provider)
            } else if status == 429 {
                state.status = .rateLimited; state.detail = "Rate limited. Automatic retry in 5 minutes."
            } else {
                state.status = .unavailable; state.detail = "Usage service returned HTTP \(status). Will retry."
            }
        } catch is CancellationError {
            state.status = .unavailable; state.detail = "Refresh cancelled"
        } catch {
            state.status = .unavailable
            state.detail = error is QuotaError ? "Usage response could not be read. Will retry." : "Network unavailable. Will retry automatically."
        }
        return state
    }
    private func request(_ provider: ProviderKind, credential: ProviderCredential) async throws -> ProviderState {
        let url = URL(string: provider == .codex ? "https://chatgpt.com/backend-api/wham/usage" : "https://api.anthropic.com/api/oauth/usage")!
        var headers: [String: String] = [:]
        if provider == .codex, let id = credential.accountID { headers["ChatGPT-Account-Id"] = id }
        if provider == .claude { headers["anthropic-beta"] = "oauth-2025-04-20"; headers["User-Agent"] = "claude-code/2.1.69" }
        return try QuotaParser.parse(provider, data: await transport.get(url, credential: credential, headers: headers))
    }
    private func loginHint(_ provider: ProviderKind) -> String {
        provider == .codex ? "Run codex login, then refresh." : "Sign in in Claude Code with /login, then refresh."
    }
}
