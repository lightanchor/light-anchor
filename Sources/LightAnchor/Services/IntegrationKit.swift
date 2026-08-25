import Foundation

private func makeExternalEventMonitor(
    source: ExternalEventSource,
    description: String,
    value: String,
    inboxURL: URL? = nil
) throws -> WaitingMonitorConfiguration {
    let correlationID = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !correlationID.isEmpty else { throw WaitingDetectionError.invalidConfiguration }
    return WaitingMonitorConfiguration(
        kind: .event,
        eventInboxURL: inboxURL ?? ExternalEventStore.defaultFileURL(),
        eventCorrelationID: correlationID,
        eventSources: [source],
        eventKinds: [.completed, .failed, .cancelled]
    )
}

struct GenericExternalEventConnector: Sendable {
    let kind: WaitingKind
    let source: ExternalEventSource
    let inboxURL: URL?

    init(kind: WaitingKind, source: ExternalEventSource, inboxURL: URL? = nil) {
        self.kind = kind
        self.source = source
        self.inboxURL = inboxURL
    }

    func makeMonitor(description: String, value: String) throws -> WaitingMonitorConfiguration {
        try makeExternalEventMonitor(
            source: source,
            description: description,
            value: value,
            inboxURL: inboxURL
        )
    }
}
