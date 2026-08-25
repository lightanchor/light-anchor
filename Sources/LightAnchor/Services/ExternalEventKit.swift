import Foundation

#if os(macOS)
import Darwin
#endif

enum ExternalEventStoreError: LocalizedError, Equatable {
    case invalidEvent
    case unreadableRecord

    var errorDescription: String? {
        switch self {
        case .invalidEvent:
            tr("the_external_event_has_no_valid_correlation")
        case .unreadableRecord:
            tr("the_external_event_log_has_an_unreadable_record")
        }
    }
}

struct ExternalEventStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        LightAnchorStorage.externalEventsURL(fileManager: fileManager)
    }

    func publish(_ event: ExternalEvent) throws {
        guard event.isValid else { throw ExternalEventStoreError.invalidEvent }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let line = try encoder.encode(event) + Data([0x0A])
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try withFileLock {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                do {
                    try handle.write(contentsOf: line)
                } catch {
                    // Roll back: a half-written line makes every later read of
                    // the log fail, and nothing else repairs it.
                    try? handle.truncate(atOffset: end)
                    throw error
                }
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        }
    }

    func events() throws -> [ExternalEvent] {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try withFileLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                if let milliseconds = try? container.decode(Double.self) {
                    return Date(timeIntervalSince1970: milliseconds / 1_000)
                }
                let value = try container.decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: value) {
                    return date
                }
                if let date = ISO8601DateFormatter().date(from: value) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "外部事件时间不是有效的 ISO 8601 值。"
                )
            }

            var result: [ExternalEvent] = []
            guard !data.isEmpty else { return [] }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if line.isEmpty {
                    if index == lines.index(before: lines.endIndex) {
                        continue
                    }
                    throw ExternalEventStoreError.unreadableRecord
                }
                guard let event = try? decoder.decode(ExternalEvent.self, from: Data(line)) else {
                    throw ExternalEventStoreError.unreadableRecord
                }
                result.append(event)
            }
            return result
        }
    }

    func matching(
        correlationID: String,
        sources: Set<ExternalEventSource> = [],
        kinds: Set<ExternalEventKind> = [],
        after: Date? = nil
    ) throws -> [ExternalEvent] {
        let normalizedID = correlationID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try events()
            .filter {
                $0.correlationID == normalizedID &&
                    (sources.isEmpty || sources.contains($0.source)) &&
                    (kinds.isEmpty || kinds.contains($0.kind)) &&
                    (after == nil || $0.occurredAt >= after!)
            }
            .sorted { $0.occurredAt < $1.occurredAt }
    }

    func removeAll() throws {
        let fileManager = FileManager.default
        let lockURL = fileURL.appendingPathExtension("lock")
        guard fileManager.fileExists(atPath: fileURL.path) ||
            fileManager.fileExists(atPath: lockURL.path)
        else { return }
        // The lock file stays in place: unlinking it lets the next writer create
        // a different inode and hold a lock that excludes nobody.
        _ = lockURL
        try withFileLock {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        #if os(macOS)
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ExternalEventStoreError.unreadableRecord }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ExternalEventStoreError.unreadableRecord
        }
        return try operation()
        #else
        return try operation()
        #endif
    }
}

struct ExternalEventURLParser {
    func event(from url: URL, now: Date = Date()) -> ExternalEvent? {
        guard url.scheme?.lowercased() == "lightanchor",
              url.host?.lowercased() == "event",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sourceValue = components.queryItems?.first(where: { $0.name == "source" })?.value,
              let source = ExternalEventSource(rawValue: sourceValue),
              let kindValue = components.queryItems?.first(where: { $0.name == "kind" })?.value,
              let kind = ExternalEventKind(rawValue: kindValue),
              let correlationID = components.queryItems?.first(where: { $0.name == "correlation" })?.value
        else { return nil }

        let title = components.queryItems?.first(where: { $0.name == "title" })?.value ?? ""
        let detail = components.queryItems?.first(where: { $0.name == "detail" })?.value ?? ""
        let date = components.queryItems?
            .first(where: { $0.name == "occurredAt" })?
            .value
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? now
        let processIdentifier = components.queryItems?
            .first(where: { $0.name == "pid" })?
            .value
            .flatMap(Int32.init)
        let workingDirectory = components.queryItems?
            .first(where: { $0.name == "cwd" })?
            .value
            .flatMap(URL.init(fileURLWithPath:))

        let event = ExternalEvent(
            source: source,
            kind: kind,
            correlationID: correlationID,
            title: title,
            detail: detail,
            occurredAt: date,
            processIdentifier: processIdentifier,
            workingDirectory: workingDirectory
        )
        return event.isValid ? event : nil
    }
}

struct IncomingURLWaitingRequest: Equatable, Sendable {
    let kind: WaitingKind
    let source: ExternalEventSource
    let correlationID: String
    let title: String
    let detail: String
}

struct IncomingURLWaitingRequestParser: Sendable {
    func request(from url: URL) -> IncomingURLWaitingRequest? {
        guard url.scheme?.lowercased() == "lightanchor",
              url.host?.lowercased() == "wait",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let kindValue = components.queryItems?.first(where: { $0.name == "kind" })?.value,
              let kind = WaitingKind(rawValue: kindValue),
              let rawCorrelationID = components.queryItems?.first(where: { $0.name == "correlation" })?.value
        else { return nil }

        let source = components.queryItems?
            .first(where: { $0.name == "source" })?
            .value
            .flatMap(ExternalEventSource.init(rawValue:)) ?? .custom
        guard (kind == .download && source == .download) ||
            (kind == .export && source == .export)
        else { return nil }

        let correlationID = rawCorrelationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correlationID.isEmpty, correlationID.count <= 256 else { return nil }
        let fallbackTitle = kind == .download ? "浏览器下载" : "文件导出"
        let title = components.queryItems?
            .first(where: { $0.name == "title" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = components.queryItems?
            .first(where: { $0.name == "detail" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return IncomingURLWaitingRequest(
            kind: kind,
            source: source,
            correlationID: correlationID,
            title: String((title?.isEmpty == false ? title! : fallbackTitle).prefix(240)),
            detail: String(detail.prefix(1_000))
        )
    }
}
