import XCTest
@testable import LightAnchor

final class LocalizationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func table(_ locale: String) throws -> [String: String] {
        let url = repositoryRoot.appendingPathComponent(
            "Sources/LightAnchor/Resources/\(locale).lproj/Localizable.strings"
        )
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: String])
    }

    func testTablesParseAndHaveNoEmptyValues() throws {
        for locale in ["zh-Hans", "en"] {
            let entries = try table(locale)
            XCTAssertGreaterThan(entries.count, 700, "\(locale) 表意外变小，可能被误删")
            for (key, value) in entries {
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(locale) 空翻译：\(key)"
                )
            }
        }
    }

    /// key 必须是稳定的英文标识符——不再允许中文当 key。
    func testKeysAreStableASCIIIdentifiers() throws {
        let keyShape = try NSRegularExpression(pattern: "^[a-z][a-z0-9_]*$")
        for locale in ["zh-Hans", "en"] {
            for key in try table(locale).keys {
                let range = NSRange(key.startIndex..., in: key)
                XCTAssertNotNil(
                    keyShape.firstMatch(in: key, range: range),
                    "\(locale) 非法 key（应为小写英文标识符）：\(key)"
                )
            }
        }
    }

    /// zh-Hans 是唯一事实源：两张表 key 集必须完全一致，谁缺谁多都算坏。
    func testTablesShareTheSameKeySet() throws {
        let zh = Set(try table("zh-Hans").keys)
        let en = Set(try table("en").keys)
        XCTAssertEqual(
            zh.symmetricDifference(en), [],
            "zh 独有：\(zh.subtracting(en).sorted().prefix(10))；en 独有：\(en.subtracting(zh).sorted().prefix(10))"
        )
    }

    func testFormatSpecifiersMatchBetweenChineseAndEnglish() throws {
        let zh = try table("zh-Hans")
        let en = try table("en")
        // 位置说明符（%2$@）算同一个占位符：语序不同的语言靠它调换实参顺序，
        // 比较的是「用到哪些类型的占位符」，不是它们在句子里的位置。
        let spec = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:\\.\\d)?(?:lld|ld|d|f|@)")
        let position = try NSRegularExpression(pattern: "\\d+\\$")
        func specs(_ s: String) -> [String] {
            spec.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { match in
                let raw = String(s[Range(match.range, in: s)!])
                return position.stringByReplacingMatches(
                    in: raw,
                    range: NSRange(raw.startIndex..., in: raw),
                    withTemplate: ""
                )
            }
        }
        for (key, zhValue) in zh {
            guard let enValue = en[key] else { continue }
            XCTAssertEqual(
                specs(zhValue).sorted(), specs(enValue).sorted(),
                "格式占位符不一致：\(key)（zh: \(zhValue) / en: \(enValue)）"
            )
        }
    }

    func testCoreKeysCarryTheExpectedChinese() throws {
        let zh = try table("zh-Hans")
        let expectations: [String: String] = [
            "now": "现在",
            "later": "稍后",
            "waiting": "等待",
            "environments": "环境",
            "save": "保存",
            "cancel": "取消",
            "inbox": "稍后",
            "reference": "暂存箱",
            "interface_language": "界面语言",
        ]
        for (key, chinese) in expectations {
            XCTAssertEqual(zh[key], chinese, "核心 key 变动：\(key)")
        }
    }

    /// tr() 端到端：测试进程钉死 zh-Hans，断言应与机器语言无关。
    func testTrResolvesFromBundledTables() {
        XCTAssertTrue(LocalizationTable.pinToChinese)
        XCTAssertEqual(tr("save"), "保存")
        XCTAssertEqual(tr("cancel"), "取消")
        // 查不到的 key 原样返回，不崩、不空。
        XCTAssertEqual(tr("definitely_not_a_key"), "definitely_not_a_key")
    }

    /// 英文表确实被打进资源 bundle 且能按 key 命中。
    func testEnglishBundleResolvesKeys() throws {
        let path = try XCTUnwrap(Bundle.module.path(forResource: "en", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(bundle.localizedString(forKey: "save", value: nil, table: nil), "Save")
        XCTAssertEqual(bundle.localizedString(forKey: "now", value: nil, table: nil), "Now")
    }

    // MARK: - 源码守门：不许再把中文当 key / 当界面字面量

    private func swiftFiles(under relativePaths: [String]) throws -> [URL] {
        var result: [URL] = []
        for relative in relativePaths {
            let root = repositoryRoot.appendingPathComponent(relative)
            if root.pathExtension == "swift" {
                result.append(root)
                continue
            }
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "swift" { result.append(url) }
            }
        }
        XCTAssertFalse(result.isEmpty)
        return result
    }

    /// 源码里所有 `tr("…")` 的 key。
    private func trKeysInSource() throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"tr\("([^"]+)"\)"#)
        var keys: Set<String> = []
        for file in try swiftFiles(under: ["Sources"]) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let captured = Range(match.range(at: 1), in: text) else { continue }
                keys.insert(String(text[captured]))
            }
        }
        return keys
    }

    private func containsCJK(_ s: Substring) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// tr() 的实参必须是标识符 key，不许再传中文原文。
    func testNoChineseLiteralKeysRemainInTrCalls() throws {
        let pattern = try NSRegularExpression(pattern: #"tr\("([^"]*)"\)"#)
        for file in try swiftFiles(under: ["Sources"]) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let key = text[Range(match.range(at: 1), in: text)!]
                XCTAssertFalse(
                    containsCJK(key),
                    "tr() 传了中文（应为标识符 key）：\(file.lastPathComponent): \(key)"
                )
            }
        }
    }

    /// tr() 传的 key 必须在表里。查不到时 tr() 会原样回吐 key，界面上就出现
    /// 一行 `some_key_name`——这条把那种拼错/漏加抓在测试里。
    func testEveryTrKeyExistsInTheTables() throws {
        let table = try self.table("zh-Hans")
        let missing = try trKeysInSource().filter { table[$0] == nil }
        XCTAssertEqual(
            missing.sorted(), [],
            "这些 key 不在本地化表里，界面会直接显示 key 名"
        )
    }

    /// 反向：表里不留没人用的 key。删掉功能时顺手删文案，表才不会越攒越糊。
    func testTablesHaveNoUnusedKeys() throws {
        let used = try trKeysInSource()
        let unused = try table("zh-Hans").keys.filter { !used.contains($0) }
        XCTAssertEqual(unused.sorted(), [], "这些 key 没有任何 tr() 用到")
    }

    /// 界面层（Views/Design/LightAnchorApp）不许再有裸中文字面量——
    /// 用户可见文案必须走 tr()，含插值的也要走 `String(format: tr(...))`。
    /// 只有下面两类刻意保持中文：写进数据的字符串，和不面向用户的通道
    /// （喂模型的提示词输入、诊断日志）。
    func testUILayerHasNoBareChineseLiterals() throws {
        // 这些会被写进数据（等待证据、默认名），刻意保持中文原样。
        let persistedAllowlist: Set<String> = [
            "用户停止关注。", "用户停止等待。", "用户确认可以返回。", "新的当前工作",
        ]
        // 这些不是界面文案：前两条是喂给模型的提示词输入（提示词语言另议，
        // 现在整套是中文），第三条写进诊断日志。
        let notInterfaceCopyAllowlist: Set<String> = [
            #"问：\(String(message.text.prefix(60)))"#,
            #"答：\(String(message.text.prefix(80)))"#,
            #"回不到捕获前的应用：\(name)"#,
        ]
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        let files = try swiftFiles(under: [
            "Sources/LightAnchor/Views",
            "Sources/LightAnchor/Design",
            "Sources/LightAnchor/App/LightAnchorApp.swift",
        ])
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            var inMultiline = false
            for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                let tripleQuotes = line.components(separatedBy: "\"\"\"").count - 1
                if inMultiline {
                    if tripleQuotes % 2 == 1 { inMultiline = false }
                    continue
                }
                if tripleQuotes % 2 == 1 { inMultiline = true; continue }
                // 去掉行注释（够用的近似：注释里不会出现带引号的中文字面量）。
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                let range = NSRange(code.startIndex..., in: code)
                for match in literal.matches(in: code, range: range) {
                    let content = code[Range(match.range(at: 1), in: code)!]
                    guard containsCJK(content) else { continue }
                    if persistedAllowlist.contains(String(content)) { continue }
                    if notInterfaceCopyAllowlist.contains(String(content)) { continue }
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(content)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "界面层出现裸中文字面量（应包 tr()）：\n\(offenders.joined(separator: "\n"))")
    }

    /// 服务层里「会走到用户眼前」的文案也不许是裸中文。
    ///
    /// 这里守的是错误与状态串：LocalizedError 的 errorDescription、往
    /// `presentNotice`/report 里塞的句子。刻意排除三类，各自在源码里写了理由：
    /// 写进数据的字符串、分词表（中文问句解析），以及不面向用户的通道
    /// （提示词输入、诊断日志、命令行工具）。
    func testUserFacingServiceCopyGoesThroughTr() throws {
        // 只查这些文件：它们的中文字面量已经全部收口，回归会被立刻发现。
        // 其余服务文件仍有刻意保留的中文（分词表、提示词、持久化串）。
        let closedFiles = [
            "Sources/LightAnchor/Services/AttentionActionKit.swift",
            "Sources/LightAnchor/Services/CaptureKit.swift",
            "Sources/LightAnchor/Services/ContextKit.swift",
            "Sources/LightAnchor/Services/DataBackupKit.swift",
            "Sources/LightAnchor/Services/EnvironmentKit.swift",
            "Sources/LightAnchor/Services/LocalAssetStore.swift",
            "Sources/LightAnchor/Services/LocalEventStore.swift",
            "Sources/LightAnchor/Services/ProcessExecutionKit.swift",
            "Sources/LightAnchor/Services/ReleaseKit.swift",
            "Sources/LightAnchor/Services/WaitingPresentationKit.swift",
            "Sources/LightAnchor/Services/WaitingNotifications.swift",
            "Sources/LightAnchor/Services/WorkHistoryKit.swift",
        ]
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        var offenders: [String] = []
        for path in closedFiles {
            let text = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            var inMultiline = false
            for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                let tripleQuotes = line.components(separatedBy: "\"\"\"").count - 1
                if inMultiline {
                    if tripleQuotes % 2 == 1 { inMultiline = false }
                    continue
                }
                if tripleQuotes % 2 == 1 { inMultiline = true; continue }
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                let range = NSRange(code.startIndex..., in: code)
                for match in literal.matches(in: code, range: range) {
                    let content = code[Range(match.range(at: 1), in: code)!]
                    guard containsCJK(content) else { continue }
                    offenders.append("\(path):\(index + 1): \(content)")
                }
            }
        }
        XCTAssertEqual(
            offenders, [],
            "服务层出现裸中文文案（应包 tr()）：\n\(offenders.joined(separator: "\n"))"
        )
    }

    func testAppLanguageAppliesAndClearsAppleLanguagesOverride() {
        let defaults = UserDefaults.standard
        let savedLanguages = defaults.object(forKey: AppLanguage.appleLanguagesKey)
        let savedChoice = defaults.string(forKey: AppLanguage.storageKey)
        defer {
            defaults.set(savedLanguages, forKey: AppLanguage.appleLanguagesKey)
            if savedLanguages == nil { defaults.removeObject(forKey: AppLanguage.appleLanguagesKey) }
            if let savedChoice {
                defaults.set(savedChoice, forKey: AppLanguage.storageKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.storageKey)
            }
        }

        AppLanguage.apply(.english)
        XCTAssertEqual(defaults.stringArray(forKey: AppLanguage.appleLanguagesKey), ["en"])
        XCTAssertEqual(AppLanguage.current, .english)

        AppLanguage.apply(.chinese)
        XCTAssertEqual(defaults.stringArray(forKey: AppLanguage.appleLanguagesKey), ["zh-Hans"])

        AppLanguage.apply(.system)
        // AppleLanguages 在全局域始终有系统值；只验证应用域的覆盖已经撤掉——
        // 即读到的值不再是我们刚写的 ["zh-Hans"]。
        XCTAssertNotEqual(defaults.stringArray(forKey: AppLanguage.appleLanguagesKey), ["zh-Hans"])
        XCTAssertEqual(AppLanguage.current, .system)
    }
}
