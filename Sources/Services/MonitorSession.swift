import Foundation

protocol MonitoringSession: AnyObject, Sendable {
    func start() throws
    func send(_ command: [String: Any])
    func stop()
}

enum CollectorEvent: Sendable {
    case snapshot(ServerSnapshot)
    case hello(CollectorMessage)
    case error(String)
}
