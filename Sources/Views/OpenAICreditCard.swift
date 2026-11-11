import SwiftUI

struct OpenAICreditCard: View {
    let state: OpenAICreditState
    var isRefreshing = false
    let configure: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        title
                        Spacer(minLength: 8)
                        expiry(now: context.date)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        title
                        expiry(now: context.date)
                    }
                }
                if let snapshot = state.snapshot {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(money(snapshot.remaining(at: context.date)))
                            .font(.system(size: 22, weight: .semibold))
                        Text("/ " + money(snapshot.configuration.total) + " remaining")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(String(format: "%.1f%% used", snapshot.consumedPercent))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                        .accessibilityElement(children: .combine)
                    GaugeBar(percent: snapshot.consumedPercent,
                        color: lastKnown(now: context.date) || snapshot.isExpired(at: context.date) ? Color(white: 0.55) : AIUsageStyle.green,
                        height: 8)
                } else {
                    Text("— / — remaining").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                    GaugeBar(percent: 0, height: 8)
                }
                HStack(spacing: 10) {
                    status(now: context.date)
                    Spacer(minLength: 6)
                    Link(destination: URL(string: "https://platform.openai.com/settings/organization/billing/credit-grants")!) {
                        HStack(spacing: 5) {
                            Text("Billing")
                            Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                        }.font(.system(size: 13)).padding(.horizontal, 11).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("Open OpenAI Credit Grants")
                    Button(action: configure) { Image(systemName: "gearshape").font(.system(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("OpenAI credit settings").accessibilityLabel("OpenAI credit settings")
                }
                if state.snapshot == nil {
                    Text(state.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let snapshot = state.snapshot, snapshot.grants.count > 1 {
                    DisclosureGroup("\(snapshot.grants.count) credit grants") {
                        ForEach(Array(snapshot.grants.enumerated()), id: \.offset) { _, grant in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(grant.state)
                                    Text(grant.expiresAt.map { "Expires " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "No expiry date")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(money(grant.remaining) + " / " + money(grant.total)).monospacedDigit()
                            }.font(.caption).padding(.top, 6)
                        }
                    }.font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var title: some View {
        HStack(spacing: 8) {
            Text("OpenAI API").font(.system(size: 16, weight: .medium))
            if let snapshot = state.snapshot {
                let direct = snapshot.configuration.source == .brave
                Text(direct ? "Credit Grants" : snapshot.configuration.source == .costsAPI ? "Estimated" : "Manual")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(direct ? AIUsageStyle.green : .orange)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((direct ? AIUsageStyle.green : Color.orange).opacity(0.15), in: Capsule())
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    @ViewBuilder private func expiry(now: Date) -> some View {
        if let snapshot = state.snapshot, let date = snapshot.displayExpiry {
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
            HStack(spacing: 8) {
                Text(snapshot.isExpired(at: now) ? "Expired" : days < 0 ? "D+\(-days)" : days == 0 ? "D-Day" : "D-\(days)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(days <= 7 ? Color.orange : .secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((days <= 7 ? Color.orange : Color.secondary).opacity(0.14), in: Capsule())
                Text(date.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month(.abbreviated).day()) + " 만료")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.fixedSize().help(date.formatted(date: .complete, time: snapshot.configuration.source == .brave ? .omitted : .shortened))
        }
    }
    private func lastKnown(now: Date) -> Bool {
        state.isStale || state.updatedAt.map { now.timeIntervalSince($0) >= 300 } == true
    }
    private func status(now: Date) -> some View {
        HStack(spacing: 5) {
            if isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Refreshing…")
            } else {
                if lastKnown(now: now) || (state.status != .connected && state.status != .waiting) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
                if let updated = state.updatedAt {
                    Text((lastKnown(now: now) ? "Last known · " : "Updated · ") + updated.formatted(date: .omitted, time: .shortened))
                        .help(updated.formatted(date: .complete, time: .shortened))
                } else { Text("Not checked yet") }
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            .help(state.detail).accessibilityHint(state.detail)
    }
    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}
