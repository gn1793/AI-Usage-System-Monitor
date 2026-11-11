import SwiftUI
import AppKit

enum AIUsageStyle {
    static let green = Color(red: 0.34, green: 0.59, blue: 0.42)
    static let track = Color.primary.opacity(0.12)
}

struct AIUsageCard: View {
    @EnvironmentObject private var quotas: AIQuotaService
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var monitor: MonitorCoordinator
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Text("AI Usage").font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 8)
                Text(quotas.isRefreshing ? "Refreshing…" : "Every 5 minutes")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .help("Codex and Claude refresh every 5 minutes. OpenAI credits update when you press refresh.")
                Button { Task { await quotas.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                }.buttonStyle(.plain).disabled(quotas.isRefreshingCredits)
                    .help("Refresh Codex, OpenAI credits and Claude now")
                    .accessibilityLabel("Refresh AI usage and OpenAI credits now")
            }
            ForEach(quotas.providers.filter { $0.name == ProviderKind.codex.rawValue }) { provider in
                ProviderUsageSection(provider: provider)
            }
            Divider().opacity(0.5)
            OpenAICreditCard(state: quotas.openAICredits, isRefreshing: quotas.isRefreshingCredits) {
                SettingsWindowManager.shared.show(prefs: prefs, monitor: monitor, quotas: quotas)
            }
            Divider().opacity(0.5)
            ForEach(quotas.providers.filter { $0.name == ProviderKind.claude.rawValue }) { provider in
                ProviderUsageSection(provider: provider)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(colorScheme == .dark ? Color(white: 0.075) : Color(white: 0.975), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ProviderUsageSection: View {
    let provider: ProviderState
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(provider.name).font(.system(size: 18, weight: .semibold))
                    Spacer(minLength: 8)
                    if let updated = provider.updatedAt {
                        Text("Updated " + updated.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(window.name)
                            Spacer()
                            Text(String(format: "%.0f%% used", window.usedPercent)).monospacedDigit()
                        }.font(.system(size: 14))
                        GaugeBar(percent: window.usedPercent,
                            color: provider.isStale ? .secondary : window.usedPercent >= 95 ? .red : window.usedPercent >= 80 ? .orange : AIUsageStyle.green,
                            height: 8)
                        if let reset = window.resetAt {
                            Text(QuotaResetFormatter.text(reset, now: context.date))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .help(reset.formatted(date: .complete, time: .standard))
                        }
                    }.accessibilityElement(children: .combine)
                }
                if provider.status != .connected {
                    Text((provider.isStale ? "Last known values · " : "") + provider.detail)
                        .font(.caption).foregroundStyle(provider.status == .authenticationRequired ? Color.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if provider.status == .authenticationRequired {
                        Button("Copy sign-in command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(provider.name == ProviderKind.codex.rawValue ? "codex login" : "/login", forType: .string)
                        }.font(.caption).buttonStyle(.link)
                    }
                }
            }
        }
    }
}
