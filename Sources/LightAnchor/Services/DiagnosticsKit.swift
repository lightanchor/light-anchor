import Foundation

struct DiagnosticEvent: Codable, Equatable {
    let occurredAt: Date
    let operation: String
    let message: String
}

struct DiagnosticBundle: Codable, Equatable {
    let exportedAt: Date
    let appVersion: String
    let operatingSystem: String
    let releaseManifestVersion: Int
    let events: [DiagnosticEvent]
}

final class LocalDiagnostics: @unchecked Sendable {
    static let shared = LocalDiagnostics()

    private let lock = NSLock()
    private let fileURL: URL
    private let maximumFileSize = 1_000_000

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? LightAnchorStorage.diagnosticsURL()
    }

    func record(operation: String, message: String) {
        let event = DiagnosticEvent(
            occurredAt: Date(),
            operation: redact(operation),
            message: redact(message)
        )
        guard let data = try? JSONEncoder().encode(event) else { return }

        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue >= maximumFileSize {
                try? FileManager.default.removeItem(at: fileURL)
            }
            let line = data + Data([0x0A])
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Diagnostics must never affect the user's workspace.
        }
    }

    func installUncaughtExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            LocalDiagnostics.shared.record(
                operation: "uncaught-exception",
                message: "\(exception.name.rawValue): \(exception.reason ?? "unknown")"
            )
        }
    }

    func exportData(maximumEvents: Int = 200) throws -> Data {
        lock.lock()
        let storedEvents: [DiagnosticEvent]
        do {
            storedEvents = try readEvents()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        let events = storedEvents
            .suffix(max(0, maximumEvents))
            .map { event in
                DiagnosticEvent(
                    occurredAt: event.occurredAt,
                    operation: redact(event.operation),
                    message: redact(event.message)
                )
            }
        let bundle = DiagnosticBundle(
            exportedAt: Date(),
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.0",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            releaseManifestVersion: LightAnchorSchema.releaseManifestVersion,
            events: Array(events)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    func removeAllData() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func readEvents() throws -> [DiagnosticEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return data.split(separator: 0x0A).compactMap { line in
            try? JSONDecoder().decode(DiagnosticEvent.self, from: Data(line))
        }
    }

    private func redact(_ message: String) -> String {
        var result = message
        let home = NSHomeDirectory()
        if !home.isEmpty {
            result = result.replacingOccurrences(of: home, with: "<HOME>")
        }
        result = replaceMatches(
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            in: result,
            replacement: "Bearer <REDACTED>"
        )
        result = replaceMatches(
            #"\bxox[baprs]-[A-Za-z0-9-]+\b"#,
            in: result,
            replacement: "<REDACTED_TOKEN>"
        )
        result = replaceMatches(
            #"(?i)\b(?:x-api-key|api[-_]?key|token|secret|password|passwd|authorization)\s*[:=]\s*[^\s,;]+"#,
            in: result,
            replacement: "<REDACTED_SECRET>"
        )
        result = redactURLs(in: result)
        return result
    }

    private func replaceMatches(
        _ pattern: String,
        in value: String,
        replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }

    private func redactURLs(in value: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)\bhttps?://[^\s<>\"']+"#
        ) else {
            return value
        }

        var result = value
        let matches = expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let rawURL = String(result[range])
            let trailing = String(
                rawURL.reversed().prefix {
                    ".,;:!?)]}".contains($0)
                }.reversed()
            )
            let core = String(rawURL.dropLast(trailing.count))
            guard var components = URLComponents(string: core) else { continue }
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            result.replaceSubrange(
                range,
                with: (components.string ?? core) + trailing
            )
        }
        return result
    }
}
