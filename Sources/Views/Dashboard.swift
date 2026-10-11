import SwiftUI
import AppKit

private enum Palette {
    static let green = Color(red: 0.12, green: 0.64, blue: 0.46)
    static let gold = Color.orange
    static let red = Color.red
    static let track = Color.primary.opacity(0.12)
    static let panel = Color.primary.opacity(0.045)
}
struct GaugeBar: View {
    let percent: Double
    var color = Palette.green
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, percent.isFinite ? percent / 100 : 0)))
            }
        }.frame(height: 7).accessibilityHidden(true)
    }
}
struct MetricBar: View {
    let title: String
    let pct: Double
    let value: String
    let color: Color
    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 40, alignment: .leading)
            Text(String(format: "%.0f%%", pct)).monospacedDigit().frame(width: 43, alignment: .trailing)
            GaugeBar(percent: pct, color: color)
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: 94, alignment: .trailing)
        }.font(.system(size: 12)).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(Int(pct)) percent, \(value)")
    }
}
struct Dashboard: View {
    var expandedWindow = false
    @EnvironmentObject private var monitor: MonitorCoordinator
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var quotas: AIQuotaService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("AI Usage & System Monitor").font(.system(size: 17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Label(statusText, systemImage: "circle.fill").font(.caption)
                    .foregroundStyle(allOnline ? Palette.green : .secondary)
                if !expandedWindow {
                    Button { DashboardWindowManager.shared.show(prefs: prefs, monitor: monitor, quotas: quotas) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(.plain).help("Open a separate resizable dashboard")
                        .accessibilityLabel("Open expanded dashboard")
                }
            }
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AIUsageCard().environmentObject(quotas)
                        HStack {
                            Text("SSH Computers").font(.headline)
                            Spacer()
                            Toggle("Realtime", isOn: Binding(get: { monitor.realtime }, set: { prefs.realtime = $0; monitor.setRealtime($0) }))
                                .toggleStyle(.switch).font(.caption).accessibilityLabel("Realtime SSH sampling")
                                .help("Realtime: 1 second; normal: 10 seconds")
                            Text("\(monitor.effectiveInterval)s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).help("Refresh or reconnect SSH computers").accessibilityLabel("Refresh SSH computers")
                        }
                        if monitor.hosts.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "desktopcomputer").font(.title)
                                Text("Add an SSH computer in Settings.").foregroundStyle(.secondary)
                                Button("Open Settings") { SettingsWindowManager.shared.show(prefs: prefs, monitor: monitor) }
                            }.frame(maxWidth: .infinity).padding(24)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: expandedWindow && geometry.size.width >= 860 ? 2 : 1), alignment: .leading, spacing: 14) {
                                ForEach(monitor.hosts) { host in ServerCard(record: host) }
                            }
                        }
                    }.padding(.trailing, 4)
                }
            }
            HStack {
                Button { SettingsWindowManager.shared.show(prefs: prefs, monitor: monitor) } label: { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain)
                Spacer()
                Text("AI 5m · SSH \(monitor.effectiveInterval)s").font(.caption).foregroundStyle(.secondary)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
            }.font(.caption)
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(prefs.theme.colorScheme)
    }
    private var allOnline: Bool { !monitor.hosts.isEmpty && monitor.onlineCount == monitor.hosts.count }
    private var statusText: String {
        if monitor.hosts.isEmpty { return "No hosts" }
        return allOnline ? "Live" : "\(monitor.onlineCount)/\(monitor.hosts.count) online"
    }
}
private struct AIUsageCard: View {
    @EnvironmentObject private var quotas: AIQuotaService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI Usage").font(.headline)
                Spacer()
                Text(quotas.isRefreshing ? "Refreshing…" : "Every 5 minutes").font(.caption).foregroundStyle(.secondary)
                Button { Task { await quotas.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(quotas.isRefreshing)
                    .help("Refresh Codex and Claude usage").accessibilityLabel("Refresh AI usage")
            }
            ForEach(quotas.providers) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(provider.name).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if let updated = provider.updatedAt {
                            Text("Updated " + updated.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(window.name).font(.caption)
                                Spacer()
                                Text(String(format: "%.0f%% used", window.usedPercent)).font(.caption.monospacedDigit())
                            }
                            GaugeBar(percent: window.usedPercent, color: provider.isStale ? .secondary : window.usedPercent >= 95 ? Palette.red : window.usedPercent >= 80 ? Palette.gold : Palette.green)
                            if let reset = window.resetAt {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    Text(resetText(reset, now: context.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .help(reset.formatted(date: .complete, time: .standard))
                                }
                            }
                        }.accessibilityElement(children: .combine)
                    }
                    if provider.status != .connected {
                        Text((provider.isStale ? "Last known values · " : "") + provider.detail)
                            .font(.caption).foregroundStyle(provider.status == .authenticationRequired ? Palette.gold : .secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if provider.status == .authenticationRequired {
                            Button("Copy sign-in command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(provider.name == "Codex" ? "codex login" : "/login", forType: .string)
                            }.font(.caption).buttonStyle(.link)
                        }
                    }
                }
            }
        }.padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }
    private func resetText(_ reset: Date, now: Date) -> String {
        let minutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        if minutes == 0 { return "Reset due · refresh for the latest quota" }
        return "Resets in \(minutes / 60)h \(minutes % 60)m · " + reset.formatted(date: .abbreviated, time: .shortened)
    }
}
struct ServerCard: View {
    @ObservedObject var record: HostMonitor
    @State private var expanded = true
    @State private var showCores = false
    private var state: ServerViewState { record.state }
    private func gb(_ bytes: Int64?) -> String {
        guard let bytes else { return "N/A" }
        return String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
    }
    private var statusColor: Color {
        switch state.connection {
        case .connected: return Palette.green
        case .failed: return Palette.red
        case .stale, .connecting: return Palette.gold
        case .disconnected: return .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.id).font(.system(size: 15, weight: .semibold)).lineLimit(1).help(record.id)
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Label(state.connection.rawValue, systemImage: "circle.fill").font(.caption).foregroundStyle(statusColor)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(record.id), \(state.connection.rawValue), \(expanded ? "collapse" : "expand") details")
            if let error = state.error {
                Text(error).font(.caption).foregroundStyle(state.connection == .failed ? Palette.red : Palette.gold)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.gpuError, !error.isEmpty {
                Text("GPU metrics: " + error).font(.caption).foregroundStyle(Palette.gold).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                if let snapshot = state.snapshot {
                    Text(snapshot.cpu.model).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(snapshot.cpu.model)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("CPU").font(.subheadline.weight(.semibold))
                            if let temperature = snapshot.cpu.temperatureC { Text("\(Int(temperature))°C").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(snapshot.cpu.usagePercent.map { String(format: "%.0f%%", $0) } ?? "N/A").monospacedDigit()
                        }
                        GaugeBar(percent: snapshot.cpu.usagePercent ?? 0)
                        if !snapshot.cpu.logicalCoreUsage.isEmpty {
                            Button { showCores.toggle() } label: { Label(showCores ? "Hide CPU cores" : "Show CPU cores", systemImage: showCores ? "chevron.up" : "chevron.down") }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                            if showCores {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74))], spacing: 6) {
                                    ForEach(Array(snapshot.cpu.logicalCoreUsage.enumerated()), id: \.offset) { index, usage in
                                        HStack(spacing: 4) {
                                            Text("C\(index)").foregroundStyle(.secondary)
                                            Text(usage.map { String(format: "%.0f%%", $0) } ?? "—")
                                        }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 3)
                                    }
                                }
                            }
                        }
                        Divider()
                        if let ram = snapshot.ram {
                            HStack { Text("RAM").font(.subheadline.weight(.semibold)); Spacer(); Text(gb(ram.totalBytes) + " total").font(.caption).foregroundStyle(.secondary) }
                            MetricBar(title: "Used", pct: Double(ram.usedBytes) / Double(max(1, ram.totalBytes)) * 100, value: gb(ram.usedBytes), color: Palette.gold)
                            MetricBar(title: "Avail.", pct: Double(ram.availableBytes) / Double(max(1, ram.totalBytes)) * 100, value: gb(ram.availableBytes), color: Palette.green)
                        } else { Text("RAM unavailable on this OS").font(.caption).foregroundStyle(.secondary) }
                    }.padding(10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Text("NVIDIA GPUs").font(.subheadline.weight(.semibold)); Spacer()
                        Text("\(snapshot.gpus.count)/\(snapshot.gpuDetectedCount ?? snapshot.gpus.count) reporting").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.gpus) { gpu in GPUCard(gpu: gpu) }
                    if snapshot.gpus.isEmpty && state.gpuError == nil {
                        Text(state.gpuBackend == "nvml" ? "No NVIDIA GPUs detected" : "GPU metrics unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(state.connection == .connecting ? "Waiting for the first sample…" : "No sample received yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let received = state.receivedAt {
                    Text("Last sample " + received.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11)).foregroundStyle(state.connection == .connected ? Color.secondary : Palette.gold)
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }
    private var summary: String {
        guard let snapshot = state.snapshot else { return state.os ?? "Waiting for collector" }
        let cpu = snapshot.cpu.usagePercent.map { String(format: "%.0f%%", $0) } ?? "N/A"
        let ram = snapshot.ram.map { String(format: "%.0f%%", Double($0.usedBytes) / Double(max(1, $0.totalBytes)) * 100) } ?? "N/A"
        return "CPU \(cpu) · RAM \(ram) · \(snapshot.gpus.count) GPU"
    }
}
private struct GPUCard: View {
    let gpu: GPUInfo
    @State private var expanded = false
    private func gb(_ value: Int64?) -> String { value.map { String(format: "%.1f GiB", Double($0) / 1_073_741_824) } ?? "N/A" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("GPU \(gpu.index) · \(gpu.name)").lineLimit(1).help(gpu.name)
                        Spacer(minLength: 4)
                        Text(gpu.temperatureC.map { "\(Int($0))°C" } ?? "N/A").foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.font(.system(size: 12, weight: .medium))
                    HStack {
                        Text("Used \(gb(gpu.memoryUsedBytes))")
                        Spacer()
                        Text("Util " + (gpu.utilizationPercent.map { String(format: "%.0f%%", $0) } ?? "N/A"))
                    }.font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("GPU \(gpu.index), \(gpu.name), \(expanded ? "collapse" : "expand") details")
            GaugeBar(percent: gpu.utilizationPercent ?? 0, color: (gpu.utilizationPercent ?? 0) >= 90 ? Palette.red : Palette.green)
            if expanded, let total = gpu.memoryTotalBytes, total > 0 {
                MetricBar(title: "Used", pct: Double(gpu.memoryUsedBytes ?? 0) / Double(total) * 100, value: gb(gpu.memoryUsedBytes), color: Palette.gold)
                MetricBar(title: "Free", pct: Double(gpu.memoryFreeBytes ?? 0) / Double(total) * 100, value: gb(gpu.memoryFreeBytes), color: Palette.green)
                Text(gb(total) + " total").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}
