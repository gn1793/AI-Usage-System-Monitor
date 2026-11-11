import Foundation

private struct TestFailure: Error { let message: String }
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
}
private func near(_ value: Double?, _ expected: Double) -> Bool { abs((value ?? .infinity) - expected) < 0.000_001 }
private let testNow = Date(timeIntervalSince1970: 1_794_400_000)
private func configuration(source: OpenAICreditSource = .costsAPI, total: Double = 45) -> OpenAICreditConfiguration {
    OpenAICreditConfiguration(source: source, total: total, manualRemaining: min(total, 35.99),
        startsAt: testNow.addingTimeInterval(-10 * 86_400), expiresAt: testNow.addingTimeInterval(86_400),
        organizationID: "org-test", savedAt: testNow)
}
private func page(_ values: [Double], more: Bool = false, cursor: String? = nil, currency: String = "usd") throws -> Data {
    var object: [String: Any] = ["data": [["results": values.map { ["amount": ["value": $0, "currency": currency]] }]], "has_more": more]
    if let cursor { object["next_page"] = cursor }
    return try JSONSerialization.data(withJSONObject: object)
}
private struct Credentials: OpenAIAdminCredentialReading {
    var key: String? = "test-only"
    func readAdminKey() async -> String? { key }
}
private struct BrowserReader: BraveGrantReading {
    var data: Data
    func read() async throws -> Data { data }
}
private actor Transport: QuotaTransport {
    enum Step: Sendable { case data(Data), http(Int) }
    struct Request: Sendable { var url: URL; var headers: [String: String]; var authorized: Bool }
    var steps: [Step]
    var requests: [Request] = []
    init(_ steps: [Step]) { self.steps = steps }
    func get(_ url: URL, credential: ProviderCredential, headers: [String: String]) async throws -> Data {
        requests.append(Request(url: url, headers: headers, authorized: credential.token == "test-only"))
        guard !steps.isEmpty else { throw QuotaError.malformed }
        switch steps.removeFirst() {
        case .data(let data): return data
        case .http(let status): throw QuotaError.http(status)
        }
    }
}
private struct Quotas: QuotaFetching {
    func fetch(_ provider: ProviderKind) async -> ProviderState { ProviderState(name: provider.rawValue, status: .connected) }
}
private actor PollingQuotas: QuotaFetching {
    var calls = 0
    func fetch(_ provider: ProviderKind) async -> ProviderState {
        calls += 1
        return ProviderState(name: provider.rawValue, status: .connected)
    }
}
private actor CountingCredits: OpenAICreditFetching {
    var calls = 0
    func fetch(_ configuration: OpenAICreditConfiguration?, now: Date) async -> OpenAICreditState {
        calls += 1
        guard let configuration else { return OpenAICreditState() }
        return OpenAICreditState(snapshot: OpenAICreditSnapshot(configuration: configuration, used: 9), status: .connected, updatedAt: now)
    }
}
@MainActor private final class MemoryCreditCache: CreditSnapshotCaching {
    var value: CachedCreditSnapshot?
    func load() -> CachedCreditSnapshot? { value }
    func save(_ value: CachedCreditSnapshot) { self.value = value }
    func clear() { value = nil }
}
private actor SuspendedCreditFetcher: OpenAICreditFetching {
    private var first: CheckedContinuation<OpenAICreditState, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var calls = 0
    private var oldConfiguration: OpenAICreditConfiguration?
    func fetch(_ configuration: OpenAICreditConfiguration?, now: Date) async -> OpenAICreditState {
        calls += 1
        guard let configuration else { return OpenAICreditState() }
        if calls == 1 {
            oldConfiguration = configuration
            return await withCheckedContinuation { continuation in
                first = continuation; started?.resume(); started = nil
            }
        }
        return OpenAICreditState(snapshot: OpenAICreditSnapshot(configuration: configuration, used: 2), status: .connected, updatedAt: now)
    }
    func waitUntilStarted() async {
        if first == nil { await withCheckedContinuation { started = $0 } }
    }
    func release() {
        first?.resume(returning: OpenAICreditState(snapshot: OpenAICreditSnapshot(configuration: oldConfiguration!, used: 9), status: .connected, updatedAt: testNow))
        first = nil
    }
}

@main struct OpenAICreditsTests {
    @MainActor static func main() async throws {
        try expect(QuotaResetFormatter.duration(testNow.addingTimeInterval(Double(4 * 1440 + 23 * 60 + 21) * 60), now: testNow) == "4d 23h 21m", "Weekly reset durations must normalize days, hours and minutes")
        try expect(QuotaResetFormatter.duration(testNow.addingTimeInterval(45 * 60), now: testNow) == "0d 0h 45m", "Short reset windows must retain all three units")
        try expect(QuotaResetFormatter.duration(testNow.addingTimeInterval(24 * 3600), now: testNow) == "1d 0h 0m", "Day boundaries must normalize correctly")
        try expect(QuotaResetFormatter.duration(testNow, now: testNow) == nil, "A due reset must not show a negative countdown")
        print("PASS: reset countdowns with days, hours and minutes")

        let polling = PollingQuotas(), countedCredits = CountingCredits(), memory = MemoryCreditCache()
        let manualService = AIQuotaService(fetcher: polling, creditFetcher: countedCredits, creditCache: memory, pollingInterval: .milliseconds(5))
        manualService.configureCredits(configuration())
        manualService.start()
        for _ in 0..<100 {
            if await polling.calls >= 4 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        manualService.stop()
        try expect(await polling.calls >= 4, "Subscription quotas must keep polling automatically")
        try expect(await countedCredits.calls == 0, "Startup and automatic polling must never query OpenAI credits")
        await manualService.refresh()
        try expect(await countedCredits.calls == 1 && manualService.openAICredits.status == .connected, "The explicit refresh action must read credits")
        try expect(memory.value?.snapshot.used == 9, "A successful manual read must save its last known balance")
        manualService.start()
        try await Task.sleep(for: .milliseconds(15))
        manualService.stop()
        try expect(await countedCredits.calls == 1, "Restarting or waking the polling loop must not query credits")
        let restored = AIQuotaService(fetcher: Quotas(), creditFetcher: countedCredits, creditCache: memory)
        restored.configureCredits(configuration())
        try expect(restored.openAICredits.isStale && restored.openAICredits.snapshot?.used == 9, "Saved credits must restore as last known values without a query")
        try expect(await countedCredits.calls == 1, "Restoring the cache must not query credits")
        let roundTrip = try JSONDecoder().decode(CachedCreditSnapshot.self, from: JSONEncoder().encode(memory.value!))
        try expect(roundTrip.matches(configuration()) && roundTrip.snapshot.used == 9, "Cached credit data must round-trip and match its grant settings")
        restored.configureCredits(configuration(total: 100))
        try expect(restored.openAICredits.snapshot == nil && memory.value == nil, "Changing grant settings must discard another grant's cached balance")
        print("PASS: manual credit refresh, subscription polling, wake, cache restore and cache invalidation")

        let browserData = Data(#"{"currency":"USD","rows":[["Oct 29, 2026","Available","$75.00 / $100.00","Nov 12, 2026"]]}"#.utf8)
        let browserState = try BraveGrantParser.parse(browserData, now: testNow)
        try expect(browserState.status == .connected && browserState.snapshot?.configuration.source == .brave,
            "The browser must report direct Credit Grants data")
        try expect(near(browserState.snapshot?.remaining(at: testNow), 75) && near(browserState.snapshot?.used, 25),
            "Displayed balance and grant total must determine actual spending")
        let laterOnExpiryDay = browserState.snapshot!.configuration.expiresAt.addingTimeInterval(23 * 3600)
        try expect(browserState.snapshot?.remaining(at: laterOnExpiryDay) == 75 && browserState.snapshot?.isExpired(at: laterOnExpiryDay) == false,
            "A date-only expiry must not override the website's Available state")
        let multiple = try BraveGrantParser.parse(Data(#"{"currency":"USD","rows":[["Oct 29, 2026","Available","$75.00 / $100.00","Nov 12, 2026"],["Oct 30, 2026","Available","$10.00 / $50.00","Nov 20, 2026"],["Oct 1, 2026","Expired","$500.00 / $1,000.00","Nov 1, 2026"]]}"#.utf8), now: testNow)
        try expect(multiple.snapshot?.configuration.total == 150 && multiple.snapshot?.remaining(at: testNow) == 85 && multiple.snapshot?.used == 65,
            "Only available grants must be included in the summary")
        try expect(multiple.snapshot?.grants.count == 3 && multiple.snapshot?.displayExpiry == browserState.snapshot?.displayExpiry,
            "All grants must be retained for details and the next available expiry must be shown")
        let none = try BraveGrantParser.parse(Data(#"{"currency":"USD","rows":[]}"#.utf8), now: testNow)
        try expect(none.snapshot?.configuration.total == 0 && none.snapshot?.remainingPercent(at: testNow) == 0 && none.snapshot?.consumedPercent == 0,
            "An empty grant table must produce a finite zero balance")
        let expiredBrowser = try BraveGrantParser.parse(Data(#"{"currency":"USD","rows":[["Oct 1, 2026","Expired","$30.00 / $100.00","Nov 1, 2026"]]}"#.utf8), now: testNow)
        try expect(expiredBrowser.snapshot?.remaining(at: testNow) == 0 && expiredBrowser.snapshot?.isExpired(at: testNow) == true,
            "Expired grants must have no available balance")
        let never = try BraveGrantParser.parse(Data(#"{"currency":"USD","rows":[["Oct 1, 2026","Available","$3.00 / $5.00","Never"]]}"#.utf8), now: testNow)
        try expect(never.snapshot?.displayExpiry == nil && never.snapshot?.remaining(at: testNow) == 3, "Grants without an expiry must be supported")
        for invalid in [
            #"{"currency":"EUR","rows":[]}"#,
            #"{"currency":"USD","rows":[["Oct 1, 2026","Available","$6 / $5","Nov 12, 2026"]]}"#,
            #"{"currency":"USD","rows":[["Oct 1, 2026","Available","$-1 / $5","Nov 12, 2026"]]}"#,
            #"{"currency":"USD","rows":[["Oct 1, 2026","Available","$NaN / $5","Nov 12, 2026"]]}"#,
            #"{"currency":"USD","rows":[["Oct 1, 2026","Available","$1,00 / $500","Nov 12, 2026"]]}"#,
            #"{"currency":"USD","rows":[["Oct 1, 2026","Unknown state","$3 / $5","Nov 12, 2026"]]}"#,
            #"{"currency":"USD","rows":[["unexpected"]]}"#
        ] {
            do { _ = try BraveGrantParser.parse(Data(invalid.utf8), now: testNow); throw TestFailure(message: "Malformed browser grants must fail") }
            catch is TestFailure { throw TestFailure(message: "Malformed browser grants must fail") }
            catch { }
        }
        print("PASS: browser grants, multiple grants, inactive grants, expiry dates and malformed data")
        for code in ["javascript_disabled", "automation_denied", "login_required", "tab_missing", "multiple_tabs", "browser_not_running"] {
            let failed = try BraveGrantParser.parse(Data("{\"error\":\"\(code)\"}".utf8), now: testNow)
            try expect(failed.status == .authenticationRequired && failed.snapshot == nil && !failed.detail.isEmpty, "Browser connection failures must have actionable guidance")
        }
        let browserTransport = Transport([])
        let browserClient = OpenAICreditClient(credentials: Credentials(key: nil), transport: browserTransport,
            brave: BraveCreditGrantClient(reader: BrowserReader(data: browserData)))
        let direct = await browserClient.fetch(.braveSession, now: testNow)
        try expect(direct.status == .connected && direct.snapshot?.remaining(at: testNow) == 75,
            "Brave mode must work without an Admin key or configured amounts")
        try expect(await browserTransport.requests.isEmpty, "Brave mode must not call the Costs API")
        print("PASS: browser connection guidance and keyless direct grant integration")

        let environmentKey = "sk-admin-fixtureEnvironment"
        let savedKey = "sk-admin-fixtureSaved"
        let environmentDetection = OpenAICredentialDiscovery.resolve(savedKey: nil,
            environment: ["OPENAI_ADMIN_KEY": environmentKey], launchEnvironment: [:], files: [])
        try expect(environmentDetection.key == environmentKey && environmentDetection.detection.adminSource == "OPENAI_ADMIN_KEY environment variable", "An installed Admin key must be discovered without manual entry")
        let savedDetection = OpenAICredentialDiscovery.resolve(savedKey: savedKey,
            environment: ["OPENAI_ADMIN_KEY": environmentKey], launchEnvironment: [:], files: [])
        try expect(savedDetection.key == savedKey && savedDetection.detection.hasSavedKey, "An explicit Keychain override must take precedence")
        let loginDetection = OpenAICredentialDiscovery.resolve(savedKey: nil, environment: [:],
            launchEnvironment: ["OPENAI_API_KEY": environmentKey], files: [])
        try expect(loginDetection.key == environmentKey, "Finder-launched apps must also detect the macOS login environment")
        try expect(!environmentDetection.detection.detail.contains(environmentKey), "Credential status must not contain a secret value")
        print("PASS: automatic credential detection, source precedence and secret-free status")

        let shellFile = OpenAICredentialFile(source: "~/.zshrc", kind: .shell, data: Data(#"""
        # export OPENAI_ADMIN_KEY=sk-admin-commented
        export OPENAI_ADMIN_KEY='sk-admin-first'
        export OPENAI_ADMIN_KEY="sk-admin-last" # local account
        export OPENAI_ADMIN_KEY=$(printf sk-admin-command)
        export OPENAI_ADMIN_KEY="$(printf sk-admin-command)"
        export OPENAI_ADMIN_KEY=`printf sk-admin-command`
        echo OPENAI_ADMIN_KEY=sk-admin-notAssignment
        """#.utf8))
        let shellDetection = OpenAICredentialDiscovery.resolve(savedKey: nil, environment: [:], launchEnvironment: [:], files: [shellFile])
        try expect(shellDetection.key == "sk-admin-last", "Only literal shell assignments may be read, with the final assignment taking precedence")
        let bareDetection = OpenAICredentialDiscovery.resolve(savedKey: nil, environment: [:], launchEnvironment: [:],
            files: [OpenAICredentialFile(source: "~/.profile", kind: .shell, data: Data("OPENAI_ADMIN_KEY=sk-admin-bare".utf8))])
        try expect(bareDetection.key == "sk-admin-bare", "An unquoted literal assignment must be supported")
        print("PASS: shell configuration detection without evaluating commands")

        let codexFile = OpenAICredentialFile(source: "~/.codex/auth.json", kind: .codex,
            data: Data(#"{"OPENAI_API_KEY":"sk-proj-fixture","tokens":{"access_token":"fixture-login-token"}}"#.utf8))
        let incompatible = OpenAICredentialDiscovery.resolve(savedKey: nil,
            environment: ["OPENAI_API_KEY": "sk-proj-environment"], launchEnvironment: [:], files: [codexFile])
        try expect(incompatible.key == nil && incompatible.detection.hasProjectKey && incompatible.detection.hasChatGPTSignIn,
            "Project keys and Codex logins must be identified without treating them as billing credentials")
        let codexAdmin = OpenAICredentialDiscovery.resolve(savedKey: nil, environment: [:], launchEnvironment: [:],
            files: [OpenAICredentialFile(source: "custom/auth.json", kind: .codex, data: Data(#"{"OPENAI_API_KEY":"sk-admin-codexFixture"}"#.utf8))])
        try expect(codexAdmin.key == "sk-admin-codexFixture", "An Admin key in Codex credentials must be reusable")
        let wronglyNamed = OpenAICredentialDiscovery.resolve(savedKey: nil,
            environment: ["OPENAI_ADMIN_KEY": "sk-proj-ordinary"], launchEnvironment: [:], files: [])
        try expect(wronglyNamed.key == nil && wronglyNamed.detection.hasProjectKey, "Naming a project key OPENAI_ADMIN_KEY must not grant billing access")
        let unavailable = OpenAICredentialDiscovery.resolve(savedKey: nil, environment: [:], launchEnvironment: [:],
            files: [OpenAICredentialFile(source: "invalid/auth.json", kind: .codex, data: Data("not-json".utf8))])
        try expect(unavailable.key == nil && unavailable.detection.adminSource == nil, "Missing and malformed local credentials must remain unconfigured")
        print("PASS: Codex credential reuse, login detection and billing credential boundaries")

        let parsed = try OpenAICostPage.parse(page([4, 5.51, -0.5], more: true, cursor: "second"))
        try expect(near(parsed.cost, 9.01) && parsed.nextPage == "second", "Costs, adjustments and pagination must be parsed")
        try expect(try OpenAICostPage.parse(page([])).cost == 0, "An empty cost period is zero")
        for invalid in [try page([1], currency: "eur"), try page([1], more: true), Data("{\"data\": []}".utf8), Data("{\"data\":[{\"results\":[{}]}],\"has_more\":false}".utf8)] {
            do { _ = try OpenAICostPage.parse(invalid); throw TestFailure(message: "Invalid costs must fail") }
            catch is TestFailure { throw TestFailure(message: "Invalid costs must fail") }
            catch { }
        }
        print("PASS: cost parsing, refunds, currency and malformed responses")

        let transport = Transport([.data(try page([4], more: true, cursor: "page + /")), .data(try page([5.01]))])
        let client = OpenAICreditClient(credentials: Credentials(), transport: transport)
        let state = await client.fetch(configuration(), now: testNow)
        try expect(state.status == .connected && near(state.snapshot?.used, 9.01), "All cost pages must be summed")
        try expect(near(state.snapshot?.remaining(at: testNow), 35.99), "The estimated balance must subtract spending")
        let requests = await transport.requests
        try expect(requests.count == 2 && requests.allSatisfy { $0.authorized && $0.url.host == "api.openai.com" && $0.headers["OpenAI-Organization"] == "org-test" }, "Costs must use the selected organization and credentials")
        let query = URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)!.queryItems!
        try expect(query.first(where: { $0.name == "page" })?.value == "page + /", "Cursor encoding must preserve special characters")
        try expect(query.first(where: { $0.name == "start_time" })?.value == String(Int(configuration().startsAt.timeIntervalSince1970)), "Costs must start at the grant period")
        print("PASS: authenticated organization requests, pagination and estimated balance")

        let noRequests = Transport([])
        let manual = await OpenAICreditClient(credentials: Credentials(key: nil), transport: noRequests).fetch(configuration(source: .manual), now: testNow)
        try expect(manual.status == .connected && near(manual.snapshot?.remaining(at: testNow), 35.99), "Manual mode must work without credentials")
        try expect(manual.updatedAt == testNow, "Manual update time must be the saved time")
        try expect(await noRequests.requests.isEmpty, "Manual mode must not use the network")
        let missing = await OpenAICreditClient(credentials: Credentials(key: nil), transport: noRequests).fetch(configuration(), now: testNow)
        try expect(missing.status == .authenticationRequired && missing.snapshot == nil, "Missing credentials must not invent a balance")
        let unconfigured = await client.fetch(nil, now: testNow)
        try expect(unconfigured.snapshot == nil && unconfigured.status == .waiting, "An unconfigured grant must have no balance")
        var invalid = configuration(); invalid.total = .infinity
        try expect(invalid.validationError(now: testNow) != nil, "Infinite amounts must be rejected")
        invalid = configuration(); invalid.manualRemaining = 46
        try expect(invalid.validationError(now: testNow) != nil, "Remaining balance cannot exceed the grant")
        invalid = configuration(); invalid.expiresAt = invalid.startsAt
        try expect(invalid.validationError(now: testNow) != nil, "Expiry must follow the start")
        print("PASS: manual mode, unconfigured state, missing credentials and validation")

        var expired = configuration(source: .manual); expired.expiresAt = testNow
        let expiredState = await client.fetch(expired, now: testNow)
        try expect(expiredState.snapshot?.remaining(at: testNow) == 0 && near(expiredState.snapshot?.used, 9.01), "Expiry must remove availability without inventing spending")
        let overdrawn = OpenAICreditSnapshot(configuration: configuration(), used: 60)
        try expect(overdrawn.remaining(at: testNow) == 0 && overdrawn.consumedPercent == 100, "Overdrawn grants must clamp the gauge")
        let expiredTransport = Transport([.data(try page([1]))])
        // Use automatic mode to check that post-expiry spending is excluded.
        expired.source = .costsAPI
        _ = await OpenAICreditClient(credentials: Credentials(), transport: expiredTransport).fetch(expired, now: testNow.addingTimeInterval(100))
        let expiryRequests = await expiredTransport.requests
        let expiryQuery = URLComponents(url: expiryRequests[0].url, resolvingAgainstBaseURL: false)!.queryItems!
        try expect(expiryQuery.first(where: { $0.name == "end_time" })?.value == String(Int(testNow.timeIntervalSince1970)), "Costs must stop at grant expiry")
        print("PASS: expiration, overdrawn grants and period boundaries")

        for (code, expected) in [(401, ProviderStatus.authenticationRequired), (403, .authenticationRequired), (429, .rateLimited), (500, .unavailable)] {
            let failed = await OpenAICreditClient(credentials: Credentials(), transport: Transport([.http(code)])).fetch(configuration(), now: testNow)
            try expect(failed.status == expected && failed.snapshot == nil, "HTTP \(code) must be represented accurately")
        }
        let repeated = Transport([.data(try page([1], more: true, cursor: "same")), .data(try page([1], more: true, cursor: "same"))])
        let repeatedState = await OpenAICreditClient(credentials: Credentials(), transport: repeated).fetch(configuration(), now: testNow)
        try expect(repeatedState.status == .unavailable && repeatedState.snapshot == nil, "Repeated cursors must fail instead of double counting or looping")
        print("PASS: authentication, rate limiting, service errors and cursor loops")

        let staleTransport = Transport([.data(try page([9.01])), .http(429)])
        let service = AIQuotaService(fetcher: Quotas(), creditFetcher: OpenAICreditClient(credentials: Credentials(), transport: staleTransport), creditCache: nil)
        service.configureCredits(configuration())
        await service.refresh(); await service.refresh()
        try expect(service.openAICredits.isStale && service.openAICredits.status == .rateLimited && near(service.openAICredits.snapshot?.used, 9.01), "Refresh failures must retain the last successful balance as stale")
        service.configureCredits(nil)
        try expect(service.openAICredits.snapshot == nil, "Clearing settings must clear cached balances")
        print("PASS: stale balance retention and settings reset")

        let suspended = SuspendedCreditFetcher()
        let changing = AIQuotaService(fetcher: Quotas(), creditFetcher: suspended, creditCache: nil)
        changing.configureCredits(configuration())
        let oldRefresh = Task { await changing.refresh() }
        await suspended.waitUntilStarted()
        changing.configureCredits(configuration(total: 100))
        await changing.refresh()
        await suspended.release(); await oldRefresh.value
        try expect(changing.openAICredits.snapshot?.configuration.total == 100 && changing.openAICredits.snapshot?.used == 2, "An older in-flight request must not overwrite a new grant")
        print("PASS: grant changes invalidate older in-flight requests")
        print("All OpenAI credit checks passed.")
    }
}
