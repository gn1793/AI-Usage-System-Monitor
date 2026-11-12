import Foundation

protocol BraveGrantReading: Sendable { func read() async throws -> Data }

struct AppleEventBraveGrantReader: BraveGrantReading {
    var scriptURL: URL? = Bundle.main.url(forResource: "ReadOpenAICreditGrants", withExtension: "js")
    func read() async throws -> Data {
        guard let scriptURL else { throw BraveGrantError.scriptMissing }
        let process = Process()
        let work = Task.detached {
            try Task.checkCancellation()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", scriptURL.path]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timeout.schedule(deadline: .now() + 35)
            timeout.setEventHandler { if process.isRunning { process.terminate() } }
            timeout.resume()
            defer { timeout.cancel() }
            try process.run()
            if Task.isCancelled { process.terminate() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0, !data.isEmpty, data.count <= 1_048_576 else { throw BraveGrantError.browserUnavailable }
            return data
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
            if process.isRunning { process.terminate() }
        }
    }
}

enum BraveGrantError: Error { case scriptMissing, browserUnavailable, malformed }

actor BraveCreditGrantClient {
    private let reader: any BraveGrantReading
    init(reader: any BraveGrantReading = AppleEventBraveGrantReader()) { self.reader = reader }
    func fetch(now: Date) async -> OpenAICreditState {
        do {
            try Task.checkCancellation()
            let data = try await reader.read()
            try Task.checkCancellation()
            return try BraveGrantParser.parse(data, now: now)
        } catch {
            return OpenAICreditState(status: .unavailable, detail: "Brave Credit Grants could not be read. Open the Billing tab and refresh. If macOS asks to control Brave, allow this app in Privacy & Security → Automation.")
        }
    }
}

enum BraveGrantParser {
    static func parse(_ data: Data, now: Date) throws -> OpenAICreditState {
        struct Payload: Decodable {
            var error: String?
            var currency: String?
            var rows: [[String]]?
            var capturedAt: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        if let error = payload.error { return failure(error) }
        guard payload.currency == "USD", let rows = payload.rows else { throw BraveGrantError.malformed }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "MMM d, yyyy"; formatter.isLenient = false
        var grants: [OpenAICreditGrant] = []
        for row in rows {
            guard row.count == 4, !row[1].isEmpty else { throw BraveGrantError.malformed }
            // Historical grants can have other states and different field formats.
            // Only Available rows contribute to the balance or grant details.
            guard row[1].lowercased() == "available" else { continue }
            guard let received = formatter.date(from: row[0]) else { throw BraveGrantError.malformed }
            let amounts = row[2].components(separatedBy: "/")
            guard amounts.count == 2, let remaining = amount(amounts[0]), let total = amount(amounts[1]),
                  total > 0, remaining >= 0, remaining <= total else { throw BraveGrantError.malformed }
            let expiry: Date?
            if ["never", "no expiry", "—", "-"].contains(row[3].lowercased()) { expiry = nil }
            else {
                guard let date = formatter.date(from: row[3]) else { throw BraveGrantError.malformed }
                expiry = date
            }
            grants.append(OpenAICreditGrant(receivedAt: received, state: row[1], remaining: remaining, total: total, expiresAt: expiry))
        }
        // The website's state is authoritative. A displayed expiry date has no
        // time-of-day; do not expire an available grant at local midnight.
        let available = grants.filter(\.isAvailable)
        let total = available.reduce(0) { $0 + $1.total }
        let remaining = available.reduce(0) { $0 + $1.remaining }
        guard total.isFinite, remaining.isFinite else { throw BraveGrantError.malformed }
        var configuration = OpenAICreditConfiguration.braveSession
        configuration.total = total; configuration.manualRemaining = remaining
        configuration.startsAt = available.map(\.receivedAt).min() ?? now
        configuration.expiresAt = available.compactMap(\.expiresAt).min() ?? .distantFuture
        configuration.savedAt = now
        let detail = available.isEmpty ? "No available credit grants" : "\(available.count) available grant\(available.count == 1 ? "" : "s") · Brave Credit Grants"
        return OpenAICreditState(snapshot: OpenAICreditSnapshot(configuration: configuration, used: max(0, total - remaining), grants: grants),
                                status: .connected, detail: detail, updatedAt: now)
    }
    private static func amount(_ string: String) -> Double? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^\$(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        let digits = value.dropFirst().replacingOccurrences(of: ",", with: "")
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let number = Double(digits), number.isFinite else { return nil }
        return number
    }
    private static func failure(_ error: String) -> OpenAICreditState {
        let detail: String
        switch error {
        case "browser_not_running": detail = "Open Brave and sign in to OpenAI Billing, then refresh."
        case "tab_missing": detail = "Open the Credit Grants tab in Brave and keep it open for automatic refresh."
        case "multiple_tabs": detail = "More than one Credit Grants tab is open. Keep one tab open so the selected organization is unambiguous."
        case "javascript_disabled": detail = "In Brave, enable View → Developer → Allow JavaScript from Apple Events, then refresh."
        case "automation_denied": detail = "Allow this app to control Brave in macOS System Settings → Privacy & Security → Automation."
        case "login_required": detail = "Your Billing session needs sign-in. Sign in in Brave, then refresh."
        case "unsupported_currency": detail = "The Credit Grants page did not report USD. Open Billing and check the selected organization."
        default: detail = "The Credit Grants table did not load. Open the tab in Brave and refresh."
        }
        return OpenAICreditState(status: ["table_not_ready", "browser_error", "unsupported_currency"].contains(error) ? .unavailable : .authenticationRequired, detail: detail)
    }
}
