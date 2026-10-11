import Foundation

struct HostRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String { alias }
    var alias: String
    var enabled: Bool = true
}

struct HostInfo: Codable, Sendable { var hostname: String; var os: String? }
struct CPUInfo: Codable, Sendable {
    var model: String
    var usagePercent: Double?
    var temperatureC: Double?
    var logicalCoreUsage: [Double?]
    enum CodingKeys: String, CodingKey {
        case model, usagePercent = "usage_percent", temperatureC = "temperature_c", logicalCoreUsage = "logical_core_usage"
    }
}
struct RAMInfo: Codable, Sendable {
    var totalBytes: Int64
    var usedBytes: Int64
    var availableBytes: Int64
    enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes", usedBytes = "used_bytes", availableBytes = "available_bytes"
    }
}
struct GPUInfo: Codable, Identifiable, Sendable {
    var id: String { uuid }
    var index: Int
    var uuid: String
    var name: String
    var memoryUsedBytes: Int64?
    var memoryFreeBytes: Int64?
    var memoryTotalBytes: Int64?
    var utilizationPercent: Double?
    var temperatureC: Double?
    enum CodingKeys: String, CodingKey {
        case index, uuid, name
        case memoryUsedBytes = "memory_used_bytes", memoryFreeBytes = "memory_free_bytes", memoryTotalBytes = "memory_total_bytes"
        case utilizationPercent = "utilization_percent", temperatureC = "temperature_c"
    }
}
struct ServerSnapshot: Codable, Sendable {
    var protocolVersion: Int
    var type: String
    var sequence: Int
    var timestamp: String
    var host: HostInfo
    var cpu: CPUInfo
    var ram: RAMInfo?
    var gpus: [GPUInfo]
    var gpuBackend: String? = nil
    var gpuError: String? = nil
    var gpuDetectedCount: Int? = nil
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", type, sequence, timestamp, host, cpu, ram, gpus
        case gpuBackend = "gpu_backend", gpuError = "gpu_error", gpuDetectedCount = "gpu_detected_count"
    }
}
struct CollectorMessage: Decodable, Sendable {
    var type: String
    var message: String?
    var os: String?
    var gpuBackend: String?
    var gpuError: String?
    enum CodingKeys: String, CodingKey { case type, message, os, gpuBackend = "gpu_backend", gpuError = "gpu_error" }
}

enum HostConnection: String, Sendable { case disconnected = "Offline", connecting = "Connecting", connected = "Online", failed = "Error", stale = "Stale" }
struct ServerViewState: Identifiable, Sendable {
    let id: String
    var connection: HostConnection = .disconnected
    var snapshot: ServerSnapshot?
    var receivedAt: Date?
    var error: String?
    var gpuBackend: String?
    var gpuError: String?
    var os: String?
    var isStale: Bool { connection != .connected }
}
struct QuotaWindow: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var usedPercent: Double
    var resetAt: Date?
}
enum ProviderStatus: String, Sendable { case waiting, connected, authenticationRequired, rateLimited, unavailable }
struct ProviderState: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var windows: [QuotaWindow] = []
    var detail: String = "Waiting for refresh"
    var updatedAt: Date?
    var status: ProviderStatus = .waiting
    var lastAttemptAt: Date? = nil
    var isStale: Bool { status != .connected && !windows.isEmpty }
}
