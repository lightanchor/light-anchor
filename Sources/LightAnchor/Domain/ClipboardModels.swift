import Foundation

// MARK: - 剪贴板历史（跟随事情）
//
// 现场只在放下那一刻读一次剪贴板，一段事里复制过的其他内容全丢。剪贴板历史
// 补这个缺口：一件事开始就记，放下 / 等待即停，接着做再续，结束收尾——
// 记录的边界就是这段工作（episode）的边界，不是一份全局的剪贴板管理器。
//
// 只记文字；隐私规则与现场那一次读取完全相同（机密 / 瞬态标记不读、终端与
// 密码管理器在前台时跳过、脱敏后截断），再加上现场来源里被排除的应用不记。

/// 一条剪贴板历史：什么时候、从哪个应用、复制了什么文字。
struct ClipboardHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    /// 单段工作的条目上限：超出丢最早的，保留最近复制的。
    static let entryLimit = 200

    let id: UUID
    let at: Date
    let text: String
    /// 复制时的前台应用名（读不到为空）。
    let sourceApplication: String

    init(
        id: UUID = UUID(),
        at: Date = Date(),
        text: String,
        sourceApplication: String = ""
    ) {
        self.id = id
        self.at = at
        self.text = text
        self.sourceApplication = sourceApplication.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 复写条：同一段连续做事时复制的内容在同一张纸上，放下再回来是新的一张。
/// 纸和纸之间是真的撕开，撕口写着放下了多久——历史自己说明「暂停就是暂停」。
struct ClipboardStrip: Equatable, Identifiable {
    /// 这张纸上的条目，最近的在前。至少一条。
    let entries: [ClipboardHistoryEntry]
    /// 这张纸之后放下了多久（到下一张更新的纸开始为止）；最新一张为 nil。
    let pauseAfter: TimeInterval?

    var id: UUID { entries[0].id }

    /// 按专注区间分纸：每条归到包住它的区间；落在区间外的（比如放下那一刻
    /// 稍后才写入的当时剪贴板）归到开始时间不晚于它的最近一段。没有区间信息
    /// 时全部在一张纸上。返回最新的纸在前。
    static func build(
        entries: [ClipboardHistoryEntry],
        focusIntervals: [DateInterval]
    ) -> [ClipboardStrip] {
        let ordered = entries.sorted { $0.at < $1.at }
        guard !ordered.isEmpty else { return [] }
        let intervals = focusIntervals.sorted { $0.start < $1.start }
        guard !intervals.isEmpty else {
            return [ClipboardStrip(entries: ordered.reversed(), pauseAfter: nil)]
        }

        var grouped: [Int: [ClipboardHistoryEntry]] = [:]
        for entry in ordered {
            let index = intervals.firstIndex { $0.start <= entry.at && entry.at <= $0.end }
                ?? intervals.lastIndex { $0.start <= entry.at }
                ?? 0
            grouped[index, default: []].append(entry)
        }

        let indices = grouped.keys.sorted(by: >)
        return indices.enumerated().map { position, index in
            // 更新的那张纸在前一个位置；两段区间之间的空档就是放下的时长。
            let pauseAfter: TimeInterval? = position == 0
                ? nil
                : max(0, intervals[indices[position - 1]].start.timeIntervalSince(intervals[index].end))
            return ClipboardStrip(entries: grouped[index]!.reversed(), pauseAfter: pauseAfter)
        }
    }
}
