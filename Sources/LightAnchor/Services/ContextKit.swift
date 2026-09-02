import Foundation

/// 采集入口的 URL 清洗：http/https 链接落盘前去掉凭据、fragment 和 token 形态的
/// 查询参数；`file://` 等其他 scheme 原样保留（路径就是恢复所需的全部信息）。
enum ContextURLSanitizer {
    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func sanitized(_ url: URL) -> URL {
        guard isWebURL(url) else { return url }
        return SecretRedactor.stripSensitiveComponents(from: url)
    }

    static func sanitized(_ url: URL?) -> URL? {
        url.map(sanitized)
    }
}

/// 恢复现场 / 执行环境动作时允许「打开」的条目白名单。这些值来自持久化数据
/// （现场快照、备份、环境配置），不能假定是采集时的原样，所以恢复端自己把关：
/// 链接只放 http/https；文件只放普通文档——不碰应用、脚本、安装包、可执行文件、
/// 符号链接和目录（bundle 也是目录）。
enum RestoreItemPolicy {
    enum Rejection: Equatable {
        case unsupportedScheme
        case missing
        case notARegularFile
        case symbolicLink
        case executable
        case blockedExtension(String)
    }

    /// 双击即执行、或由系统当作程序/安装包处理的扩展名（小写）。
    static let blockedFileExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "scpt", "scptd", "applescript",
        "workflow", "action", "pkg", "mpkg", "dmg", "sh", "zsh", "bash", "fish",
        "py", "rb", "pl", "jar", "webloc", "inetloc", "fileloc", "url",
        "prefpane", "saver", "plugin", "bundle", "framework", "kext",
        "xpc", "appex", "qlgenerator", "mdimporter", "service", "wdgt", "osax",
    ]

    static func allowsLink(_ url: URL) -> Bool {
        ContextURLSanitizer.isWebURL(url)
    }

    /// 只信任文件系统的实际状态，不信任路径长相。
    static func fileRejection(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Rejection? {
        guard url.isFileURL else { return .unsupportedScheme }
        let path = url.path
        guard !path.isEmpty, path.hasPrefix("/") else { return .unsupportedScheme }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        guard let attributes else { return .missing }
        if let type = attributes[.type] as? FileAttributeType {
            if type == .typeSymbolicLink { return .symbolicLink }
            if type != .typeRegular { return .notARegularFile }
        }

        let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey,
            .isExecutableKey, .isApplicationKey,
        ])
        if values?.isSymbolicLink == true { return .symbolicLink }
        if values?.isDirectory == true || values?.isPackage == true
            || values?.isApplication == true || values?.isRegularFile == false {
            return .notARegularFile
        }
        if values?.isExecutable == true { return .executable }

        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, blockedFileExtensions.contains(ext) {
            return .blockedExtension(ext)
        }
        return nil
    }

    static func allowsFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        fileRejection(url, fileManager: fileManager) == nil
    }

    /// 终端工作目录：必须是真实存在的目录本体，不接受符号链接。
    static func allowsTerminalDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/") else { return false }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeDirectory
        else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else { return false }
        return true
    }
}

import ApplicationServices
import AppKit

struct ContextObservation {
    let capsule: ContextCapsule
    let sourceApplicationBundleIdentifier: String?
    let sourceProcessIdentifier: Int32?
    let windowFactsAvailable: Bool
    let limitations: [String]
}

struct AppContextSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let operatingSystem: String
    let bundleIdentifier: String?
    let appVersion: String
    let buildNumber: String
    let executable: String
    let sourceApplicationBundleIdentifier: String?
    let sourceProcessIdentifier: Int32?
    let windowFactsAvailable: Bool
    let capsule: ContextCapsule
    let limitations: [String]

    static func make(
        observation: ContextObservation,
        generatedAt: Date = Date(),
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown",
        buildNumber: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown",
        executable: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    ) -> Self {
        Self(
            schemaVersion: 1,
            generatedAt: generatedAt,
            operatingSystem: operatingSystem,
            bundleIdentifier: bundleIdentifier,
            appVersion: appVersion,
            buildNumber: buildNumber,
            executable: executable,
            sourceApplicationBundleIdentifier: observation.sourceApplicationBundleIdentifier,
            sourceProcessIdentifier: observation.sourceProcessIdentifier,
            windowFactsAvailable: observation.windowFactsAvailable,
            capsule: observation.capsule,
            limitations: observation.limitations
        )
    }
}

enum AppContextSnapshotter {
    static let reportEnvironmentKey = "LIGHTANCHOR_CONTEXT_REPORT"

    static func reportURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let path = environment[reportEnvironmentKey], path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    @discardableResult
    static func write(
        observation: ContextObservation,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        guard let destination = reportURL(environment: environment) else { return false }
        let snapshot = AppContextSnapshot.make(observation: observation)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshot).write(to: destination, options: .atomic)
        return true
    }
}

/// 无状态的窗口事实来源。标 Sendable 是为了让恢复器能整体交给后台任务：
/// AX 查询会阻塞（等窗口出现要轮询），不该占着主线程。
struct MacAccessibilityWindowFactProvider: Sendable {
    func facts(for application: NSRunningApplication) -> [ContextWindowFact] {
        guard AXIsProcessTrusted() else { return [] }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let focusedElement = elementFact(
            copyAttribute(kAXFocusedUIElementAttribute, from: applicationElement)
        )
        let windows: [AXUIElement] = copyAttribute(
            kAXWindowsAttribute,
            from: applicationElement
        ) ?? []
        guard !windows.isEmpty else { return [] }

        return windows.enumerated().map { index, window in
            let title: String = copyAttribute(kAXTitleAttribute, from: window) ?? ""
            let role: String = copyAttribute(kAXRoleAttribute, from: window) ?? ""
            let subrole: String = copyAttribute(kAXSubroleAttribute, from: window) ?? ""
            let documentURL = documentURL(for: window)
            let isMain: Bool = copyAttribute(kAXMainAttribute, from: window) ?? false
            let isFocused: Bool = copyAttribute(kAXFocusedAttribute, from: window) ?? false
            let identifier = [
                application.bundleIdentifier ?? "",
                documentURL?.absoluteString ?? "",
                title,
                role,
                subrole,
                String(index)
            ].joined(separator: "|")

            return ContextWindowFact(
                stableIdentifier: identifier,
                applicationBundleIdentifier: application.bundleIdentifier ?? "",
                title: title,
                role: role,
                subrole: subrole,
                documentURL: documentURL,
                isMain: isMain,
                isFocused: isFocused,
                focusedElement: isFocused ? focusedElement : nil
            )
        }
    }

    private func documentURL(for window: AXUIElement) -> URL? {
        let value: String? = copyAttribute(kAXDocumentAttribute, from: window)
        guard let value, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme != nil {
            // 网页地址在这里就去掉凭据 / fragment / token 参数，落盘的永远是干净的。
            return ContextURLSanitizer.sanitized(url)
        }
        return URL(fileURLWithPath: value)
    }

    private func elementFact(_ element: AXUIElement?) -> ContextElementFact? {
        guard let element else { return nil }
        let fact = ContextElementFact(
            role: copyAttribute(kAXRoleAttribute, from: element) ?? "",
            subrole: copyAttribute(kAXSubroleAttribute, from: element) ?? "",
            title: copyAttribute(kAXTitleAttribute, from: element) ?? "",
            identifier: copyAttribute(kAXIdentifierAttribute, from: element) ?? "",
            description: copyAttribute(kAXDescriptionAttribute, from: element) ?? ""
        )
        return fact.hasStableIdentity ? fact : nil
    }

    private func copyAttribute<Value>(
        _ attribute: String,
        from element: AXUIElement
    ) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Value
    }
}

/// 一个终端会话的现场事实：工作目录 + 当时正在跑的前台命令（读不到则为空）。
struct MacTerminalSession: Equatable {
    let workingDirectory: URL
    let runningCommand: String
}

struct MacTerminalWorkingDirectoryProvider {
    private struct ProcessRecord {
        let processIdentifier: Int32
        let parentProcessIdentifier: Int32
        let name: String
    }

    static let supportedBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable"
    ]

    /// 每个目录一条会话；shell 进程优先，命令取该 shell 最深的非 shell 后代
    /// （近似前台任务，如 `swift test`）。
    func sessions(for application: NSRunningApplication) -> [MacTerminalSession] {
        guard let bundleIdentifier = application.bundleIdentifier,
              Self.supportedBundleIdentifiers.contains(bundleIdentifier)
        else { return [] }

        let records = processRecords()
        let descendants = descendantProcesses(
            of: application.processIdentifier,
            records: records
        )
        let candidates = descendants.sorted { lhs, rhs in
            let leftIsShell = isShellProcess(lhs.name)
            let rightIsShell = isShellProcess(rhs.name)
            if leftIsShell != rightIsShell {
                return leftIsShell && !rightIsShell
            }
            return lhs.processIdentifier < rhs.processIdentifier
        }

        var seenDirectories = Set<URL>()
        var sessions: [MacTerminalSession] = []
        for process in candidates {
            guard let directory = currentDirectory(for: process.processIdentifier),
                  seenDirectories.insert(directory).inserted
            else { continue }
            let command = isShellProcess(process.name)
                ? foregroundCommand(ofShell: process.processIdentifier, records: records)
                : ""
            sessions.append(MacTerminalSession(
                workingDirectory: directory,
                runningCommand: command
            ))
        }
        return sessions
    }

    /// shell 的「前台命令」：其非 shell 后代里 pid 最大的那个（最近启动的近似）。
    private func foregroundCommand(
        ofShell shellProcessIdentifier: Int32,
        records: [ProcessRecord]
    ) -> String {
        let ignoredNames: Set<String> = ["ps", "lsof"]
        let candidate = descendantProcesses(of: shellProcessIdentifier, records: records)
            .filter { record in
                let basename = URL(fileURLWithPath: record.name).lastPathComponent
                return !isShellProcess(record.name) && !ignoredNames.contains(basename)
            }
            .max { $0.processIdentifier < $1.processIdentifier }
        guard let candidate,
              let output = runCommand(
                executablePath: "/bin/ps",
                arguments: ["-o", "command=", "-p", String(candidate.processIdentifier)]
              )
        else { return "" }
        let command = output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self.sanitizedCommand(command)
    }

    /// 命令行常带 token（`curl -H "Authorization: …"`、`-p密码`）。先脱敏再截断，
    /// 免得截断把一个 token 切成一半留下来。
    static func sanitizedCommand(_ command: String, limit: Int = 120) -> String {
        String(SecretRedactor.redact(command).prefix(limit))
    }

    static func isTerminalApplication(_ bundleIdentifier: String) -> Bool {
        supportedBundleIdentifiers.contains(bundleIdentifier)
    }

    private func processRecords() -> [ProcessRecord] {
        guard let output = runCommand(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,comm="]
        ) else { return [] }

        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                maxSplits: 2,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 3,
                  let processIdentifier = Int32(fields[0]),
                  let parentProcessIdentifier = Int32(fields[1])
            else { return nil }
            return ProcessRecord(
                processIdentifier: processIdentifier,
                parentProcessIdentifier: parentProcessIdentifier,
                name: String(fields[2])
            )
        }
    }

    private func descendantProcesses(
        of processIdentifier: Int32,
        records: [ProcessRecord]
    ) -> [ProcessRecord] {
        var childrenByParent: [Int32: [ProcessRecord]] = [:]
        for record in records {
            childrenByParent[record.parentProcessIdentifier, default: []].append(record)
        }

        var result: [ProcessRecord] = []
        var queue = [processIdentifier]
        var visited = Set<Int32>()
        while let parent = queue.first {
            queue.removeFirst()
            guard visited.insert(parent).inserted else { continue }
            for child in childrenByParent[parent, default: []] {
                result.append(child)
                queue.append(child.processIdentifier)
            }
        }
        return result
    }

    private func isShellProcess(_ name: String) -> Bool {
        let basename = URL(fileURLWithPath: name).lastPathComponent
        let normalized = basename.hasPrefix("-")
            ? String(basename.dropFirst())
            : basename
        return Set(["zsh", "bash", "fish", "sh", "tcsh", "ksh"]).contains(normalized)
    }

    private func currentDirectory(for processIdentifier: Int32) -> URL? {
        let lsofPath = ["/usr/sbin/lsof", "/usr/bin/lsof"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let lsofPath,
              let output = runCommand(
                executablePath: lsofPath,
                arguments: [
                    "-a",
                    "-p",
                    String(processIdentifier),
                    "-d",
                    "cwd",
                    "-Fn"
                ]
              )
        else { return nil }

        guard let path = output
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.first == "n" })
            .map({ String($0.dropFirst()) }),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func runCommand(
        executablePath: String,
        arguments: [String]
    ) -> String? {
        // `ps` on a busy Mac already emits ~63 KB, and the pipe buffer tops out
        // at 64 KB, so this must drain while the child runs rather than after it.
        ProcessExecutionSupport.runSynchronously(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments
        )
    }
}

/// 现场采集开关（对应设置里的「保存终端…」「保存剪贴板…」）。
struct ContextCaptureOptions {
    /// 采集终端工作目录和运行命令。
    var includeTerminal: Bool = true
    /// 采集剪贴板文字（截断到 `clipboardCharacterLimit`）。
    var includeClipboard: Bool = false
    var clipboardCharacterLimit: Int = 2000
    var sourcePreferences: SceneCapturePreferences

    static var `default`: ContextCaptureOptions { ContextCaptureOptions() }

    init(
        includeTerminal: Bool = true,
        includeClipboard: Bool = false,
        sourcePreferences: SceneCapturePreferences = .load()
    ) {
        self.includeTerminal = includeTerminal
        self.includeClipboard = includeClipboard
        self.sourcePreferences = sourcePreferences
    }

    init(
        preferences: IntelligencePreferences,
        sourcePreferences: SceneCapturePreferences = .load()
    ) {
        self.includeTerminal = preferences.saveTerminalCommands
        self.includeClipboard = preferences.saveClipboardContent
        self.sourcePreferences = sourcePreferences
    }
}

final class MacContextRecorder {
    private let windowFactProvider = MacAccessibilityWindowFactProvider()
    private let terminalWorkingDirectoryProvider = MacTerminalWorkingDirectoryProvider()

    func capture(note: String = "", options: ContextCaptureOptions = .default) -> ContextObservation {
        let frontmost = NSWorkspace.shared.frontmostApplication
        // 现场是整张桌面，不只是前台那一个应用——尤其是从本应用内点
        // 「记录当前现场」时，前台应用就是我们自己，只看它必然一无所获。
        // 双重排除自己：bundle ID 匹配正式包，pid 兜底裸二进制（无 bundle ID）。
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        var candidates = NSWorkspace.shared.runningApplications.filter { application in
            application.activationPolicy == .regular
                && !application.isHidden
                && application.processIdentifier != ownProcessIdentifier
                && (ownBundleIdentifier == nil || application.bundleIdentifier != ownBundleIdentifier)
        }
        // 前台应用排最前，让「当前在用什么」保持在现场清单的开头。
        if let frontmost, let index = candidates.firstIndex(where: {
            $0.processIdentifier == frontmost.processIdentifier
        }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }

        var applicationNames: [String] = []
        var applicationBundleIdentifiers: [String] = []
        var windowFacts: [ContextWindowFact] = []
        var terminalSessions: [MacTerminalSession] = []
        for application in candidates {
            guard let bundleIdentifier = application.bundleIdentifier,
                  options.sourcePreferences.allowsApplication(bundleIdentifier)
            else { continue }
            let facts = windowFactProvider.facts(for: application).filter {
                options.sourcePreferences.allowsDocumentURL($0.documentURL)
            }
            let applicationSessions = options.includeTerminal
                ? terminalWorkingDirectoryProvider.sessions(for: application)
                : []
            // 只保留真正开着窗口（或有终端目录）的应用，后台常驻的不算现场。
            guard !facts.isEmpty || !applicationSessions.isEmpty else { continue }
            applicationNames.append(application.localizedName ?? bundleIdentifier)
            applicationBundleIdentifiers.append(bundleIdentifier)
            windowFacts.append(contentsOf: facts)
            terminalSessions.append(contentsOf: applicationSessions)
        }
        // 目录去重（保序），命令随所属会话同步保留。
        var seenTerminalDirectories = Set<URL>()
        terminalSessions = terminalSessions.filter {
            seenTerminalDirectories.insert($0.workingDirectory).inserted
        }

        // 事实来源可注入（测试 / 其他 provider），这里再清洗一遍链接，不依赖上游。
        windowFacts = windowFacts.map { fact in
            guard let documentURL = fact.documentURL else { return fact }
            let sanitized = ContextURLSanitizer.sanitized(documentURL)
            guard sanitized != documentURL else { return fact }
            // 稳定标识里也拼了地址，同步替换，别让 token 从这条缝里漏出去。
            return ContextWindowFact(
                stableIdentifier: fact.stableIdentifier.replacingOccurrences(
                    of: documentURL.absoluteString,
                    with: sanitized.absoluteString
                ),
                applicationBundleIdentifier: fact.applicationBundleIdentifier,
                title: fact.title,
                role: fact.role,
                subrole: fact.subrole,
                documentURL: sanitized,
                isMain: fact.isMain,
                isFocused: fact.isFocused,
                focusedElement: fact.focusedElement
            )
        }
        let documentURLs = windowFacts.compactMap(\.documentURL)
        let files = documentURLs.filter(\.isFileURL)
        let links = documentURLs.filter(ContextURLSanitizer.isWebURL)
        var limitations: [String] = []

        if frontmost == nil {
            limitations.append(tr("couldn_t_read_the_frontmost_app"))
        }
        if !AXIsProcessTrusted() {
            limitations.append(tr("no_accessibility_permission_apps_only"))
        } else if windowFacts.isEmpty {
            limitations.append(tr("no_open_app_exposed_window_facts"))
        }
        if options.includeTerminal,
           applicationBundleIdentifiers.contains(
               where: MacTerminalWorkingDirectoryProvider.isTerminalApplication
           ), terminalSessions.isEmpty {
            limitations.append(tr("couldn_t_read_terminal_directories"))
        }

        return ContextObservation(
            capsule: ContextCapsule(
                applications: applicationNames,
                applicationBundleIdentifiers: applicationBundleIdentifiers,
                windows: windowFacts.map(\.title).filter { !$0.isEmpty },
                windowFacts: windowFacts,
                files: files,
                links: links,
                terminalWorkingDirectories: terminalSessions.map(\.workingDirectory),
                terminalCommands: terminalSessions.map(\.runningCommand),
                clipboardText: options.includeClipboard
                    ? Self.clipboardText(
                        limit: options.clipboardCharacterLimit,
                        frontmostBundleIdentifier: frontmost?.bundleIdentifier
                    )
                    : "",
                note: note
            ),
            sourceApplicationBundleIdentifier: frontmost?.bundleIdentifier,
            sourceProcessIdentifier: frontmost?.processIdentifier,
            windowFactsAvailable: !windowFacts.isEmpty,
            limitations: limitations
        )
    }

    /// 读剪贴板文字。密码管理器等标记为机密/瞬态的内容一律不读；前台是终端或
    /// 密码管理器时整段跳过（剪贴板里大概率是刚复制的命令或口令）；剩下的文字
    /// 也先脱敏再截断。
    private static func clipboardText(limit: Int, frontmostBundleIdentifier: String?) -> String {
        if let frontmostBundleIdentifier,
           isClipboardSensitiveApplication(frontmostBundleIdentifier) {
            return ""
        }
        let pasteboard = NSPasteboard.general
        let sensitiveTypes = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        ]
        let types = pasteboard.types ?? []
        guard !types.contains(where: sensitiveTypes.contains) else { return "" }
        guard let text = pasteboard.string(forType: .string) else { return "" }
        return sanitizedClipboardText(text, limit: limit)
    }

    /// 脱敏在截断之前，避免截断把 token 切一半留下。
    static func sanitizedClipboardText(_ text: String, limit: Int) -> String {
        let trimmed = SecretRedactor.redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }

    /// 密码管理器的 bundle ID 片段（小写匹配），加上所有受支持的终端。
    static let passwordManagerBundleIdentifierFragments: [String] = [
        "1password", "bitwarden", "keepass", "lastpass", "dashlane",
        "com.apple.passwords", "com.apple.keychainaccess",
        "enpass", "nordpass", "protonpass", "roboform", "strongbox",
    ]

    static func isClipboardSensitiveApplication(_ bundleIdentifier: String) -> Bool {
        let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if MacTerminalWorkingDirectoryProvider.isTerminalApplication(bundleIdentifier) {
            return true
        }
        return passwordManagerBundleIdentifierFragments.contains { normalized.contains($0) }
    }
}

struct ContextRestoreReport: Codable, Equatable {
    var openedApplications: [String] = []
    var restoredWindows: [ContextWindowFact] = []
    var openedFiles: [URL] = []
    var openedLinks: [URL] = []
    var openedTerminalWorkingDirectories: [URL] = []
    var limitations: [String] = []
    var failures: [String] = []

    var succeeded: Bool { failures.isEmpty && limitations.isEmpty }
    var hasIssues: Bool { !failures.isEmpty || !limitations.isEmpty }

    var summary: String {
        var parts: [String] = []
        if !restoredWindows.isEmpty {
            parts.append(String(
                format: restoredWindows.count == 1
                    ? tr("restored_n_windows_one") : tr("restored_n_windows"),
                restoredWindows.count
            ))
        }
        if !openedFiles.isEmpty || !openedLinks.isEmpty {
            parts.append(
                String(
                    format: openedFiles.count + openedLinks.count == 1
                        ? tr("reopened_n_files_or_links_one") : tr("reopened_n_files_or_links"),
                    openedFiles.count + openedLinks.count
                )
            )
        }
        if !openedTerminalWorkingDirectories.isEmpty {
            parts.append(
                String(
                    format: openedTerminalWorkingDirectories.count == 1
                        ? tr("restored_n_terminal_directories_one")
                        : tr("restored_n_terminal_directories"),
                    openedTerminalWorkingDirectories.count
                )
            )
        }
        parts.append(contentsOf: limitations)
        parts.append(contentsOf: failures)
        return parts.isEmpty ? tr("no_restorable_context_found") : parts.joined(separator: " ")
    }
}

struct AppContextRestorationSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let source: AppContextSnapshot
    let report: ContextRestoreReport
}

enum AppContextRestorationSnapshotter {
    static let inputEnvironmentKey = "LIGHTANCHOR_CONTEXT_RESTORE_INPUT"
    static let reportEnvironmentKey = "LIGHTANCHOR_CONTEXT_RESTORE_REPORT"

    static func inputURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        absoluteURL(for: inputEnvironmentKey, environment: environment)
    }

    static func reportURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        absoluteURL(for: reportEnvironmentKey, environment: environment)
    }

    static func loadSource(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppContextSnapshot? {
        guard let sourceURL = inputURL(environment: environment) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppContextSnapshot.self, from: Data(contentsOf: sourceURL))
    }

    @discardableResult
    static func write(
        source: AppContextSnapshot,
        report: ContextRestoreReport,
        generatedAt: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        guard let destination = reportURL(environment: environment) else { return false }
        let snapshot = AppContextRestorationSnapshot(
            schemaVersion: 1,
            generatedAt: generatedAt,
            source: source,
            report: report
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshot).write(to: destination, options: .atomic)
        return true
    }

    private static func absoluteURL(
        for key: String,
        environment: [String: String]
    ) -> URL? {
        guard let path = environment[key], path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

final class MacContextRestorer: Sendable {
    private let windowFactProvider = MacAccessibilityWindowFactProvider()

    /// 只把焦点还给捕获前那个应用。
    ///
    /// 快速捕获的「保存后回到原上下文」要的就是回到刚才那个窗口。走
    /// `restore(_:)` 会按整张现场清单把每个应用都激活一遍、并打开里面的文件和
    /// 链接——那是环境恢复该做的事，用在一次随手捕获之后只会把桌面翻乱。
    /// pid 优先（同一应用可能开着多个实例），读不到再按 bundle ID 找。
    @discardableResult
    func returnFocus(
        toProcessIdentifier processIdentifier: Int32?,
        bundleIdentifier: String?
    ) -> Bool {
        if let processIdentifier,
           let application = NSRunningApplication(processIdentifier: processIdentifier),
           !application.isTerminated {
            return application.activate()
        }
        guard let bundleIdentifier,
              let application = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
              })
        else { return false }
        return application.activate()
    }

    func restore(_ context: ContextCapsule) -> ContextRestoreReport {
        var report = ContextRestoreReport()
        let bundleIdentifiers = Set(
            context.applicationBundleIdentifiers
                + context.windowFacts.map(\.applicationBundleIdentifier)
                .filter { !$0.isEmpty }
        )

        for bundleIdentifier in bundleIdentifiers.sorted() {
            guard let application = activateApplication(
                bundleIdentifier: bundleIdentifier,
                report: &report
            ) else { continue }

            let facts = context.windowFacts.filter {
                $0.applicationBundleIdentifier == bundleIdentifier
            }
            guard !facts.isEmpty else { continue }
            guard AXIsProcessTrusted() else {
                report.failures.append(
                    String(format: tr("restoring_windows_needs_accessibility"), bundleIdentifier)
                )
                continue
            }

            let missingFacts = restoreWindows(
                facts,
                for: application,
                report: &report,
                recordMissingFailures: false
            )
            guard !missingFacts.isEmpty else { continue }

            for fact in missingFacts {
                guard let documentURL = fact.documentURL else { continue }
                openDocument(documentURL, report: &report)
            }

            let unresolvedFacts = waitForWindows(
                missingFacts,
                in: application,
                report: &report
            )
            for fact in unresolvedFacts {
                let label = fact.title.isEmpty ? fact.stableIdentifier : fact.title
                report.failures.append(String(format: tr("couldn_t_locate_window"), label))
            }
        }

        let windowDocumentURLs = Set(context.windowFacts.compactMap(\.documentURL))
        for fileURL in context.files where !windowDocumentURLs.contains(fileURL) {
            guard Self.allowsOpening(fileURL, report: &report) else { continue }
            if NSWorkspace.shared.open(fileURL) {
                report.openedFiles.append(fileURL)
            } else {
                report.failures.append(String(format: tr("couldn_t_open_file"), fileURL.path))
            }
        }

        for link in context.links where !windowDocumentURLs.contains(link) {
            guard Self.allowsOpening(link, report: &report) else { continue }
            if NSWorkspace.shared.open(link) {
                report.openedLinks.append(link)
            } else {
                report.failures.append(String(format: tr("couldn_t_open_link"), link.absoluteString))
            }
        }

        restoreTerminalWorkingDirectories(context, report: &report)
        return report
    }

    /// 恢复端的白名单门：只放普通文档文件和 http/https 链接，其余记入失败并跳过。
    /// 这些 URL 来自持久化数据（快照、备份），不能假定就是当时采集到的东西。
    static func allowsOpening(_ url: URL, report: inout ContextRestoreReport) -> Bool {
        if url.isFileURL {
            guard RestoreItemPolicy.allowsFile(url) else {
                report.failures.append(
                    String(format: tr("skipped_unsafe_item_on_restore"), url.path)
                )
                return false
            }
            return true
        }
        guard RestoreItemPolicy.allowsLink(url) else {
            report.failures.append(
                String(format: tr("skipped_unsafe_item_on_restore"), url.absoluteString)
            )
            return false
        }
        return true
    }

    private func restoreTerminalWorkingDirectories(
        _ context: ContextCapsule,
        report: inout ContextRestoreReport
    ) {
        guard !context.terminalWorkingDirectories.isEmpty else { return }
        guard let terminalBundleIdentifier = context.applicationBundleIdentifiers
            .first(where: MacTerminalWorkingDirectoryProvider.isTerminalApplication),
              let terminalURL = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: terminalBundleIdentifier)
        else {
            report.limitations.append(tr("terminal_directories_saved_but_no_terminal_app"))
            return
        }

        for directory in context.terminalWorkingDirectories {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                report.failures.append(
                    String(format: tr("terminal_directory_is_gone"), directory.path)
                )
                continue
            }
            // 只把真实存在的目录本体交给终端：文件、符号链接、bundle 都不算，
            // 否则 `open -a Terminal <path>` 会把它当脚本/文档去执行或打开。
            guard RestoreItemPolicy.allowsTerminalDirectory(directory) else {
                report.failures.append(
                    String(format: tr("skipped_unsafe_item_on_restore"), directory.path)
                )
                continue
            }
            // 用 NSWorkspace 而不是再起一个 `/usr/bin/open` 子进程：目录 URL 直接
            // 交给终端应用，不经过命令行参数解析。
            if Self.openDirectory(directory, withApplicationAt: terminalURL) {
                report.openedTerminalWorkingDirectories.append(directory)
            } else {
                report.failures.append(
                    String(format: tr("couldn_t_open_terminal_directory"), directory.path)
                )
            }
        }
    }

    /// 同步等待 NSWorkspace 的打开结果。恢复器本身就在后台线程阻塞轮询 AX，
    /// 这里再等一个回调不改变它的线程模型；回调在系统的并发队列上派发，
    /// 不会与等待方互锁。超时按失败处理，不让恢复卡死。
    private static func openDirectory(_ directory: URL, withApplicationAt applicationURL: URL) -> Bool {
        let outcome = OpenOutcome()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            outcome.finish(succeeded: error == nil)
        }
        return outcome.wait(timeout: .now() + .seconds(10))
    }

    private final class OpenOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var succeeded = false

        func finish(succeeded: Bool) {
            lock.lock()
            self.succeeded = succeeded
            lock.unlock()
            semaphore.signal()
        }

        func wait(timeout: DispatchTime) -> Bool {
            guard semaphore.wait(timeout: timeout) == .success else { return false }
            lock.lock()
            defer { lock.unlock() }
            return succeeded
        }
    }

    private func activateApplication(
        bundleIdentifier: String,
        report: inout ContextRestoreReport
    ) -> NSRunningApplication? {
        if let runningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first {
            guard runningApplication.activate(options: [.activateAllWindows]) else {
                report.failures.append(String(format: tr("couldn_t_activate_app"), bundleIdentifier))
                return nil
            }
            report.openedApplications.append(bundleIdentifier)
            return runningApplication
        }

        guard let applicationURL = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleIdentifier),
              NSWorkspace.shared.open(applicationURL)
        else {
            report.failures.append(String(format: tr("app_not_found"), bundleIdentifier))
            return nil
        }

        report.openedApplications.append(bundleIdentifier)
        guard let runningApplication = waitForRunningApplication(bundleIdentifier: bundleIdentifier) else {
            report.failures.append(
            String(format: tr("app_launched_but_unreachable"), bundleIdentifier)
        )
            return nil
        }
        return runningApplication
    }

    private func waitForRunningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        for _ in 0..<20 {
            if let application = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first {
                _ = application.activate(options: [.activateAllWindows])
                return application
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func restoreWindows(
        _ facts: [ContextWindowFact],
        for application: NSRunningApplication,
        report: inout ContextRestoreReport,
        recordMissingFailures: Bool = true
    ) -> [ContextWindowFact] {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let windows: [AXUIElement] = copyAttribute(kAXWindowsAttribute, from: applicationElement) ?? []
        let availableFacts = windows.enumerated().map { index, window in
            WindowCandidate(
                element: window,
                fact: fact(for: window, application: application, index: index)
            )
        }

        var usedWindowIndices = Set<Int>()
        var missingFacts: [ContextWindowFact] = []
        for requestedFact in facts {
            guard let match = availableFacts.enumerated().first(where: { index, candidate in
                !usedWindowIndices.contains(index) &&
                matches(requestedFact, actual: candidate.fact)
            }) else {
                let label = requestedFact.title.isEmpty ? requestedFact.stableIdentifier : requestedFact.title
                missingFacts.append(requestedFact)
                if recordMissingFailures {
                    report.failures.append(String(format: tr("couldn_t_locate_window"), label))
                }
                continue
            }
            usedWindowIndices.insert(match.offset)
            let candidate = match.element

            _ = AXUIElementPerformAction(candidate.element, kAXRaiseAction as CFString)
            if requestedFact.isMain {
                _ = AXUIElementSetAttributeValue(
                    candidate.element,
                    kAXMainAttribute as CFString,
                    kCFBooleanTrue
                )
            }
            if requestedFact.isFocused {
                _ = AXUIElementSetAttributeValue(
                    candidate.element,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
                if let focusedElement = requestedFact.focusedElement,
                   !restoreFocusedElement(focusedElement, in: candidate.element) {
                    report.limitations.append(
                    String(format: tr("couldn_t_restore_input_focus"), requestedFact.title)
                )
                }
            }
            report.restoredWindows.append(requestedFact)
        }
        return missingFacts
    }

    private func waitForWindows(
        _ facts: [ContextWindowFact],
        in application: NSRunningApplication,
        report: inout ContextRestoreReport
    ) -> [ContextWindowFact] {
        var unresolvedFacts = facts
        for _ in 0..<20 where !unresolvedFacts.isEmpty {
            Thread.sleep(forTimeInterval: 0.05)
            unresolvedFacts = restoreWindows(
                unresolvedFacts,
                for: application,
                report: &report,
                recordMissingFailures: false
            )
        }
        return unresolvedFacts
    }

    private func openDocument(_ url: URL, report: inout ContextRestoreReport) {
        guard Self.allowsOpening(url, report: &report) else { return }
        if NSWorkspace.shared.open(url) {
            if url.isFileURL {
                report.openedFiles.append(url)
            } else if ["http", "https"].contains(url.scheme?.lowercased()) {
                report.openedLinks.append(url)
            }
        } else if url.isFileURL {
            report.failures.append(String(format: tr("couldn_t_open_file"), url.path))
        } else {
            report.failures.append(String(format: tr("couldn_t_open_link"), url.absoluteString))
        }
    }

    private struct WindowCandidate {
        let element: AXUIElement
        let fact: ContextWindowFact
    }

    private func fact(
        for window: AXUIElement,
        application: NSRunningApplication,
        index: Int
    ) -> ContextWindowFact {
        let title: String = copyAttribute(kAXTitleAttribute, from: window) ?? ""
        let role: String = copyAttribute(kAXRoleAttribute, from: window) ?? ""
        let subrole: String = copyAttribute(kAXSubroleAttribute, from: window) ?? ""
        let documentURL = documentURL(for: window)
        let isMain: Bool = copyAttribute(kAXMainAttribute, from: window) ?? false
        let isFocused: Bool = copyAttribute(kAXFocusedAttribute, from: window) ?? false
        let identifier = [
            application.bundleIdentifier ?? "",
            documentURL?.absoluteString ?? "",
            title,
            role,
            subrole,
            String(index)
        ].joined(separator: "|")
        return ContextWindowFact(
            stableIdentifier: identifier,
            applicationBundleIdentifier: application.bundleIdentifier ?? "",
            title: title,
            role: role,
            subrole: subrole,
            documentURL: documentURL,
            isMain: isMain,
            isFocused: isFocused
        )
    }

    private func documentURL(for window: AXUIElement) -> URL? {
        let value: String? = copyAttribute(kAXDocumentAttribute, from: window)
        guard let value, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme != nil {
            // 与采集侧同样清洗，否则带 token 的实时地址永远匹配不上存下来的干净地址。
            return ContextURLSanitizer.sanitized(url)
        }
        return URL(fileURLWithPath: value)
    }

    private func matches(_ requested: ContextWindowFact, actual: ContextWindowFact) -> Bool {
        if let requestedDocumentURL = requested.documentURL,
           let actualDocumentURL = actual.documentURL,
           requestedDocumentURL == actualDocumentURL {
            return true
        }
        if !requested.title.isEmpty && requested.title == actual.title {
            return requested.role.isEmpty || requested.role == actual.role
        }
        return requested.stableIdentifier == actual.stableIdentifier
    }

    private func restoreFocusedElement(
        _ requested: ContextElementFact,
        in window: AXUIElement
    ) -> Bool {
        var visited = 0
        return findAndFocus(
            requested,
            in: window,
            depth: 0,
            visited: &visited
        )
    }

    private func findAndFocus(
        _ requested: ContextElementFact,
        in element: AXUIElement,
        depth: Int,
        visited: inout Int
    ) -> Bool {
        guard depth <= 8, visited < 2_000 else { return false }
        visited += 1

        if elementMatches(requested, actual: element) {
            return AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            ) == .success
        }

        let children: [AXUIElement] = copyAttribute(kAXChildrenAttribute, from: element) ?? []
        for child in children where findAndFocus(
            requested,
            in: child,
            depth: depth + 1,
            visited: &visited
        ) {
            return true
        }
        return false
    }

    private func elementMatches(
        _ requested: ContextElementFact,
        actual element: AXUIElement
    ) -> Bool {
        let actualIdentifier: String = copyAttribute(kAXIdentifierAttribute, from: element) ?? ""
        if !requested.identifier.isEmpty && requested.identifier == actualIdentifier {
            return true
        }

        let actualRole: String = copyAttribute(kAXRoleAttribute, from: element) ?? ""
        let actualSubrole: String = copyAttribute(kAXSubroleAttribute, from: element) ?? ""
        let actualTitle: String = copyAttribute(kAXTitleAttribute, from: element) ?? ""
        let actualDescription: String = copyAttribute(kAXDescriptionAttribute, from: element) ?? ""
        guard !requested.role.isEmpty,
              requested.role == actualRole,
              requested.subrole.isEmpty || requested.subrole == actualSubrole
        else { return false }

        if !requested.title.isEmpty && requested.title == actualTitle { return true }
        return !requested.description.isEmpty && requested.description == actualDescription
    }

    private func copyAttribute<Value>(
        _ attribute: String,
        from element: AXUIElement
    ) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Value
    }
}

final class CaptureContextStore: @unchecked Sendable {
    static let shared = CaptureContextStore()

    private let lock = NSLock()
    private var pending: ContextObservation?

    func prepare() {
        let observation = MacContextRecorder().capture(
            options: ContextCaptureOptions(preferences: .load())
        )
        lock.lock()
        pending = observation
        lock.unlock()
    }

    func consume() -> ContextObservation? {
        lock.lock()
        defer { lock.unlock() }
        let observation = pending
        pending = nil
        return observation
    }
}
