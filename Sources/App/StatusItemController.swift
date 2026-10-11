import AppKit
import SwiftUI
import Combine

final class DashboardPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let item: NSStatusItem
    private let prefs: Preferences
    private let monitor: MonitorCoordinator
    private let quotas: AIQuotaService
    private var panel: DashboardPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var globalClicks: Any?
    private var localClicks: Any?
    private var screenObserver: NSObjectProtocol?
    private var applyingSize = false

    init(prefs: Preferences, monitor: MonitorCoordinator, quotas: AIQuotaService) {
        self.prefs = prefs; self.monitor = monitor; self.quotas = quotas
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            let image = Bundle.main.url(forResource: "MenuCat", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) } ?? NSImage(named: "MenuCat")
                ?? NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Monitor")
            image?.isTemplate = true; image?.size = NSSize(width: 18, height: 18)
            button.image = image; button.toolTip = "AI Usage & System Monitor"
            button.setAccessibilityLabel("AI Usage & System Monitor")
            button.target = self; button.action = #selector(toggle)
        }
        prefs.$popupHeight.combineLatest(prefs.$popupWidth).dropFirst().sink { [weak self] height, width in
            self?.applySize(NSSize(width: width, height: height))
        }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.adjustForScreen() }
        }
    }

    @objc private func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }
    private func show() {
        if panel == nil {
            let panel = DashboardPanel(contentRect: NSRect(x: 0, y: 0, width: prefs.popupWidth, height: prefs.popupHeight),
                styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "AI Usage & System Monitor"
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(kind)?.isHidden = true }
            panel.contentView = NSHostingView(rootView: Dashboard().environmentObject(prefs).environmentObject(monitor).environmentObject(quotas))
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.delegate = self; panel.onEscape = { [weak self] in self?.hide() }
            self.panel = panel
        }
        applySize(NSSize(width: prefs.popupWidth, height: prefs.popupHeight))
        positionBelowStatusItem()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        monitor.setSurface("popup", visible: true)
        installClickMonitors()
    }
    func hide() {
        panel?.orderOut(nil); removeClickMonitors()
        monitor.setSurface("popup", visible: false)
    }
    private func applySize(_ size: NSSize) {
        guard !applyingSize, let panel else { return }
        applyingSize = true
        defer { applyingSize = false }
        let screen = item.button?.window?.screen ?? panel.screen ?? NSScreen.main
        if let screen {
            panel.contentMinSize = NSSize(width: min(420, screen.visibleFrame.width), height: min(350, screen.visibleFrame.height - 28))
            panel.maxSize = screen.visibleFrame.size
        }
        panel.setContentSize(size)
        if let screen { panel.setFrame(WindowGeometry.constrain(panel.frame, to: screen.visibleFrame), display: panel.isVisible) }
    }
    private func positionBelowStatusItem() {
        guard let panel, let button = item.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var frame = panel.frame
        frame.origin = NSPoint(x: anchor.midX - frame.width / 2, y: anchor.minY - frame.height - 5)
        if let screen = buttonWindow.screen ?? NSScreen.main { frame = WindowGeometry.constrain(frame, to: screen.visibleFrame) }
        panel.setFrame(frame, display: false)
    }
    private func adjustForScreen() {
        applySize(NSSize(width: prefs.popupWidth, height: prefs.popupHeight))
        if panel?.isVisible == true { positionBelowStatusItem() }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, !applyingSize else { return }
        applyingSize = true
        prefs.savePanelSize(panel.contentRect(forFrameRect: panel.frame).size)
        applyingSize = false
        adjustForScreen()
    }
    func windowDidResignKey(_ notification: Notification) { hide() }
    func windowWillClose(_ notification: Notification) { hide() }
    private func installClickMonitors() {
        removeClickMonitors()
        globalClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }
        localClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.item.button?.window { self.hide() }
            }
            return event
        }
    }
    private func removeClickMonitors() {
        if let globalClicks { NSEvent.removeMonitor(globalClicks) }; globalClicks = nil
        if let localClicks { NSEvent.removeMonitor(localClicks) }; localClicks = nil
    }
    func shutdown() {
        hide(); subscriptions.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.contentView = nil; panel = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}
