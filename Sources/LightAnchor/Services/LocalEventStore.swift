import Foundation

struct AttentionEventDocument: Codable, Equatable {
    let schemaVersion: Int
    var events: [AttentionEvent]

    init(
        schemaVersion: Int = LightAnchorSchema.eventDocumentVersion,
        events: [AttentionEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.events = events
    }
}

private struct SchemaVersionDocument: Decodable {
    let schemaVersion: Int
}

enum LocalEventStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            String(format: tr("can_t_read_local_state_version"), version)
        }
    }
}

final class LocalEventStore {
    let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let legacyDecoder: JSONDecoder

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? LocalEventStore.defaultFileURL()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: try container.decode(TimeInterval.self))
        }
        self.decoder = decoder

        let legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSince1970: try container.decode(TimeInterval.self))
        }
        self.legacyDecoder = legacyDecoder
    }

    func load() throws -> [AttentionEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let version = try JSONDecoder().decode(SchemaVersionDocument.self, from: data).schemaVersion
        switch version {
        case 1:
            return try legacyDecoder.decode(AttentionEventDocument.self, from: data)
                .events
                .filter { $0.kind != .unsupported }
        case LightAnchorSchema.eventDocumentVersion:
            return try decoder.decode(AttentionEventDocument.self, from: data)
                .events
                .filter { $0.kind != .unsupported }
        default:
            throw LocalEventStoreError.unsupportedSchema(version)
        }
    }

    func save(events: [AttentionEvent]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let data = try encodedData(events: events)
        try data.write(to: fileURL, options: .atomic)
    }

    func encodedData(events: [AttentionEvent]) throws -> Data {
        try encoder.encode(
            AttentionEventDocument(
                schemaVersion: LightAnchorSchema.eventDocumentVersion,
                events: events
            )
        )
    }

    static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        LightAnchorStorage.eventsURL(fileManager: fileManager)
    }
}
