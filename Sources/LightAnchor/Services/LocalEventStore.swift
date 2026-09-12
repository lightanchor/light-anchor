import Foundation

/// 整份事件日志的单文档形态。「导出数据」给用户的就是这样一个文件；
/// 磁盘上的事件是逐条落盘的（见 `LocalEventStore`），此结构不用于加载。
struct AttentionEventDocument: Codable, Equatable {
    var events: [AttentionEvent] = []
}

struct AttentionEventRecord: Codable, Equatable {
    let event: AttentionEvent
}

/// 事件日志的落盘方式：一条事件一个文件。
///
/// 布局是 `events/<UTC 日期>/<时分秒>-<序号>-<事件 id>.json`。这样切而不是整份
/// 日志一个 JSON，是为了让数据目录本身就适合放进版本库：两台机器各自追加
/// 的事件永远落在不同文件里，合并就是取并集，没有文本冲突；一次提交只
/// 改动这次新增的那几个文件，历史也就可读。
///
/// 事件是 append-only 的，但不是只增不改：抹除场景内容会改写旧事件，删除采集
/// 会移除事件。所以 `save` 按 id 对照上次落盘的内容做增量——新的写、变了的
/// 重写、不在了的删——而不是每次重写全部文件。
///
/// 加载顺序按 `(序号, occurredAt, id)`——序号即写入时的先后。回放依赖顺序
/// （同一实体后者覆盖前者），而 `occurredAt` 是调用方传进来的业务时间，可以乱序
/// （测试与补录都会传过去的时刻），不能当主键。occurredAt 与 id 只兜住序号缺失
/// 或相等的文件。
final class LocalEventStore {
    let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private struct Entry {
        var url: URL
        var data: Data
        var sequence: Int
    }

    /// 上次 load/save 时磁盘上每条事件的位置与内容，save 据此算增量。
    private var index: [UUID: Entry]?
    private var nextSequence = 0

    init(directoryURL: URL? = nil) {
        self.directoryURL = (directoryURL ?? LocalEventStore.defaultDirectoryURL()).standardizedFileURL

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
    }

    // MARK: - Load

    func load() throws -> [AttentionEvent] {
        var index: [UUID: Entry] = [:]
        var events: [UUID: AttentionEvent] = [:]
        var maxSequence = -1

        for fileURL in try eventFileURLs() {
            let data = try Data(contentsOf: fileURL)
            let record = try decoder.decode(AttentionEventRecord.self, from: data)
            let sequence = Self.sequence(fromFileName: fileURL.lastPathComponent)
            events[record.event.id] = record.event
            index[record.event.id] = Entry(url: fileURL, data: data, sequence: sequence)
            maxSequence = max(maxSequence, sequence)
        }

        self.index = index
        self.nextSequence = maxSequence + 1
        return events.values.sorted { lhs, rhs in
            // 序号即本机写入时的先后，等价于旧整份数组的 append 顺序。回放依赖
            // 顺序（同一实体后者覆盖前者），而 occurredAt 是业务时间、可能乱序
            // （测试与补录会传入任意时刻），不能当主键；只在序号缺失/相等时兜底。
            let lhsSequence = index[lhs.id]?.sequence ?? .max
            let rhsSequence = index[rhs.id]?.sequence ?? .max
            if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 目录下两层（日期目录 / 事件文件）的全部 `.json`，按路径排序保证遍历稳定。
    private func eventFileURLs() throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        var urls: [URL] = []
        for day in try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) where (try? day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for file in try fileManager.contentsOfDirectory(
                at: day,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) where file.pathExtension == "json" {
                urls.append(file)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    // MARK: - Save

    func save(events: [AttentionEvent]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try LightAnchorStorage.ensureGitIgnore(in: directoryURL.deletingLastPathComponent())

        var index = try self.index ?? loadIndex()
        var retained = Set<UUID>()
        for event in events {
            retained.insert(event.id)
            let data = try encoder.encode(AttentionEventRecord(event: event))
            if let existing = index[event.id] {
                guard existing.data != data else { continue }
                try data.write(to: existing.url, options: .atomic)
                index[event.id]?.data = data
            } else {
                let sequence = nextSequence
                nextSequence += 1
                let url = fileURL(for: event, sequence: sequence)
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                index[event.id] = Entry(url: url, data: data, sequence: sequence)
            }
        }

        var touchedDirectories = Set<URL>()
        for (id, entry) in index where !retained.contains(id) {
            try fileManager.removeItem(at: entry.url)
            touchedDirectories.insert(entry.url.deletingLastPathComponent())
            index.removeValue(forKey: id)
        }
        for directory in touchedDirectories {
            if let remaining = try? fileManager.contentsOfDirectory(atPath: directory.path),
               remaining.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        }
        self.index = index
    }

    private func loadIndex() throws -> [UUID: Entry] {
        _ = try load()
        return index ?? [:]
    }

    /// 单文档形态的整份日志，供导出。
    func encodedData(events: [AttentionEvent]) throws -> Data {
        try encoder.encode(AttentionEventDocument(events: events))
    }

    // MARK: - Paths

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HHmmss"
        return formatter
    }()

    /// 日期与时间取 UTC：文件名不能随机器时区变化，否则同一条事件在两台机器上
    /// 会落到不同的路径。
    private func fileURL(for event: AttentionEvent, sequence: Int) -> URL {
        let day = Self.dayFormatter.string(from: event.occurredAt)
        let time = Self.timeFormatter.string(from: event.occurredAt)
        let name = "\(time)-\(String(format: "%08d", sequence))-\(event.id.uuidString).json"
        return directoryURL
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(name)
    }

    /// 文件名格式 `HHmmss-00000123-<uuid>.json`；被人改过名的文件排在同瞬间事件的最后。
    static func sequence(fromFileName name: String) -> Int {
        let parts = name.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, let sequence = Int(parts[1]) else { return .max }
        return sequence
    }

    static func defaultDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        LightAnchorStorage.eventsDirectoryURL(fileManager: fileManager)
    }
}
