import Foundation

enum ExternalEventSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case ide
    case terminal
    case build
    case download
    case export
    case reply
    case calendar
    case agent
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ide: "IDE"
        case .terminal: tr("terminal")
        case .build: tr("build_tools")
        case .download: tr("download_tools")
        case .export: tr("export_tools")
        case .reply: tr("reply_connector")
        case .calendar: tr("calendar")
        case .agent: "Agent"
        case .custom: tr("other_connectors")
        }
    }
}

enum ExternalEventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case started
    case progress
    case completed
    case failed
    case cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .started: tr("started")
        case .progress: tr("in_progress")
        case .completed: tr("completed")
        case .failed: tr("failed_2")
        case .cancelled: tr("cancelled")
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .started, .progress: false
        }
    }
}

struct ExternalEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let source: ExternalEventSource
    let kind: ExternalEventKind
    let correlationID: String
    let title: String
    let detail: String
    let payload: [String: String]
    let occurredAt: Date
    let processIdentifier: Int32?
    let workingDirectory: URL?

    init(
        id: UUID = UUID(),
        source: ExternalEventSource,
        kind: ExternalEventKind,
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

    var isValid: Bool {
        !correlationID.isEmpty && (!title.isEmpty || !detail.isEmpty || kind.isTerminal)
    }

    var evidence: String {
        let label = title.isEmpty ? source.title : title
        let state = kind.title
        if detail.isEmpty {
            return "\(label)：\(state)"
        }
        return "\(label)：\(state)。\(detail)"
    }
}
