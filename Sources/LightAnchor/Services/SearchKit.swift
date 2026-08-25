import Foundation

/// 工作区搜索的打分：词首命中 > 包含；标题重于正文、正文重于 OCR；
/// 最近改动过的排前面。返回 nil 表示不命中。
enum WorkspaceSearchScoring {
    struct Field {
        let text: String
        let weight: Double

        init(_ text: String, weight: Double) {
            self.text = text
            self.weight = weight
        }
    }

    static let titleWeight = 3.0
    static let tagWeight = 2.5
    static let bodyWeight = 1.5
    static let extractedWeight = 1.0

    static func score(
        query: String,
        fields: [Field],
        recency: Date?,
        now: Date = Date()
    ) -> Double? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return nil }

        var best = 0.0
        for field in fields {
            let text = field.text.lowercased()
            guard !text.isEmpty else { continue }
            let match: Double
            if text == normalizedQuery {
                match = 6
            } else if text.hasPrefix(normalizedQuery) {
                match = 4
            } else if text
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .contains(where: { $0.hasPrefix(normalizedQuery) }) {
                match = 3
            } else if text.contains(normalizedQuery) {
                match = 1.5
            } else {
                continue
            }
            best = max(best, match * field.weight)
        }
        guard best > 0 else { return nil }

        // 时近加权：90 天内线性衰减，最多 +1 分——只影响并列时的先后。
        if let recency {
            let age = max(0, now.timeIntervalSince(recency))
            best += max(0, 1 - age / (90 * 24 * 3600))
        }
        return best
    }
}

struct WorkspaceSceneSearchMatch: Equatable {
    let score: Double
    let title: String
    let matchKind: String
}

/// 现场搜索只索引用户选择保存的语义事实：回来线索、文件/网页/终端/应用。
/// 不索引连续操作，也不把目标名本身扩散成每一份现场的重复结果。
enum WorkspaceSceneSearch {
    static func match(
        query: String,
        scene: SceneSnapshot,
        now: Date = Date()
    ) -> WorkspaceSceneSearchMatch? {
        typealias Field = WorkspaceSearchScoring.Field
        var candidates: [WorkspaceSceneSearchMatch] = []

        if let score = WorkspaceSearchScoring.score(
            query: query,
            fields: [Field(scene.returnCue, weight: WorkspaceSearchScoring.titleWeight)],
            recency: scene.capturedAt,
            now: now
        ), !scene.returnCue.isEmpty {
            candidates.append(WorkspaceSceneSearchMatch(
                score: score,
                title: scene.returnCue,
                matchKind: tr("resume_with")
            ))
        }

        for item in scene.items {
            guard let score = WorkspaceSearchScoring.score(
                query: query,
                fields: [
                    Field(item.title, weight: WorkspaceSearchScoring.titleWeight),
                    Field(item.detail, weight: WorkspaceSearchScoring.bodyWeight),
                    Field(item.sourceApplication, weight: WorkspaceSearchScoring.bodyWeight),
                    Field(item.address, weight: WorkspaceSearchScoring.extractedWeight)
                ],
                recency: scene.capturedAt,
                now: now
            ) else { continue }
            candidates.append(WorkspaceSceneSearchMatch(
                score: score,
                title: item.title.isEmpty ? item.address : item.title,
                matchKind: item.kind.title
            ))
        }

        return candidates.max {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.title.localizedCompare($1.title) == .orderedDescending
        }
    }
}

enum WorkspaceHistoryQueryIntent: Equatable {
    case recent
    case document
    case webpage
    case terminal

    static func infer(from query: String) -> Self? {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        let asksPast = [
            "刚才", "之前", "上次", "中断前", "最近", "做了什么",
            "what was i", "what did i", "earlier", "last time", "recent"
        ].contains(where: normalized.contains)
        guard asksPast else { return nil }

        if ["文档", "文件", "稿子", "document", "file"].contains(where: normalized.contains) {
            return .document
        }
        if ["网页", "页面", "网站", "链接", "page", "website", "link"].contains(where: normalized.contains) {
            return .webpage
        }
        if ["终端", "命令", "agent", "terminal", "command"].contains(where: normalized.contains) {
            return .terminal
        }
        return .recent
    }
}
