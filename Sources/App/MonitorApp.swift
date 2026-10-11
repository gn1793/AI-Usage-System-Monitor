import AppKit
import Combine

@MainActor
final class MonitorApplicationDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private let monitor = MonitorCoordinator()
    private let quotas = AIQuotaService()
    private var status: StatusItemController?
    private var subscriptions = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController(prefs: prefs, monitor: monitor, quotas: quotas)
        monitor.setRealtime(prefs.realtime); monitor.setEnergySaving(prefs.energySaving)
        monitor.reconcile(prefs.hosts); quotas.start()
        prefs.$hosts.dropFirst().sink { [weak self] hosts in self?.monitor.reconcile(hosts) }.store(in: &subscriptions)
        prefs.$energySaving.dropFirst().sink { [weak self] value in self?.monitor.setEnergySaving(value) }.store(in: &subscriptions)
        prefs.$realtime.dropFirst().sink { [weak self] value in self?.monitor.setRealtime(value) }.store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.monitor.suspend(); self?.quotas.stop() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.monitor.resume(); self?.quotas.start() }
        })
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        status?.shutdown(); quotas.stop(); monitor.shutdown()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll(); subscriptions.removeAll()
    }
}

@main struct MonitorApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = MonitorApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
