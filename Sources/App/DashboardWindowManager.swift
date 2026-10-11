import AppKit
import SwiftUI

@MainActor
final class DashboardWindowManager: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowManager()
    private var window: NSWindow?
    private weak var monitor: MonitorCoordinator?
    private var screenObserver: NSObjectProtocol?

    func show(prefs: Preferences, monitor: MonitorCoordinator, quotas: AIQuotaService) {
        self.monitor = monitor
        if window == nil {
            let view = Dashboard(expandedWindow: true).environmentObject(prefs).environmentObject(monitor).environmentObject(quotas)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "AI Usage & System Monitor"
            window.contentView = NSHostingView(rootView: view)
            window.contentMinSize = NSSize(width: 460, height: 400)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.setFrameAutosaveName("AIUsageSystemMonitorDashboard")
            if !window.setFrameUsingName("AIUsageSystemMonitorDashboard") { window.center() }
            self.window = window
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.constrain() }
            }
        }
        constrain()
        monitor.setSurface("expanded", visible: true)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func constrain() {
        guard let window, let screen = WindowGeometry.screen(for: window.frame) else { return }
        window.contentMinSize = NSSize(width: min(460, screen.visibleFrame.width), height: min(400, screen.visibleFrame.height - 28))
        window.setFrame(WindowGeometry.constrain(window.frame, to: screen.visibleFrame), display: window.isVisible)
    }
    func windowDidChangeScreen(_ notification: Notification) { constrain() }
    func windowDidMiniaturize(_ notification: Notification) { monitor?.setSurface("expanded", visible: false) }
    func windowDidDeminiaturize(_ notification: Notification) { monitor?.setSurface("expanded", visible: true) }
    func windowWillClose(_ notification: Notification) {
        monitor?.setSurface("expanded", visible: false)
        // Keep at most one native window; release the entire hidden SwiftUI tree.
        window?.contentView = nil; window = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
    }
}
