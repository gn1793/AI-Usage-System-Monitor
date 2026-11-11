import Foundation

enum QuotaResetFormatter {
    static func duration(_ reset: Date, now: Date) -> String? {
        let minutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        guard minutes > 0 else { return nil }
        return "\(minutes / 1440)d \((minutes % 1440) / 60)h \(minutes % 60)m"
    }
    static func text(_ reset: Date, now: Date) -> String {
        guard let duration = duration(reset, now: now) else { return "Reset due · refresh for the latest quota" }
        return "Resets in \(duration) · " + reset.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
