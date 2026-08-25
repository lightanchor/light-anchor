import Foundation

/// 已生成叙事的本地缓存：按「单位-周期起始日」键存在 UserDefaults 里。
/// 叙事随时可以重新生成，所以不进事件日志；缓存只留最近的几十条。
enum NarrativeStore {
    static let storageKey = "lightanchor.reviewNarratives"
    private static let capacity = 36

    static func key(
        for period: ReviewPeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let start = period.interval(now: now, calendar: calendar).start
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = calendar.timeZone
        return "\(period.unit.rawValue)-\(formatter.string(from: start))"
    }

    static func text(forKey key: String, defaults: UserDefaults = .standard) -> String? {
        load(defaults)[key]
    }

    static func save(_ text: String, forKey key: String, defaults: UserDefaults = .standard) {
        var entries = load(defaults)
        entries[key] = text
        // 键尾是 ISO 日期，字典序即时间序：满了先丢最旧的周期。
        while entries.count > capacity, let oldest = entries.keys.sorted().first {
            entries.removeValue(forKey: oldest)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(_ defaults: UserDefaults) -> [String: String] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
