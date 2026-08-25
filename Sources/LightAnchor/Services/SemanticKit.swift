// 收件箱的确定性语义分析：只按明确词组和来源给提示，不替用户分类。
import Foundation

enum SemanticDisposition: String, Codable, CaseIterable, Identifiable {
    case action
    case waiting
    case reference
    case idea
    case context

    var id: String { rawValue }

    var title: String {
        switch self {
        case .action: tr("action_cue")
        case .waiting: tr("waiting_cue")
        case .reference: tr("reference_2")
        case .idea: tr("thought")
        case .context: tr("scene_cues")
        }
    }
}

struct SemanticSuggestion: Codable, Equatable {
    let labels: [String]
    let summary: String
    let confidence: Double
    let evidence: [String]
    let disposition: SemanticDisposition

    private enum CodingKeys: String, CodingKey {
        case labels
        case summary
        case confidence
        case evidence
        case disposition
    }

    init(
        labels: [String],
        summary: String,
        confidence: Double,
        evidence: [String],
        disposition: SemanticDisposition = .idea
    ) {
        self.labels = labels
        self.summary = summary
        self.confidence = confidence
        self.evidence = evidence
        self.disposition = disposition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            labels: try container.decodeIfPresent([String].self, forKey: .labels) ?? [],
            summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "",
            confidence: try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0,
            evidence: try container.decodeIfPresent([String].self, forKey: .evidence) ?? [],
            disposition: try container.decodeIfPresent(
                SemanticDisposition.self,
                forKey: .disposition
            ) ?? .idea
        )
    }
}

struct LocalSemanticAnalyzer {
    func analyze(_ capture: CaptureItem) -> SemanticSuggestion {
        let title = capture.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = capture.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = [title, body].filter { !$0.isEmpty }.joined(separator: " ")
        let normalized = text.lowercased()
        var scores: [SemanticDisposition: Int] = [:]
        var evidence: [String] = []

        func add(_ disposition: SemanticDisposition, _ phrase: String, weight: Int = 1) {
            guard normalized.contains(phrase.lowercased()) else { return }
            scores[disposition, default: 0] += weight
            if !evidence.contains(phrase) { evidence.append(phrase) }
        }

        if capture.kind == .link || capture.sourceURL != nil {
            scores[.reference, default: 0] += 3
            evidence.append(tr("link_source"))
        }
        if capture.kind == .fileReference || capture.kind == .screenshot {
            scores[.context, default: 0] += 2
            evidence.append(capture.kind.title)
        }
        if capture.kind == .voice {
            scores[.idea, default: 0] += 1
            evidence.append(tr("voice_capture"))
        }

        for phrase in ["等待", "等回复", "回复后", "构建", "下载", "导出", "会议", "开始时间", "完成后", "pending", "build", "download", "export", "meeting", "reply"] {
            add(.waiting, phrase, weight: phrase.count > 2 ? 2 : 1)
        }
        for phrase in ["需要", "记得", "处理", "完成", "整理", "检查", "联系", "回复", "下一步", "todo", "fix", "review", "安排", "决定", "先"] {
            add(.action, phrase, weight: phrase.count > 2 ? 2 : 1)
        }
        for phrase in ["文章", "资料", "参考", "文档", "教程", "阅读", "查阅", "reference", "docs", "article", "read"] {
            add(.reference, phrase)
        }
        for phrase in ["截图", "现场", "上下文", "窗口", "文件", "当前页面", "screenshot", "context"] {
            add(.context, phrase)
        }

        let disposition = scores.max {
            if $0.value == $1.value { return $0.key.rawValue > $1.key.rawValue }
            return $0.value < $1.value
        }?.key ?? .idea
        if evidence.isEmpty {
            evidence = text
                .split { $0.isWhitespace || $0 == "，" || $0 == "。" || $0 == "," || $0 == "." }
                .map(String.init)
                .filter { $0.count >= 2 }
                .prefix(4)
                .map { String($0) }
        }

        let score = scores[disposition, default: 0]
        let confidence = min(
            0.9,
            max(0.2, 0.3 + Double(score) * 0.1 + Double(min(evidence.count, 4)) * 0.04)
        )
        let summary = makeSummary(
            disposition: disposition,
            title: title,
            body: body,
            sourceURL: capture.sourceURL
        )
        var labels = [disposition.title, capture.kind.title]
        if let sourceApplication = capture.sourceApplication,
           !sourceApplication.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            labels.append(String(format: tr("from_source_app"), sourceApplication))
        }
        return SemanticSuggestion(
            labels: labels,
            summary: summary,
            confidence: confidence,
            evidence: Array(evidence.prefix(6)),
            disposition: disposition
        )
    }

    private func makeSummary(
        disposition: SemanticDisposition,
        title: String,
        body: String,
        sourceURL: URL?
    ) -> String {
        let subject: String
        if disposition == .reference, let sourceURL {
            subject = title.isEmpty ? (sourceURL.host ?? sourceURL.absoluteString) : title
        } else {
            subject = title.isEmpty ? body : title
        }
        let prefix: String
        switch disposition {
        case .action: prefix = tr("next_step_prefix")
        case .waiting: prefix = tr("wait_condition_prefix")
        case .reference: prefix = tr("reference_prefix")
        case .idea: prefix = tr("idea_prefix")
        case .context: prefix = tr("scene_cue_prefix")
        }
        let compact = subject
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard compact.count > 140 else { return prefix + compact }
        return prefix + compact.prefix(140) + "…"
    }
}
