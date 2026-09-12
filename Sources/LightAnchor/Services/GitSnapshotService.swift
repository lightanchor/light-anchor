import Foundation

/// 一个可回退的版本：`id` 是 git 的 commit hash，`date` 是提交时间。
/// 提交哈希是唯一标识；它由内容决定，所以两台机器对同一批数据产生同一个
/// commit id，`date` 只用作展示。
struct LightAnchorSnapshot: Equatable {
    let id: String
    let date: Date
    let subject: String
}

/// 数据根目录上的 git 快照引擎（叠加层，不做运行时数据源）。
///
/// 设计要点：
/// - 仓库就开在数据根目录（`LIGHTANCHOR_DATA_ROOT` 或 Application Support/LightAnchor），
///   快照覆盖 `events/  assets/  recordings/  clipboard/`。`.gitignore` 已把缓存与
///   本机状态排除在外，所以版本库里的都是用户数据。
/// - 运行时读写**永远不经过 git**：应用读的是事件日志源文件，git 只是它们盖上
///   的版本与备份层。git 失败时应用照常工作。
/// - 所有命令在串行队列上执行，单个快照原子，互不交错。
/// - 身份只在**本仓库**的 config 里设置（`user.name/email`），不碰全局配置。
///
/// `@unchecked Sendable`：全部可变状态都收敛在 `queue` 这条串行队列后面，
/// `rootURL` 与 `userDefaults` 自身线程安全。
final class GitSnapshotService: @unchecked Sendable {
    let rootURL: URL
    private let queue = DispatchQueue(label: "light-anchor.git-snapshot")
    private let userDefaults: UserDefaults
    /// 取 GitHub 令牌（默认读 Keychain）。可注入，测试不碰 Keychain。
    private let tokenProvider: @Sendable () -> String?

    init(
        rootURL: URL = LightAnchorStorage.rootURL(),
        userDefaults: UserDefaults = .standard,
        tokenProvider: @escaping @Sendable () -> String? = { KeychainGitHubTokenStore().readToken() }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.userDefaults = userDefaults
        self.tokenProvider = tokenProvider
    }

    /// 对 github.com 的 https 远端注入认证头。走环境变量形式的 git 配置
    /// （`GIT_CONFIG_*`），令牌不出现在命令行参数里，也不写进任何配置文件。
    func authEnvironment(for remote: URL) -> [String: String] {
        guard remote.scheme == "https",
              let host = remote.host, host == "github.com" || host.hasSuffix(".github.com"),
              let token = tokenProvider()
        else { return [:] }
        let credentials = Data("x-access-token:\(token)".utf8).base64EncodedString()
        return [
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
            "GIT_CONFIG_VALUE_0": "Authorization: Basic \(credentials)"
        ]
    }

    // MARK: - 初始化

    /// 确保根目录是 git 仓库并备好提交身份。幂等，可重复调用。
    func prepare() throws {
        try onQueue { try ensureRepository(); try ensureIdentity() }
    }

    func ensureRepository() throws {
        guard !isRepository else { return }
        // 全新安装时数据根目录还不存在（第一条事件都没写过），先把它建出来，
        // 否则 git init 失败且没人重试，快照会静默失效到下次启动。
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try GitRunner.run(in: rootURL, ["init", "-b", "main"])
    }

    func ensureIdentity() throws {
        let name = (try? GitRunner.run(in: rootURL, ["config", "user.name"])) ?? ""
        let email = (try? GitRunner.run(in: rootURL, ["config", "user.email"])) ?? ""
        if name.isEmpty {
            try GitRunner.run(in: rootURL, ["config", "user.name", "LightAnchor"])
        }
        if email.isEmpty {
            try GitRunner.run(in: rootURL, ["config", "user.email", "snapshot@lightanchor.local"])
        }
    }

    var isRepository: Bool {
        FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent(".git", isDirectory: true).path
        )
    }

    // MARK: - 快照

    /// 提交一个快照。没有变化则返回 nil（不产生空提交）。
    /// `note` 是给这次快照的一句话说明，落进 commit 的 subject。
    ///
    /// 只在仓库已存在时工作：快照绝不自己 `git init`。否则「删除全部本地数据」
    /// 之后一个迟到的去抖快照会把 .git 又建回来。
    @discardableResult
    func snapshot(note: String = "") throws -> LightAnchorSnapshot? {
        try onQueue {
            guard isRepository else { return nil }
            try ensureIdentity()
            try GitRunner.run(in: rootURL, ["add", "-A"])
            guard hasStagedChanges else { return nil }
            let subject = SnapshotNote.combined([SnapshotNote(subject: note)])
            try GitRunner.run(in: rootURL, ["commit", "-m", subject])
            let id = try GitRunner.run(in: rootURL, ["rev-parse", "HEAD"])
            let date = try commitDate(of: id)
            return LightAnchorSnapshot(id: id, date: date, subject: subject)
        }
    }

    private var hasStagedChanges: Bool {
        // `status --porcelain` 只有已暂存（staged）的差异时，git 退出码还是 0，
        // 所以不能用退出码判「有没有差异」。porcelain 输出每行一个变更，非空即有。
        guard isRepository else { return false }
        let status = (try? GitRunner.run(in: rootURL, ["status", "--porcelain"])) ?? ""
        let staged = status.split(separator: "\n").filter { !$0.hasPrefix("??") }
        return !staged.isEmpty
    }

    /// 最近 `limit` 个快照，最新的在前。
    func history(limit: Int = 60) throws -> [LightAnchorSnapshot] {
        try onQueue {
            guard isRepository else { return [] }
            let format = "%H%x1f%at%x1f%s%x00"
            let output = try GitRunner.run(
                in: rootURL,
                ["log", "-n", "\(limit)", "--pretty=format:\(format)"]
            )
            return Self.parseHistory(output)
        }
    }

    /// 把数据目录还原到 `snapshotID` 覆盖到的时刻。
    ///
    /// 做了三件事：(1) 把**当前**状态先提交成一个「还原前」快照（这样还原是
    /// 可撤销的，不会丢现在的工作）；(2) `reset --hard` 到目标；(3) 通知上层
    /// 重新从磁盘载入。`.git` 目录不动——还原的是数据，版本历史还在。
    ///
    /// 返回「还原前」快照，上层可以提示用户如果想回去能从它跳回。
    @discardableResult
    func restore(to snapshotID: String) throws -> LightAnchorSnapshot? {
        try onQueue {
            guard isRepository else { throw GitServiceError.invalidSnapshot }
            // 先给当前状态拍一张，保证还原可撤销。
            try GitRunner.run(in: rootURL, ["add", "-A"])
            let before: LightAnchorSnapshot?
            if hasStagedChanges {
                let subject = String(format: tr("snapshot_note_before_restore"), String(snapshotID.prefix(8)))
                try GitRunner.run(in: rootURL, ["commit", "-m", subject])
                let id = try GitRunner.run(in: rootURL, ["rev-parse", "HEAD"])
                before = LightAnchorSnapshot(id: id, date: try commitDate(of: id), subject: subject)
            } else {
                before = nil
            }
            // 还原整个树（工作区 + 索引），不动 `.git`。
            try GitRunner.run(in: rootURL, ["reset", "--hard", snapshotID])
            return before
        }
    }

    /// 把数据根目录的版本库整个删掉（连同数据的 `.git`）。删除全部本地数据时用。
    func removeRepository() throws {
        try onQueue {
            let gitDir = rootURL.appendingPathComponent(".git", isDirectory: true)
            if FileManager.default.fileExists(atPath: gitDir.path) {
                try FileManager.default.removeItem(at: gitDir)
            }
        }
    }

    // MARK: - 同步

    enum SyncOutcome: Equatable {
        /// 远端没有本地不知道的东西；本地新内容已推上去。
        case alreadyUpToDate
        /// 远端内容并进来了（含首次从远端接入）。上层需要重新从磁盘载入。
        case merged
    }

    /// 与远端双向同步：先把本地未快照的改动拍下来，取回远端，把两边并起来，
    /// 再推回去。事件是一条一个文件，两台机器各自新增的事件天然落在不同文件，
    /// 合并就是并集；只有「同一条事件在两台机器上都被改过」才需要裁决。
    ///
    /// 裁决规则（两台机器各自执行也会得出同一结果，保证收敛）：
    /// 1. **删除优先**——任何一边删了这条记录，合并结果就是删。删除往往是
    ///    隐私动作，不能被另一台机器的旧副本复活。
    /// 2. 两边都改了内容：取 blob 哈希字典序大的一方。规则本身无业务含义，
    ///    要的只是对称与确定——A、B 各自合并都选同一个赢家，一次同步后一致。
    func sync() throws -> SyncOutcome {
        do {
            let outcome = try syncOnce()
            onQueue {
                userDefaults.set(Date(), forKey: Self.lastSyncDateKey)
                userDefaults.removeObject(forKey: Self.lastSyncErrorKey)
            }
            return outcome
        } catch {
            // 自动同步是静默的，失败必须留下痕迹，设置页才有东西可给用户看。
            onQueue {
                userDefaults.set(Date(), forKey: Self.lastSyncDateKey)
                userDefaults.set(error.localizedDescription, forKey: Self.lastSyncErrorKey)
            }
            throw error
        }
    }

    var lastSyncDate: Date? {
        userDefaults.object(forKey: Self.lastSyncDateKey) as? Date
    }

    var lastSyncError: String? {
        userDefaults.string(forKey: Self.lastSyncErrorKey)
    }

    private func syncOnce() throws -> SyncOutcome {
        try onQueue {
            guard let remote = remoteURL else {
                throw GitServiceError.noRemoteConfigured
            }
            guard isRepository else { throw GitServiceError.invalidSnapshot }
            try ensureIdentity()

            // 本地未快照的改动先拍下来，合并才不会碰到脏工作区。
            try GitRunner.run(in: rootURL, ["add", "-A"])
            if hasStagedChanges {
                try GitRunner.run(in: rootURL, ["commit", "-m", tr("snapshot_note_before_sync")])
            }

            _ = try? GitRunner.run(in: rootURL, ["remote", "remove", "origin"])
            try GitRunner.run(in: rootURL, ["remote", "add", "origin", remote.absoluteString])

            // 远端还是空仓（第一次有人推）：没有可取的，直接推。
            let auth = authEnvironment(for: remote)
            let fetched = (try? GitRunner.run(
                in: rootURL, ["fetch", "origin", "main"], environment: auth
            )) != nil
            guard fetched else {
                try pushCurrentBranch(to: remote)
                return .alreadyUpToDate
            }

            let localHead = try? GitRunner.run(in: rootURL, ["rev-parse", "HEAD"])
            guard let localHead else {
                // 本地一个提交都没有：这台机器是新加入的，直接采纳远端。
                try GitRunner.run(in: rootURL, ["reset", "--hard", "FETCH_HEAD"])
                // 内容与远端一致，推送是无操作——但它记录「远端流动已获用户
                // 确认」（lastPushDate），此后定时自动同步才会接管。
                try pushCurrentBranch(to: remote)
                return .merged
            }

            let remoteHead = try GitRunner.run(in: rootURL, ["rev-parse", "FETCH_HEAD"])
            if remoteHead == localHead {
                try pushCurrentBranch(to: remote)
                return .alreadyUpToDate
            }
            // 远端是本地的祖先（只有本地在前进）→ 无需合并，推上去即可。
            let isAncestor = (try? GitRunner.run(
                in: rootURL, ["merge-base", "--is-ancestor", remoteHead, localHead]
            )) != nil
            if isAncestor {
                try pushCurrentBranch(to: remote)
                return .alreadyUpToDate
            }

            // 真正的合并。两台各自 init 的机器历史无共同祖先，明确允许。
            do {
                try GitRunner.run(in: rootURL, [
                    "merge", "--no-edit", "-m", tr("snapshot_note_synced"),
                    "--allow-unrelated-histories", "FETCH_HEAD"
                ])
            } catch {
                try resolveMergeConflictsDeterministically(originalError: error)
            }
            try pushCurrentBranch(to: remote)
            return .merged
        }
    }

    private func pushCurrentBranch(to remote: URL) throws {
        try GitRunner.run(
            in: rootURL,
            ["push", "-u", "origin", "HEAD"],
            environment: authEnvironment(for: remote)
        )
        lastPushDate = Date()
    }

    /// 合并冲突的确定性裁决（见 `sync()` 注释）。只在真的存在未合并路径时
    /// 接手；其他原因的合并失败（比如根本不是冲突）原样抛回并中止合并。
    private func resolveMergeConflictsDeterministically(originalError: Error) throws {
        let unmerged = (try? GitRunner.run(
            in: rootURL, ["diff", "--name-only", "--diff-filter=U"]
        )) ?? ""
        let paths = unmerged.split(separator: "\n").map(String.init)
        guard !paths.isEmpty else {
            _ = try? GitRunner.run(in: rootURL, ["merge", "--abort"])
            throw originalError
        }

        for path in paths {
            // `ls-files -u` 每行：mode hash stage\tpath。stage 2=本地，3=远端。
            let stages = try GitRunner.run(in: rootURL, ["ls-files", "-u", "--", path])
            var hashes: [Int: String] = [:]
            for line in stages.split(separator: "\n") {
                let columns = line.split(separator: "\t")[0].split(separator: " ")
                guard columns.count == 3, let stage = Int(columns[2]) else { continue }
                hashes[stage] = String(columns[1])
            }
            if hashes[2] == nil || hashes[3] == nil {
                // 一边删了：删除赢。
                try GitRunner.run(in: rootURL, ["rm", "-f", "--", path])
            } else if hashes[2]! > hashes[3]! {
                try GitRunner.run(in: rootURL, ["checkout", "--ours", "--", path])
                try GitRunner.run(in: rootURL, ["add", "--", path])
            } else {
                try GitRunner.run(in: rootURL, ["checkout", "--theirs", "--", path])
                try GitRunner.run(in: rootURL, ["add", "--", path])
            }
        }
        try GitRunner.run(in: rootURL, ["commit", "--no-edit"])
    }

    // MARK: - 远程（即 GitHub 等裸仓；推送 + 同步）

    var remoteURL: URL? {
        get {
            guard let raw = userDefaults.string(forKey: Self.remoteURLKey),
                  let url = URL(string: raw) else { return nil }
            return url
        }
        set {
            if let url = newValue {
                userDefaults.set(url.absoluteString, forKey: Self.remoteURLKey)
            } else {
                userDefaults.removeObject(forKey: Self.remoteURLKey)
            }
        }
    }

    var isPushingEnabled: Bool { remoteURL != nil }

    /// 把本地快照推送到远端。**只推送**：这副本不准备当同步源，也绝不回拉。
    /// 远端地址是唯一的「数据离开这台机器」通道，调用前必须让用户确认。
    func push() throws {
        try onQueue {
            guard let remote = remoteURL else {
                throw GitServiceError.noRemoteConfigured
            }
            guard isRepository else { throw GitServiceError.invalidSnapshot }
            _ = try? GitRunner.run(in: rootURL, ["remote", "remove", "origin"])
            try GitRunner.run(in: rootURL, ["remote", "add", "origin", remote.absoluteString])
            // 若本地已有 commit 就直接 push，否则先建一个空的初始 commit。
            let hasCommit = (try? GitRunner.run(in: rootURL, ["rev-parse", "HEAD"])) != nil
            if !hasCommit {
                try GitRunner.run(in: rootURL, ["commit", "--allow-empty", "-m", tr("snapshot_note_initial")])
            }
            try GitRunner.run(
                in: rootURL,
                ["push", "-u", "origin", "HEAD"],
                environment: authEnvironment(for: remote)
            )
            lastPushDate = Date()
        }
    }

    var lastPushDate: Date? {
        get {
            let key = Self.lastPushDateKey
            guard userDefaults.object(forKey: key) != nil else { return nil }
            return userDefaults.object(forKey: key) as? Date
        }
        set {
            if let newValue {
                userDefaults.set(newValue, forKey: Self.lastPushDateKey)
            } else {
                userDefaults.removeObject(forKey: Self.lastPushDateKey)
            }
        }
    }

    // MARK: - 私有

    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        try queue.sync(execute: work)
    }

    private func commitDate(of id: String) throws -> Date {
        let raw = try GitRunner.run(in: rootURL, ["show", "-s", "--format=%at", id])
        return Date(timeIntervalSince1970: TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    static func parseHistory(_ output: String) -> [LightAnchorSnapshot] {
        // 输出以 NUL 分隔（见 format 字符串），subject 可含换行但不含 NUL，
        // 所以字段切分安全。最后一段之后还有一个结尾 NUL，会被拆出空串，滤掉。
        output
            .replacingOccurrences(of: "\u{0000}", with: "\u{0000}")
            .split(separator: "\u{0000}", omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record.split(
                    separator: "\u{001f}", maxSplits: 2, omittingEmptySubsequences: false
                )
                guard fields.count == 3 else { return nil }
                return LightAnchorSnapshot(
                    id: String(fields[0]),
                    date: Date(timeIntervalSince1970: TimeInterval(String(fields[1])) ?? 0),
                    subject: String(fields[2])
                )
            }
    }

    static let remoteURLKey = "lightanchor.git.remoteURL"
    static let lastPushDateKey = "lightanchor.git.lastPushDate"
    static let lastSyncDateKey = "lightanchor.git.lastSyncDate"
    static let lastSyncErrorKey = "lightanchor.git.lastSyncError"
}

enum GitServiceError: LocalizedError {
    case invalidSnapshot
    case noRemoteConfigured

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            tr("snapshot_does_not_exist")
        case .noRemoteConfigured:
            tr("no_remote_configured")
        }
    }
}
