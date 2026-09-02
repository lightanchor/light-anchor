import Foundation

import Darwin

enum ProcessExecutionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            message.isEmpty ? tr("the_command_failed") : message
        }
    }
}

private final class CancellableProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var launched = false
    private var cancelled = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    /// Returns false when cancellation arrived while the process was starting,
    /// in which case the caller must stop the process it has just launched.
    func markLaunched() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        launched = true
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = launched ? self.process : nil
        lock.unlock()
        Self.stop(process)
    }

    static func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        if process.processIdentifier > 0 {
            _ = kill(-process.processIdentifier, SIGTERM)
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Collects pipe output as it is produced. Reading only after `waitUntilExit`
/// deadlocks as soon as the child fills the pipe buffer.
private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let endOfFile = DispatchSemaphore(value: 0)

    func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [self] source in
            let chunk = source.availableData
            guard !chunk.isEmpty else {
                source.readabilityHandler = nil
                endOfFile.signal()
                return
            }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }
    }

    /// A grandchild that inherited the write end keeps the pipe open after the
    /// child exits, so give the reader a bounded grace period rather than
    /// blocking on end of file forever.
    func finish(_ handle: FileHandle, gracePeriod: DispatchTimeInterval = .seconds(2)) -> String {
        _ = endOfFile.wait(timeout: .now() + gracePeriod)
        handle.readabilityHandler = nil
        lock.lock()
        let collected = data
        lock.unlock()
        return String(data: collected, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum ProcessExecutionSupport {
    /// Synchronous variant for callers that cannot suspend. Returns nil when the
    /// process fails to start or exits non-zero.
    static func runSynchronously(
        executableURL: URL,
        arguments: [String]
    ) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let collector = ProcessOutputCollector()
        collector.attach(to: outputPipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        process.waitUntilExit()
        let output = collector.finish(outputPipe.fileHandleForReading)
        guard process.terminationStatus == 0 else { return nil }
        return output
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil
    ) async throws -> String {
        let handle = CancellableProcessHandle()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    let outputPipe = Pipe()
                    process.executableURL = executableURL
                    process.arguments = arguments
                    process.currentDirectoryURL = workingDirectory
                    process.standardOutput = outputPipe
                    process.standardError = outputPipe

                    guard handle.install(process) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let collector = ProcessOutputCollector()
                    collector.attach(to: outputPipe.fileHandleForReading)

                    do {
                        try process.run()
                        _ = setpgid(process.processIdentifier, process.processIdentifier)
                        if !handle.markLaunched() {
                            CancellableProcessHandle.stop(process)
                        }
                        process.waitUntilExit()
                        let output = collector.finish(outputPipe.fileHandleForReading)
                        if handle.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        if process.terminationStatus == 0 {
                            continuation.resume(returning: output)
                        } else {
                            continuation.resume(throwing: ProcessExecutionError.failed(output))
                        }
                    } catch {
                        outputPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            handle.cancel()
        })
    }
}
