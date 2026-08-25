// MARK: - 外部事件协议
//
// 这个 target 与命令行工具共用，不含界面、也拿不到应用的本地化表（tr() 在
// LightAnchor target 里）。这里的错误文案面向开发者与脚本输出，留中文；
// 用户在应用里看到的同类错误由 ExternalEventKit 各自本地化。

import Foundation

#if os(macOS)
import Darwin
#endif

public enum LightAnchorEventSource: String, Codable, CaseIterable, Sendable {
    case ide
    case terminal
    case build
    case download
    case export
    case reply
    case calendar
    case agent
    case custom
}

public enum LightAnchorEventKind: String, Codable, CaseIterable, Sendable {
    case started
    case progress
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .started, .progress:
            false
        }
    }
}

public struct LightAnchorEventRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let source: LightAnchorEventSource
    public let kind: LightAnchorEventKind
    public let correlationID: String
    public let title: String
    public let detail: String
    public let payload: [String: String]
    public let occurredAt: Date
    public let processIdentifier: Int32?
    public let workingDirectory: URL?

    public init(
        id: UUID = UUID(),
        source: LightAnchorEventSource,
        kind: LightAnchorEventKind,
        correlationID: String,
        title: String = "",
        detail: String = "",
        payload: [String: String] = [:],
        occurredAt: Date = Date(),
        processIdentifier: Int32? = nil,
        workingDirectory: URL? = nil
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.correlationID = correlationID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.payload = payload
        self.occurredAt = occurredAt
        self.processIdentifier = processIdentifier
        self.workingDirectory = workingDirectory
    }

    public var isValid: Bool {
        !correlationID.isEmpty && (!title.isEmpty || !detail.isEmpty || kind.isTerminal)
    }
}

public enum LightAnchorEventLogError: LocalizedError, Equatable {
    case invalidEvent
    case unreadableRecord
    case lockUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidEvent:
            "外部事件缺少有效的关联 ID 或内容。"
        case .unreadableRecord:
            "外部事件日志中存在无法读取的记录。"
        case .lockUnavailable:
            "无法锁定外部事件日志。"
        }
    }
}

public struct LightAnchorEventLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let environmentValue = ProcessInfo.processInfo.environment["LIGHTANCHOR_EVENT_INBOX"],
                  !environmentValue.isEmpty {
            self.fileURL = URL(fileURLWithPath: environmentValue).standardizedFileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
    }

    public static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("LightAnchor", isDirectory: true)
            .appendingPathComponent("external-events.jsonl")
    }

    public func append(_ event: LightAnchorEventRecord) throws {
        guard event.isValid else { throw LightAnchorEventLogError.invalidEvent }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let line = try encoder.encode(event) + Data([0x0A])
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try withFileLock {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                do {
                    try handle.write(contentsOf: line)
                } catch {
                    // Roll back: a half-written line makes every later read of
                    // the log fail with no way to recover.
                    try? handle.truncate(atOffset: end)
                    throw error
                }
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        }
    }

    public func records() throws -> [LightAnchorEventRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try withFileLock {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return [] }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                if let milliseconds = try? container.decode(Double.self) {
                    return Date(timeIntervalSince1970: milliseconds / 1_000)
                }
                let value = try container.decode(String.self)
                if let date = ISO8601DateFormatter().date(from: value) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "事件时间不是有效的 ISO 8601 值。"
                )
            }

            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            var records: [LightAnchorEventRecord] = []
            for (index, line) in lines.enumerated() {
                if line.isEmpty {
                    if index == lines.index(before: lines.endIndex) {
                        continue
                    }
                    throw LightAnchorEventLogError.unreadableRecord
                }
                guard let record = try? decoder.decode(
                    LightAnchorEventRecord.self,
                    from: Data(line)
                ), record.isValid else {
                    throw LightAnchorEventLogError.unreadableRecord
                }
                records.append(record)
            }
            return records
        }
    }

    public func removeAll() throws {
        let fileManager = FileManager.default
        let lockURL = fileURL.appendingPathExtension("lock")
        guard fileManager.fileExists(atPath: fileURL.path) ||
            fileManager.fileExists(atPath: lockURL.path)
        else { return }

        // The lock file stays in place: unlinking it lets the next writer create
        // a different inode and hold a lock that excludes nobody.
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
        guard descriptor >= 0 else { throw LightAnchorEventLogError.lockUnavailable }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw LightAnchorEventLogError.lockUnavailable
        }
        return try operation()
        #else
        return try operation()
        #endif
    }
}
