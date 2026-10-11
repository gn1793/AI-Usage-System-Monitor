import AppKit
import SwiftUI

@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?
    func show(prefs: Preferences, monitor: MonitorCoordinator) {
        if let window { constrain(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = SettingsView().environmentObject(prefs).environmentObject(monitor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Monitor Settings"; window.contentView = NSHostingView(rootView: view)
        window.contentMinSize = NSSize(width: 460, height: 500)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.setFrameAutosaveName("AIUsageSystemMonitorSettings")
        if !window.setFrameUsingName("AIUsageSystemMonitorSettings") { window.center() }
        self.window = window
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.constrain() }
        }
        constrain(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func constrain() {
        guard let window, let screen = WindowGeometry.screen(for: window.frame) else { return }
        window.contentMinSize = NSSize(width: min(460, screen.visibleFrame.width), height: min(500, screen.visibleFrame.height - 28))
        window.setFrame(WindowGeometry.constrain(window.frame, to: screen.visibleFrame), display: window.isVisible)
    }
    func windowDidChangeScreen(_ notification: Notification) { constrain() }
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil; window = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
    }
}
