import Foundation
import Darwin

/// All mutable process and pipe state belongs to queue. Callbacks contain only
/// decoded Sendable values, never a FileHandle or a mutable JSON dictionary.
final class SSHMonitor: MonitoringSession, @unchecked Sendable {
    struct LaunchConfiguration: Sendable {
        var executableURL: URL
        var arguments: [String]
    }
    private let alias: String
    private let source: Data
    private let onEvent: @Sendable (CollectorEvent) -> Void
    private let onStop: @Sendable (Int32, String) -> Void
    private let queue: DispatchQueue
    private let launchConfiguration: LaunchConfiguration?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var stderr: FileHandle?
    private var outputReader: DispatchSourceRead?
    private var errorReader: DispatchSourceRead?
    private var buffer = Data()
    private var errorBuffer = Data()
    private var stopping = false

    init(alias: String, source: Data, onEvent: @escaping @Sendable (CollectorEvent) -> Void,
         onStop: @escaping @Sendable (Int32, String) -> Void, launchConfiguration: LaunchConfiguration? = nil) {
        self.alias = alias; self.source = source
        self.onEvent = onEvent; self.onStop = onStop
        self.launchConfiguration = launchConfiguration
        queue = DispatchQueue(label: "monitor.ssh.\(alias)", qos: .utility)
    }

    func start() throws {
        try queue.sync {
            guard process == nil else { return }
            guard !source.isEmpty, source.count < 100_000 else {
                throw NSError(domain: "Monitor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bundled collector is missing or too large"])
            }
            let encoded = source.base64EncodedString()
            let remote = "python3 -u -c 'exec(__import__(\"base64\").b64decode(\"" + encoded + "\"))'"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            task.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                              "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=15",
                              "-o", "ServerAliveCountMax=2", "--", alias, remote]
            if let launchConfiguration {
                task.executableURL = launchConfiguration.executableURL
                task.arguments = launchConfiguration.arguments
            }
            let stdoutPipe = Pipe(), stdinPipe = Pipe(), errorPipe = Pipe()
            task.standardOutput = stdoutPipe; task.standardInput = stdinPipe; task.standardError = errorPipe
            output = stdoutPipe.fileHandleForReading; stderr = errorPipe.fileHandleForReading
            input = stdinPipe.fileHandleForWriting
            task.terminationHandler = { [weak self] task in
                guard let self else { return }
                let status = task.terminationStatus
                self.queue.async { [self] in
                    if let output { readPipe(output, isError: false) }
                    if let stderr { readPipe(stderr, isError: true) }
                    let summary = String(decoding: errorBuffer, as: UTF8.self).split(separator: "\n")
                        .suffix(3).joined(separator: " | ")
                    cleanup()
                    process = nil
                    onStop(status, String(summary.prefix(480)))
                }
            }
            do {
                outputReader = try makeReader(stdoutPipe.fileHandleForReading, isError: false)
                errorReader = try makeReader(errorPipe.fileHandleForReading, isError: true)
                try task.run(); process = task
            }
            catch { cleanup(); throw error }
        }
    }

    private func makeReader(_ handle: FileHandle, isError: Bool) throws -> DispatchSourceRead {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self] in self?.readPipe(handle, isError: isError) }
        // Dispatch retains the descriptor until asynchronous cancellation has
        // finished. Close only from its cancellation handler on the same queue.
        reader.setCancelHandler { try? handle.close() }
        reader.resume()
        return reader
    }

    // Reads, descriptor identity checks and close() all execute on queue. A
    // canceled source's late event cannot read a closed or reused descriptor.
    private func readPipe(_ handle: FileHandle, isError: Bool) {
        guard !stopping, (isError ? stderr : output) === handle else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<16 {
            let (count, readError) = bytes.withUnsafeMutableBytes { buffer in
                let count = Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
                return (count, count < 0 ? errno : 0)
            }
            if count > 0 {
                let chunk = Data(bytes.prefix(count))
                if isError {
                    errorBuffer.append(chunk)
                    if errorBuffer.count > 8192 { errorBuffer.removeFirst(errorBuffer.count - 8192) }
                } else { consume(chunk) }
                continue
            }
            if count < 0 && readError == EINTR { continue }
            if count < 0 && (readError == EAGAIN || readError == EWOULDBLOCK) { return }
            if isError { errorReader?.cancel(); errorReader = nil; stderr = nil }
            else { outputReader?.cancel(); outputReader = nil; output = nil }
            if count < 0 { onEvent(.error("Unable to read the collector pipe")) }
            return
        }
    }

    private func consume(_ chunk: Data) {
        guard !stopping else { return }
        buffer.append(chunk)
        if buffer.count > 1_000_000 {
            buffer.removeAll(keepingCapacity: false)
            onEvent(.error("Collector output exceeded the buffer limit")); return
        }
        let decoder = JSONDecoder()
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard line.count < 100_000, !line.isEmpty else { continue }
            do {
                let message = try decoder.decode(CollectorMessage.self, from: line)
                switch message.type {
                case "snapshot":
                    let snapshot = try decoder.decode(ServerSnapshot.self, from: line)
                    guard snapshot.protocolVersion == 1 else { onEvent(.error("Unsupported collector protocol")); continue }
                    onEvent(.snapshot(snapshot))
                case "hello": onEvent(.hello(message))
                case "error": onEvent(.error(message.message ?? "Collector error"))
                default: break
                }
            } catch { onEvent(.error("Invalid collector response")) }
        }
    }

    func send(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        queue.async { [self] in
            guard !stopping, let input else { return }
            do { try input.write(contentsOf: data + Data([10])) }
            catch { onEvent(.error("Unable to send a collector command")) }
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopping else { return }
            stopping = true
            if let data = "{\"command\":\"shutdown\"}\n".data(using: .utf8) { try? input?.write(contentsOf: data) }
            try? input?.close(); input = nil
            if process?.isRunning == true { process?.terminate() }
            cleanup()
        }
    }

    private func cleanup() {
        if let outputReader { outputReader.cancel() } else { try? output?.close() }
        if let errorReader { errorReader.cancel() } else { try? stderr?.close() }
        outputReader = nil; errorReader = nil
        try? input?.close()
        output = nil; stderr = nil; input = nil
        buffer.removeAll(keepingCapacity: false)
    }

    deinit { if process?.isRunning == true { process?.terminate() } }
}
