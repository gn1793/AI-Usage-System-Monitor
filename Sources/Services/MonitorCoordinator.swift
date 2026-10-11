import Foundation
import Combine

@MainActor
final class HostMonitor: ObservableObject, Identifiable {
    let id: String
    @Published fileprivate(set) var state: ServerViewState
    init(alias: String) { id = alias; state = ServerViewState(id: alias) }
}

@MainActor
final class MonitorCoordinator: ObservableObject {
    typealias SessionFactory = @MainActor (String, @escaping @Sendable (CollectorEvent) -> Void,
        @escaping @Sendable (Int32, String) -> Void) -> any MonitoringSession
    @Published private(set) var hosts: [HostMonitor] = []
    @Published private(set) var onlineCount = 0
    @Published private(set) var staleCount = 0
    @Published private(set) var realtime = false
    @Published private(set) var effectiveInterval = 10
    var states: [String: ServerViewState] { records.mapValues(\.state) }
    private struct Entry { var id: UUID; var session: any MonitoringSession; var startedAt: Date; var sequence = 0 }
    private var records: [String: HostMonitor] = [:]
    private var sessions: [String: Entry] = [:]
    private var retries: [String: Int] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var enabled = Set<String>()
    private var visibleSurfaces = Set<String>()
    private var energySaving = false
    private var allowReconnect = true
    private var sleeping = false
    private var watchdog: Task<Void, Never>?
    private let factory: SessionFactory

    init(sessionFactory: SessionFactory? = nil, startsWatchdog: Bool = true) {
        let source = Bundle.main.url(forResource: "monitor", withExtension: "py")
            .flatMap { try? Data(contentsOf: $0) } ?? Data()
        factory = sessionFactory ?? { alias, event, stop in
            SSHMonitor(alias: alias, source: source, onEvent: event, onStop: stop)
        }
        if startsWatchdog {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { break }
                    self?.checkStaleness(at: Date())
                }
            }
        }
    }

    func reconcile(_ configured: [HostRecord]) {
        let active = configured.filter(\.enabled)
        enabled = Set(active.map(\.alias))
        for alias in Array(records.keys) where !enabled.contains(alias) {
            cancelRetry(alias)
            let old = sessions.removeValue(forKey: alias)
            old?.session.stop()
            records.removeValue(forKey: alias); retries.removeValue(forKey: alias)
        }
        for host in active where records[host.alias] == nil { records[host.alias] = HostMonitor(alias: host.alias) }
        hosts = active.compactMap { records[$0.alias] }
        for host in active where sessions[host.alias] == nil && retryTasks[host.alias] == nil { connect(host.alias) }
        updateCounts()
    }

    private func connect(_ alias: String) {
        guard allowReconnect, !sleeping, enabled.contains(alias), sessions[alias] == nil else { return }
        let id = UUID()
        let session = factory(alias, { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(alias, id: id, event: event) }
        }, { [weak self] code, detail in
            Task { @MainActor [weak self] in self?.stopped(alias, id: id, code: code, detail: detail) }
        })
        sessions[alias] = Entry(id: id, session: session, startedAt: Date())
        mutate(alias) { $0.connection = .connecting; $0.error = nil }
        do { try session.start(); session.send(["command": "set_interval", "seconds": effectiveInterval]) }
        catch {
            sessions.removeValue(forKey: alias); session.stop()
            failed(alias, "SSH could not start: \(error.localizedDescription)")
        }
    }

    private func receive(_ alias: String, id: UUID, event: CollectorEvent) {
        guard enabled.contains(alias), sessions[alias]?.id == id else { return }
        switch event {
        case .snapshot(let snapshot):
            guard snapshot.sequence > (sessions[alias]?.sequence ?? 0) else { return }
            sessions[alias]?.sequence = snapshot.sequence
            mutate(alias) {
                $0.snapshot = snapshot; $0.receivedAt = Date(); $0.connection = .connected; $0.error = nil
                $0.gpuBackend = snapshot.gpuBackend ?? $0.gpuBackend
                $0.gpuError = snapshot.gpuError
            }
            retries[alias] = 0
        case .hello(let message):
            mutate(alias) { $0.os = message.os; $0.gpuBackend = message.gpuBackend; $0.gpuError = message.gpuError }
        case .error(let message): mutate(alias) { $0.error = message }
        }
    }

    private func stopped(_ alias: String, id: UUID, code: Int32, detail: String) {
        guard enabled.contains(alias), sessions[alias]?.id == id, allowReconnect, !sleeping else { return }
        sessions.removeValue(forKey: alias)
        failed(alias, "SSH exited (\(code)). " + (detail.isEmpty ? "Check SSH login and remote Python 3." : detail))
    }

    private func failed(_ alias: String, _ message: String) {
        mutate(alias) { $0.connection = .failed; $0.error = message }
        scheduleRetry(alias)
    }
    private func mutate(_ alias: String, _ update: (inout ServerViewState) -> Void) {
        guard let record = records[alias] else { return }
        var state = record.state; update(&state); record.state = state
        updateCounts()
    }
    private func updateCounts() {
        let online = records.values.filter { $0.state.connection == .connected }.count
        let stale = records.values.filter { $0.state.connection == .stale }.count
        if onlineCount != online { onlineCount = online }
        if staleCount != stale { staleCount = stale }
    }
    private func cancelRetry(_ alias: String) { retryTasks.removeValue(forKey: alias)?.cancel() }
    private func scheduleRetry(_ alias: String) {
        guard allowReconnect, !sleeping, enabled.contains(alias) else { return }
        cancelRetry(alias)
        let attempt = min(5, (retries[alias] ?? 0) + 1); retries[alias] = attempt
        let delay = Double(min(60, 5 * (1 << (attempt - 1)))) + Double.random(in: 0...1)
        retryTasks[alias] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            retryTasks.removeValue(forKey: alias)
            connect(alias)
        }
    }

    func checkStaleness(at now: Date) {
        guard !sleeping else { return }
        let threshold = Double(max(35, effectiveInterval * 3))
        for (alias, entry) in Array(sessions) {
            // A retained sample belongs to the previous connection until this
            // generation supplies one. Give the replacement its startup grace.
            let last = max(records[alias]?.state.receivedAt ?? entry.startedAt, entry.startedAt)
            guard now.timeIntervalSince(last) > threshold else { continue }
            sessions.removeValue(forKey: alias); entry.session.stop()
            mutate(alias) { $0.connection = .stale; $0.error = "No recent data. Reconnecting…" }
            scheduleRetry(alias)
        }
    }
    func setRealtime(_ value: Bool) { realtime = value; updateInterval() }
    func setEnergySaving(_ value: Bool) { energySaving = value; updateInterval() }
    func setSurface(_ name: String, visible: Bool) {
        if visible { visibleSurfaces.insert(name) } else { visibleSurfaces.remove(name) }
        updateInterval()
    }
    private func updateInterval() {
        let interval = energySaving && visibleSurfaces.isEmpty ? 60 : realtime ? 1 : 10
        guard interval != effectiveInterval else { return }
        let faster = interval < effectiveInterval; effectiveInterval = interval
        for entry in sessions.values {
            entry.session.send(["command": "set_interval", "seconds": interval])
            if faster { entry.session.send(["command": "refresh"]) }
        }
    }
    func refresh() {
        for alias in enabled {
            if let entry = sessions[alias] { entry.session.send(["command": "refresh"]) }
            else { cancelRetry(alias); connect(alias) }
        }
    }
    func suspend() {
        sleeping = true
        for task in retryTasks.values { task.cancel() }; retryTasks.removeAll()
        let old = sessions; sessions.removeAll()
        for entry in old.values { entry.session.stop() }
        for alias in enabled { mutate(alias) { $0.connection = .disconnected } }
    }
    func resume() { sleeping = false; for alias in enabled { connect(alias) } }
    func shutdown() {
        allowReconnect = false; watchdog?.cancel(); watchdog = nil
        for task in retryTasks.values { task.cancel() }; retryTasks.removeAll()
        let old = sessions; sessions.removeAll()
        for entry in old.values { entry.session.stop() }
    }
    deinit { watchdog?.cancel(); for task in retryTasks.values { task.cancel() } }
}
