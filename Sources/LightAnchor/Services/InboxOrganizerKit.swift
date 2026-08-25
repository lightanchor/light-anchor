import Foundation

// 「稍后处理箱自动整理」的两件实事：
// 1. 链接标题：只存了裸 URL 的链接捕获，抓一次网页 <title> 补上；
// 2. 相似归堆：按来源域名自动加标签，配合收件箱现有的标签筛选行成堆。
// 全部确定性、可撤销（标签可编辑、标题只在缺失时补），不替用户挪去向。

enum InboxAutoOrganizer {
    /// 域名标签：去掉 www. 前缀的 host，如 "github.com"。非 http(s) 不加。
    static func hostTag(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host.isEmpty ? nil : host
    }

    /// 该捕获是否还缺标题（只存了裸 URL）。
    static func needsTitle(_ capture: CaptureItem) -> Bool {
        guard capture.kind == .link, let url = capture.sourceURL else { return false }
        let title = capture.title ?? ""
        return title.isEmpty || capture.body == url.absoluteString
    }

    /// 该捕获是否有整理空间（缺标题，或缺域名标签）。
    static func canOrganize(_ capture: CaptureItem) -> Bool {
        guard capture.kind == .link, capture.status == .inbox,
              let url = capture.sourceURL else { return false }
        if needsTitle(capture) { return true }
        if let tag = hostTag(for: url), !capture.tags.contains(tag) { return true }
        return false
    }
}

/// 抓网页 <title>。只取前 64KB、8 秒超时；失败静默返回 nil。
enum InboxLinkTitleFetcher {
    static func fetchTitle(
        for url: URL,
        session: URLSession = .shared
    ) async -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else { return nil }
        let html = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        return parseTitle(from: html)
    }

    static func parseTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>(.*?)</title>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        let match = regex.firstMatch(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        ),
        let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let raw = decodeBasicEntities(String(html[range]))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return String(raw.prefix(120))
    }

    private static func decodeBasicEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&#x27;", "'"), ("&mdash;", "—"), ("&ndash;", "–")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
