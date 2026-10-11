import Foundation
import Combine

@MainActor
final class AIQuotaService: ObservableObject {
    @Published private(set) var providers: [ProviderState] = ProviderKind.allCases.map { ProviderState(name: $0.rawValue) }
    @Published private(set) var isRefreshing = false
    private let fetcher: any QuotaFetching
    private var timer: Task<Void, Never>?
    private var inFlight: Task<[ProviderState], Never>?
    private var generation = UUID()
    init(fetcher: any QuotaFetching = QuotaClient()) { self.fetcher = fetcher }
    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(300)) } catch { break }
            }
        }
    }
    func stop() {
        generation = UUID(); timer?.cancel(); timer = nil
        inFlight?.cancel(); inFlight = nil; isRefreshing = false
    }
    func refresh() async {
        if let inFlight { _ = await inFlight.value; return }
        let fetcher = self.fetcher, id = generation
        let work = Task {
            async let codex = fetcher.fetch(.codex)
            async let claude = fetcher.fetch(.claude)
            return await [codex, claude]
        }
        inFlight = work; isRefreshing = true
        let results = await work.value
        guard generation == id, !work.isCancelled else { return }
        providers = results.map { result in
            var state = result
            if result.status != .connected, let previous = providers.first(where: { $0.name == result.name }) {
                state.windows = previous.windows; state.updatedAt = previous.updatedAt
            }
            return state
        }
        inFlight = nil; isRefreshing = false
    }
    deinit { timer?.cancel(); inFlight?.cancel() }
}
