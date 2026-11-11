import SwiftUI
import AppKit

struct OpenAICreditSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var quotas: AIQuotaService
    @State private var source = OpenAICreditSource.brave
    @State private var total = ""
    @State private var remaining = ""
    @State private var startsAt = Calendar.current.startOfDay(for: .now)
    @State private var expiresAt = Calendar.current.startOfDay(for: .now).addingTimeInterval(30 * 86_400)
    @State private var organizationID = ""
    @State private var adminKey = ""
    @State private var detection: OpenAICredentialDetection?
    @State private var isDetecting = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        GroupBox("OpenAI API credits") {
            VStack(alignment: .leading, spacing: 12) {
                Text(source == .brave ? "Read the actual balance, grant total and expiry from your signed-in OpenAI Credit Grants tab in Brave. No API key or manual amounts are needed." : "Enter the credit grant shown in OpenAI Billing. Costs API mode estimates the balance from organization costs.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Balance source", selection: $source) {
                    ForEach(OpenAICreditSource.allCases) { Text($0.title).tag($0) }
                }
                if source == .brave {
                    Button("Open Credit Grants in Brave") { Task { await openBrave() } }
                    Text("Open the Credit Grants tab when you want to update your balance, then press the refresh button beside Every 5 minutes in AI Usage. The app reads the organization selected in Billing. Startup and automatic polling do not access Brave.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("In Brave: View → Developer → Allow JavaScript from Apple Events. If macOS asks to control Brave, allow it in Privacy & Security → Automation.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if prefs.openAICredits?.source == .brave {
                        Label(quotas.openAICredits.detail, systemImage: quotas.openAICredits.status == .connected ? "checkmark.circle" : "info.circle")
                            .font(.caption).foregroundStyle(quotas.openAICredits.status == .connected ? Color.green : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack {
                        Text("Total credits (USD)").frame(width: 150, alignment: .leading)
                        TextField("Amount from Billing", text: $total).textFieldStyle(.roundedBorder)
                    }
                    if source == .manual {
                        HStack {
                            Text("Remaining (USD)").frame(width: 150, alignment: .leading)
                            TextField("Current balance", text: $remaining).textFieldStyle(.roundedBorder)
                        }
                        Text("Manual values stay as entered until you update them. Expired grants show a zero balance.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    DatePicker("Credit start", selection: $startsAt, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Expires", selection: $expiresAt, displayedComponents: [.date, .hourAndMinute])
                }
                if source == .costsAPI {
                    TextField("Organization ID (optional, org-…)", text: $organizationID).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("OpenAI organization ID")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Label(isDetecting ? "Detecting credentials…" : detection?.title ?? "Detecting credentials…",
                                  systemImage: detection?.adminSource != nil ? "checkmark.shield" : "key")
                                .font(.subheadline).foregroundStyle(detection?.adminSource != nil ? Color.green : .orange)
                            Spacer(minLength: 8)
                            Button("Detect again") { Task { await detectCredentials(refresh: true) } }
                                .disabled(isSaving || isDetecting)
                        }
                        if let detection {
                            Text(detection.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    DisclosureGroup("Use a different Admin API key (optional)") {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("Admin API key", text: $adminKey)
                                .textFieldStyle(.roundedBorder).accessibilityLabel("Optional OpenAI Admin API key")
                            HStack {
                                Link("Create an Admin API key", destination: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!)
                                Spacer()
                                if detection?.hasSavedKey == true {
                                    Button("Remove saved key") { Task { await removeKey() } }.disabled(isSaving || isDetecting)
                                }
                            }.font(.caption)
                        }.padding(.top, 6)
                    }
                    Text("A detected Admin API key is used without copying. A key entered here is stored in macOS Keychain. Costs are queried on manual refresh and can be delayed; overlapping grants and billing adjustments can affect the estimate.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(isSaving ? "Refreshing…" : source == .brave ? "Connect & refresh" : "Save & refresh") { Task { await save() } }.disabled(isSaving || isDetecting)
                    if prefs.openAICredits != nil {
                        Button("Clear credit settings") {
                            prefs.openAICredits = nil; quotas.configureCredits(nil)
                            total = ""; remaining = ""; message = "Credit settings cleared."; error = nil
                        }.disabled(isSaving)
                    }
                    Spacer()
                    Link("Open Billing", destination: URL(string: "https://platform.openai.com/settings/organization/billing/credit-grants")!)
                }
            }.padding(8)
        }.task {
            if let configuration = prefs.openAICredits {
                source = configuration.source
                if source != .brave {
                    total = String(configuration.total); remaining = String(configuration.manualRemaining)
                    startsAt = configuration.startsAt; expiresAt = configuration.expiresAt; organizationID = configuration.organizationID
                }
            }
            if source == .costsAPI { await detectCredentials() }
        }.onChange(of: source) { _, value in
            if value == .costsAPI { Task { await detectCredentials() } }
        }
    }
    private func amount(_ text: String) -> Double? {
        // Accept the user's decimal separator, but reject partially parsed input.
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(value), number.isFinite { return number }
        let separator = Locale.current.decimalSeparator ?? "."
        guard separator != ".", let number = Double(value.replacingOccurrences(of: separator, with: ".")), number.isFinite else { return nil }
        return number
    }
    private func save() async {
        error = nil; message = nil
        if source == .brave {
            isSaving = true
            defer { isSaving = false }
            let configuration = OpenAICreditConfiguration.braveSession
            prefs.openAICredits = configuration; quotas.configureCredits(configuration, force: true)
            await quotas.refreshCredits()
            message = quotas.openAICredits.status == .connected ? "Connected to Brave Credit Grants." : quotas.openAICredits.detail
            return
        }
        guard let totalAmount = amount(total) else { error = "Enter a valid credit total in USD."; return }
        var remainingAmount = totalAmount
        if source == .manual {
            guard let value = amount(remaining) else { error = "Enter a valid remaining balance in USD."; return }
            remainingAmount = value
        }
        let configuration = OpenAICreditConfiguration(source: source, total: totalAmount, manualRemaining: remainingAmount,
            startsAt: startsAt, expiresAt: expiresAt, organizationID: organizationID.trimmingCharacters(in: .whitespacesAndNewlines), savedAt: .now)
        if let problem = configuration.validationError() { error = problem; return }
        isSaving = true
        defer { isSaving = false }
        if source == .costsAPI {
            let key = adminKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                guard key.hasPrefix("sk-"), !key.contains(where: { $0.isWhitespace }) else {
                    error = "Enter a valid Admin API key from OpenAI organization settings."; return
                }
                do { try await OpenAIAdminCredentialStore.shared.save(key) }
                catch { self.error = "The Admin API key could not be saved to Keychain."; return }
                adminKey = ""
            }
            let found = await OpenAIAdminCredentialStore.shared.detect()
            detection = found
            guard found.adminSource != nil else {
                error = found.title + ". " + found.detail; return
            }
        }
        prefs.openAICredits = configuration
        quotas.configureCredits(configuration)
        await quotas.refreshCredits()
        message = source == .manual ? "Manual balance saved." : quotas.openAICredits.status == .connected ? "Credits saved. Costs refreshed." : "Settings saved. " + quotas.openAICredits.detail
    }
    private func removeKey() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await OpenAIAdminCredentialStore.shared.remove()
            adminKey = ""; error = nil; message = "Saved Admin API key removed."
            detection = await OpenAIAdminCredentialStore.shared.detect()
            quotas.configureCredits(prefs.openAICredits, force: true)
            if prefs.openAICredits?.source == .costsAPI { await quotas.refreshCredits() }
        } catch { self.error = "The saved key could not be removed from Keychain." }
    }
    private func detectCredentials(refresh: Bool = false) async {
        isDetecting = true
        defer { isDetecting = false }
        detection = await OpenAIAdminCredentialStore.shared.detect()
        if refresh, prefs.openAICredits?.source == .costsAPI {
            quotas.configureCredits(prefs.openAICredits, force: true)
            await quotas.refreshCredits()
        }
    }
    private func openBrave() async {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser") else {
            error = "Brave Browser is not installed."; return
        }
        do {
            _ = try await NSWorkspace.shared.open([URL(string: "https://platform.openai.com/settings/organization/billing/credit-grants")!],
                withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } catch { self.error = "Brave could not be opened. Open the Credit Grants page manually." }
    }
}
