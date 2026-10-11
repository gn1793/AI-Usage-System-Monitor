import Foundation
import Combine
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var hosts: [HostRecord] = [] { didSet { saveHosts() } }
    @Published var popupHeight: Double { didSet { defaults.set(popupHeight, forKey: "popup.height") } }
    @Published var popupWidth: Double { didSet { defaults.set(popupWidth, forKey: "popup.width") } }
    @Published var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "appearance.theme") } }
    @Published var energySaving: Bool { didSet { defaults.set(energySaving, forKey: "monitor.energySaving") } }
    @Published var realtime: Bool { didSet { defaults.set(realtime, forKey: "monitor.realtime") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func size(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
            let value = defaults.double(forKey: key)
            return value.isFinite && range.contains(value) ? value : fallback
        }
        popupHeight = size("popup.height", fallback: 820, range: 420...1600)
        popupWidth = size("popup.width", fallback: 540, range: 420...1200)
        theme = AppTheme(rawValue: defaults.string(forKey: "appearance.theme") ?? "system") ?? .system
        energySaving = defaults.bool(forKey: "monitor.energySaving")
        realtime = defaults.bool(forKey: "monitor.realtime")
        if let data = defaults.data(forKey: "hosts.v1"), let decoded = try? JSONDecoder().decode([HostRecord].self, from: data) {
            var seen = Set<String>()
            hosts = decoded.filter { Self.validationError($0.alias) == nil && seen.insert($0.alias).inserted }
        }
    }
    static func validationError(_ alias: String) -> String? {
        guard !alias.isEmpty else { return "Enter an SSH host alias." }
        guard alias.count <= 253 else { return "The host alias is too long (maximum 253 characters)." }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_@:%[]"))
        guard !alias.hasPrefix("-"), alias.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "Use a host alias or user@host, without spaces, shell characters or leading '-'."
        }
        return nil
    }
    @discardableResult func add(_ name: String) -> String? {
        let alias = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = Self.validationError(alias) { return error }
        guard !hosts.contains(where: { $0.alias == alias }) else { return "This host is already in the list." }
        hosts.append(HostRecord(alias: alias)); return nil
    }
    func savePanelSize(_ size: CGSize) {
        let width = min(1200, max(420, size.width.rounded()))
        let height = min(1600, max(420, size.height.rounded()))
        if popupWidth != width { popupWidth = width }
        if popupHeight != height { popupHeight = height }
    }
    private func saveHosts() {
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: "hosts.v1") }
    }
}
