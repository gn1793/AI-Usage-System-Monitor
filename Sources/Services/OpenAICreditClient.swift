import Foundation
import Security
import LocalAuthentication

protocol OpenAIAdminCredentialReading: Sendable {
    func readAdminKey() async -> String?
}

actor OpenAIAdminCredentialStore: OpenAIAdminCredentialReading {
    static let shared = OpenAIAdminCredentialStore()
    private let service = "dev.local.aiusagesystemmonitor.openai"
    private let account = "admin-api-key"

    func readAdminKey() -> String? { resolve().key }
    func detect() -> OpenAICredentialDetection { resolve().detection }
    func hasSavedKey() -> Bool { savedKey() != nil }
    private func resolve() -> OpenAICredentialDiscovery.Resolution {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shellHome = environment["ZDOTDIR"] ?? home
        var files: [OpenAICredentialFile] = []
        var seen = Set<String>()
        func append(_ path: String, kind: OpenAICredentialFile.Kind) {
            let expanded = (path as NSString).expandingTildeInPath
            guard seen.insert(expanded).inserted,
                  let size = (try? FileManager.default.attributesOfItem(atPath: expanded)[.size]) as? NSNumber,
                  size.intValue <= 1_048_576,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { return }
            let label = expanded.hasPrefix(home + "/") ? "~" + expanded.dropFirst(home.count) : expanded
            files.append(OpenAICredentialFile(source: label, kind: kind, data: data))
        }
        for path in ["\(shellHome)/.zshrc", "\(shellHome)/.zprofile", "\(shellHome)/.zshenv", "\(home)/.bashrc", "\(home)/.bash_profile", "\(home)/.profile"] {
            append(path, kind: .shell)
        }
        if let directory = environment["CODEX_HOME"] { append("\(directory)/auth.json", kind: .codex) }
        for path in ["\(home)/.codex/auth.json", "\(home)/.config/codex/auth.json", "\(home)/.codex-api/auth.json"] {
            append(path, kind: .codex)
        }
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Codex Auth", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            files.append(OpenAICredentialFile(source: "Codex Keychain", kind: .codex, data: data))
        }
        var loginEnvironment: [String: String] = [:]
        for name in ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["getenv", name]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0, data.count <= 8192 {
                    loginEnvironment[name] = String(data: data, encoding: .utf8)
                }
            }
        }
        return OpenAICredentialDiscovery.resolve(savedKey: savedKey(), environment: environment, launchEnvironment: loginEnvironment, files: files)
    }
    func save(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError.status(result) }
        } else if status != errSecSuccess { throw KeychainError.status(status) }
    }
    func remove() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
    private func savedKey() -> String? {
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }
    enum KeychainError: Error { case status(OSStatus) }
}

protocol OpenAICreditFetching: Sendable {
    func fetch(_ configuration: OpenAICreditConfiguration?, now: Date) async -> OpenAICreditState
}

/// The public Costs API reports spending, not credit grants. The grant and its
/// validity period are supplied by the user; the resulting balance is an estimate.
actor OpenAICreditClient: OpenAICreditFetching {
    private let credentials: any OpenAIAdminCredentialReading
    private let transport: any QuotaTransport
    private let brave: BraveCreditGrantClient
    init(credentials: any OpenAIAdminCredentialReading = OpenAIAdminCredentialStore.shared,
         transport: any QuotaTransport = HTTPQuotaTransport(), brave: BraveCreditGrantClient = BraveCreditGrantClient()) {
        self.credentials = credentials; self.transport = transport; self.brave = brave
    }
    func fetch(_ configuration: OpenAICreditConfiguration?, now: Date = .now) async -> OpenAICreditState {
        guard let configuration else { return OpenAICreditState() }
        if configuration.source == .brave { return await brave.fetch(now: now) }
        if let error = configuration.validationError(now: now) {
            return OpenAICreditState(status: .unavailable, detail: error)
        }
        if configuration.source == .manual {
            return OpenAICreditState(snapshot: OpenAICreditSnapshot(configuration: configuration, used: configuration.total - configuration.manualRemaining),
                                    status: .connected, detail: "Manually entered balance", updatedAt: configuration.savedAt)
        }
        guard let key = await credentials.readAdminKey() else {
            return OpenAICreditState(status: .authenticationRequired, detail: "No local Admin API key found. Open Settings to detect credentials. Codex sign-in and project keys cannot read organization costs.")
        }
        do {
            var page: String?
            var seen = Set<String>()
            var total = 0.0
            repeat {
                try Task.checkCancellation()
                var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
                components.queryItems = [
                    URLQueryItem(name: "start_time", value: String(Int(configuration.startsAt.timeIntervalSince1970))),
                    URLQueryItem(name: "end_time", value: String(Int(min(now, configuration.expiresAt).timeIntervalSince1970))),
                    URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "180")
                ]
                if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }
                var headers = ["Accept": "application/json"]
                if !configuration.organizationID.isEmpty { headers["OpenAI-Organization"] = configuration.organizationID }
                let data = try await transport.get(components.url!, credential: ProviderCredential(token: key, accountID: nil), headers: headers)
                let result = try OpenAICostPage.parse(data)
                total += result.cost
                guard total.isFinite else { throw QuotaError.malformed }
                page = result.nextPage
                if let page, !seen.insert(page).inserted { throw QuotaError.malformed }
            } while page != nil
            try Task.checkCancellation()
            return OpenAICreditState(snapshot: OpenAICreditSnapshot(configuration: configuration, used: max(0, total)),
                                    status: .connected, detail: "Estimated from organization costs", updatedAt: now)
        } catch QuotaError.http(let status) {
            if status == 401 || status == 403 {
                return OpenAICreditState(status: .authenticationRequired, detail: "Costs access denied (\(status)). Check your Admin API key and organization in Settings.")
            }
            if status == 429 {
                return OpenAICreditState(status: .rateLimited, detail: "Rate limited. Use the refresh button to try again later.")
            }
            return OpenAICreditState(status: .unavailable, detail: "Costs service returned HTTP \(status). Will retry.")
        } catch is CancellationError {
            return OpenAICreditState(status: .unavailable, detail: "Refresh cancelled")
        } catch {
            return OpenAICreditState(status: .unavailable, detail: error is QuotaError || error is DecodingError
                                    ? "Costs response could not be read. Will retry." : "Network unavailable. Will retry automatically.")
        }
    }
}

struct OpenAICostPage {
    let cost: Double
    let nextPage: String?
    static func parse(_ data: Data) throws -> OpenAICostPage {
        struct Page: Decodable {
            struct Bucket: Decodable {
                struct Result: Decodable {
                    struct Amount: Decodable { var value: Double; var currency: String }
                    var amount: Amount
                }
                var results: [Result]
            }
            var data: [Bucket]
            var has_more: Bool
            var next_page: String?
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        var cost = 0.0
        for bucket in page.data {
            for row in bucket.results {
                guard row.amount.currency.lowercased() == "usd", row.amount.value.isFinite else { throw QuotaError.malformed }
                cost += row.amount.value
            }
        }
        guard cost.isFinite else { throw QuotaError.malformed }
        if page.has_more {
            guard let cursor = page.next_page, !cursor.isEmpty else { throw QuotaError.malformed }
            return OpenAICostPage(cost: cost, nextPage: cursor)
        }
        return OpenAICostPage(cost: cost, nextPage: nil)
    }
}
