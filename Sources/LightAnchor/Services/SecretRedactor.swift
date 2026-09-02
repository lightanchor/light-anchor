import Foundation

/// 采集入口的共用脱敏器：终端命令、剪贴板、外部事件文本在落盘或进入模型提示词之前
/// 先经过这里。只替换明显的凭据形态，不试图理解语义；宁可多遮一点，也不把 token 存下来。
enum SecretRedactor {
    static let placeholder = "<REDACTED>"

    /// 规则按先具体后宽泛排列；每条都是线性匹配，没有嵌套量词，长输入不会回溯爆炸。
    private static let patterns: [(NSRegularExpression, String)] = [
        // 私钥块
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, placeholder),
        // Bearer / Basic 头，以及 -H "Authorization: …" 形式
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=_-]{8,}"#, "$1 <REDACTED>"),
        // 已知前缀的 token：Slack、GitHub、OpenAI/Anthropic、AWS access key、Google
        (#"\bxox[baprs]-[A-Za-z0-9-]{8,}\b"#, placeholder),
        (#"\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{16,}\b"#, placeholder),
        (#"\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}\b"#, placeholder),
        (#"\bAKIA[0-9A-Z]{16}\b"#, placeholder),
        (#"\bAIza[0-9A-Za-z_-]{30,}\b"#, placeholder),
        // KEY=value / key: value（名字里带 key/secret/token/password 之类的）
        (
            #"(?i)\b([A-Z0-9_-]*(?:api[-_]?key|access[-_]?key|secret|token|passwd|password|pwd|credential)[A-Z0-9_-]*)(\s*[:=]\s*)["']?[^\s"',;<]+["']?"#,
            "$1$2<REDACTED>"
        ),
        // --password value / -P value 这类空格分隔的形式
        (
            #"(?i)(--?(?:password|passwd|pwd|token|secret|api-?key|access-?key)\s+)["']?[^\s"',;<-][^\s"',;]*["']?"#,
            "$1<REDACTED>"
        ),
        // mysql 风格的紧贴密码：-pSecret
        (#"(?<=\s)-p(?![\s-])[^\s]{3,}"#, "-p<REDACTED>"),
        // 长高熵串：40+ 位十六进制 / 48+ 位不含斜杠的 base64 形态（路径里有斜杠，不会误伤）
        (#"\b[0-9a-fA-F]{40,}\b"#, placeholder),
        (#"(?<![A-Za-z0-9+/=_.-])[A-Za-z0-9+]{48,}={0,2}(?![A-Za-z0-9+/=_.-])"#, placeholder),
    ].compactMap { pattern, template in
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (expression, template)
    }

    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (expression, template) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: template
            )
        }
        return redactURLCredentials(in: result)
    }

    /// URL 只去掉用户名密码、fragment 和常见的 token 查询参数；保留路径，场景恢复还要用。
    static func stripSensitiveComponents(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let items = components.queryItems, !items.isEmpty {
            let kept = items.filter { !isSensitiveQueryName($0.name) }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url ?? url
    }

    private static let sensitiveQueryNames: Set<String> = [
        "token", "access_token", "refresh_token", "id_token", "auth", "authorization",
        "api_key", "apikey", "key", "secret", "client_secret", "password", "passwd",
        "code", "sig", "signature", "session", "sessionid", "session_id", "sid",
        "x-amz-signature", "x-amz-credential", "x-amz-security-token", "x-goog-signature",
    ]

    private static func isSensitiveQueryName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return sensitiveQueryNames.contains(lowered)
            || lowered.hasSuffix("token")
            || lowered.hasSuffix("secret")
            || lowered.hasPrefix("x-amz-")
    }

    private static let urlExpression = try? NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"']+"#
    )

    private static func redactURLCredentials(in value: String) -> String {
        guard let urlExpression else { return value }
        var result = value
        let matches = urlExpression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            let trailing = String(raw.reversed().prefix { ".,;:!?)]}".contains($0) }.reversed())
            let core = String(raw.dropLast(trailing.count))
            guard let url = URL(string: core) else { continue }
            let stripped = stripSensitiveComponents(from: url).absoluteString
            guard stripped != core else { continue }
            result.replaceSubrange(range, with: stripped + trailing)
        }
        return result
    }
}
