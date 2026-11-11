import Foundation
import Combine

@MainActor
final class AIQuotaService: ObservableObject {
    @Published private(set) var providers: [ProviderState] = ProviderKind.allCases.map { ProviderState(name: $0.rawValue) }
    @Published private(set) var openAICredits = OpenAICreditState()
    @Published private(set) var isRefreshingProviders = false
    @Published private(set) var isRefreshingCredits = false
    var isRefreshing: Bool { isRefreshingProviders || isRefreshingCredits }
    private let fetcher: any QuotaFetching
    private let creditFetcher: any OpenAICreditFetching
    private let creditCache: (any CreditSnapshotCaching)?
    private let pollingInterval: Duration
    private var creditConfiguration: OpenAICreditConfiguration?
    private var timer: Task<Void, Never>?
    private var providerWork: Task<[ProviderState], Never>?
    private var creditWork: Task<OpenAICreditState, Never>?
    private var providerGeneration = UUID()
    private var creditGeneration = UUID()
    init(fetcher: any QuotaFetching = QuotaClient(), creditFetcher: any OpenAICreditFetching = OpenAICreditClient(),
         creditCache: (any CreditSnapshotCaching)? = UserDefaultsCreditSnapshotCache(), pollingInterval: Duration = .seconds(300)) {
        self.fetcher = fetcher; self.creditFetcher = creditFetcher
        self.creditCache = creditCache; self.pollingInterval = pollingInterval
    }
    func configureCredits(_ configuration: OpenAICreditConfiguration?, force: Bool = false) {
        guard force || creditConfiguration != configuration else { return }
        creditConfiguration = configuration
        creditGeneration = UUID(); creditWork?.cancel(); creditWork = nil; isRefreshingCredits = false
        if let configuration, let cached = creditCache?.load(), cached.matches(configuration) {
            openAICredits = OpenAICreditState(snapshot: cached.snapshot, status: .waiting,
                detail: "Saved balance. Use the refresh button beside Every 5 minutes to update.", updatedAt: cached.updatedAt)
        } else {
            openAICredits = OpenAICreditState(detail: configuration == nil ? "Set up your API credits in Settings." : "Use the refresh button beside Every 5 minutes to read your credits.")
            creditCache?.clear()
        }
    }
    func start() {
        guard timer == nil else { return }
        let interval = pollingInterval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                // Startup, wake and periodic polling never access the browser.
                await self?.refreshProviders()
                do { try await Task.sleep(for: interval) } catch { break }
            }
        }
    }
    func stop() {
        providerGeneration = UUID(); creditGeneration = UUID()
        timer?.cancel(); timer = nil
        providerWork?.cancel(); providerWork = nil; isRefreshingProviders = false
        creditWork?.cancel(); creditWork = nil; isRefreshingCredits = false
    }
    /// Explicit user action from the dashboard's refresh button.
    func refresh() async {
        async let providers: Void = refreshProviders()
        async let credits: Void = refreshCredits()
        _ = await (providers, credits)
    }
    func refreshProviders() async {
        if let providerWork { _ = await providerWork.value; return }
        let fetcher = self.fetcher, generation = providerGeneration
        let work = Task {
            async let codex = fetcher.fetch(.codex)
            async let claude = fetcher.fetch(.claude)
            return await [codex, claude]
        }
        providerWork = work; isRefreshingProviders = true
        let results = await work.value
        guard generation == providerGeneration, !work.isCancelled else { return }
        providers = results.map { result in
            var state = result
            if result.status != .connected, let previous = providers.first(where: { $0.name == result.name }) {
                state.windows = previous.windows; state.updatedAt = previous.updatedAt
            }
            return state
        }
        providerWork = nil; isRefreshingProviders = false
    }
    func refreshCredits() async {
        guard let configuration = creditConfiguration else { return }
        if let creditWork { _ = await creditWork.value; return }
        let fetcher = creditFetcher, generation = creditGeneration
        let work = Task { await fetcher.fetch(configuration, now: .now) }
        creditWork = work; isRefreshingCredits = true
        var state = await work.value
        guard generation == creditGeneration, !work.isCancelled else { return }
        if state.status != .connected, let previous = openAICredits.snapshot {
            state.snapshot = previous; state.updatedAt = openAICredits.updatedAt
        }
        if state.status == .connected, let snapshot = state.snapshot, let updatedAt = state.updatedAt {
            creditCache?.save(CachedCreditSnapshot(snapshot: snapshot, updatedAt: updatedAt))
        }
        openAICredits = state
        creditWork = nil; isRefreshingCredits = false
    }
    deinit { timer?.cancel(); providerWork?.cancel(); creditWork?.cancel() }
}
