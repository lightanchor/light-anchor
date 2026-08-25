import Foundation

enum LocalDataArchiveError: LocalizedError {
    case invalidDestination
    case archiveFailed(String)
    case archiveStructureInvalid
    case symbolicLinkNotAllowed(String)
    case unsupportedFile(String)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            tr("invalid_backup_location")
        case .archiveFailed(let message):
            message.isEmpty ? tr("couldn_t_create_a_local_backup") : message
        case .archiveStructureInvalid:
            tr("unrecognized_backup_structure")
        case .symbolicLinkNotAllowed(let path):
            String(format: tr("backup_contains_unsupported_link"), path)
        case .unsupportedFile(let path):
            String(format: tr("backup_contains_unsupported_file"), path)
        case .restoreFailed(let message):
            message.isEmpty ? tr("couldn_t_restore_the_local_backup") : message
        }
    }
}

enum LocalDataArchivePhase: Sendable {
    case collecting
    case compressing
    case extracting
    case verifying
    case installing

    var title: String {
        switch self {
        case .collecting: tr("arranging_files")
        case .compressing: tr("compressing_backup")
        case .extracting: tr("unpacking_backup")
        case .verifying: tr("checking_backup_contents")
        case .installing: tr("writing_local_data")
        }
    }
}

/// 备份里的偏好快照。
///
/// 事件日志和附件在磁盘上，偏好在 UserDefaults 里——只打包目录的话，备份换机
/// 恢复会丢掉全部回顾正文（那是用户写的内容）、云端配置、快捷键和采集偏好。
/// 键取自 `LocalDataErasure` 的同一份清单：那里已经把「什么算这台机器上的
/// 用户数据」列全了，备份没有理由用第二份名单。
///
/// 存 plist 而不是 JSON：UserDefaults 的值可能是 Data 或数组，plist 原生装得下。
enum LocalPreferencesArchive {
    static let fileName = "preferences.plist"

    static var archivedKeys: [String] {
        LocalDataErasure.erasableUserDefaultsKeys + LocalDataErasure.preservedUserDefaultsKeys
    }

    static func snapshotData(from defaults: UserDefaults) throws -> Data {
        var snapshot: [String: Any] = [:]
        for key in archivedKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            snapshot[key] = value
        }
        return try PropertyListSerialization.data(
            fromPropertyList: snapshot,
            format: .xml,
            options: 0
        )
    }

    /// 写回偏好。只认清单里的键：备份文件是外部输入，不能让它往
    /// UserDefaults 里塞任意键。
    static func restore(from data: Data, into defaults: UserDefaults) throws {
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let snapshot = plist as? [String: Any] else {
            throw LocalDataArchiveError.archiveStructureInvalid
        }
        let allowed = Set(archivedKeys)
        for (key, value) in snapshot where allowed.contains(key) {
            defaults.set(value, forKey: key)
        }
    }
}

struct LocalDataArchiveService: @unchecked Sendable {
    let rootURL: URL
    /// 偏好来源。可注入，测试才不会读写跑测试这台机器上的真实偏好。
    let defaults: UserDefaults

    init(rootURL: URL = LightAnchorStorage.rootURL(), defaults: UserDefaults = .standard) {
        self.rootURL = rootURL.standardizedFileURL
        self.defaults = defaults
    }

    func createArchive(
        at archiveURL: URL,
        onProgress: (@Sendable (LocalDataArchivePhase) -> Void) = { _ in }
    ) throws {
        let fileManager = FileManager.default
        let destination = archiveURL.standardizedFileURL
        guard destination != rootURL,
              !destination.path.hasPrefix(rootURL.path + "/")
        else {
            throw LocalDataArchiveError.invalidDestination
        }

        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("light-anchor-backup-\(UUID().uuidString)", isDirectory: true)
        let stagingRoot = temporaryRoot.appendingPathComponent("LightAnchorData", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        onProgress(.collecting)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: rootURL.path) {
            try copyContents(from: rootURL, to: stagingRoot, relativePath: "")
        }
        // 偏好不在数据目录里，得单独装进备份，否则恢复后回顾正文与配置全丢。
        try LocalPreferencesArchive.snapshotData(from: defaults).write(
            to: stagingRoot.appendingPathComponent(LocalPreferencesArchive.fileName),
            options: .atomic
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Build the archive somewhere disposable first: overwriting the chosen
        // destination up front would destroy an existing backup if ditto fails.
        let stagedArchive = temporaryRoot.appendingPathComponent("LightAnchorData.zip")
        onProgress(.compressing)
        try runDitto([
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            stagingRoot.path,
            stagedArchive.path
        ])
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedArchive)
        } else {
            try fileManager.moveItem(at: stagedArchive, to: destination)
        }
    }

    func restoreArchive(
        from archiveURL: URL,
        onProgress: (@Sendable (LocalDataArchivePhase) -> Void) = { _ in }
    ) throws {
        let fileManager = FileManager.default
        let source = archiveURL.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path), source != rootURL else {
            throw LocalDataArchiveError.invalidDestination
        }

        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("light-anchor-restore-\(UUID().uuidString)", isDirectory: true)
        let extractedRoot = temporaryRoot.appendingPathComponent("extracted", isDirectory: true)
        let restoredRoot = extractedRoot.appendingPathComponent("LightAnchorData", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        onProgress(.extracting)
        try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
        try runDitto(["-x", "-k", source.path, extractedRoot.path])
        guard fileManager.fileExists(atPath: restoredRoot.path) else {
            throw LocalDataArchiveError.archiveStructureInvalid
        }
        onProgress(.verifying)
        try validateContents(at: restoredRoot, relativePath: "")
        // 偏好从包里取出来后就把文件拿掉：它不属于数据目录，装进去只会留个残留。
        let preferencesURL = restoredRoot.appendingPathComponent(LocalPreferencesArchive.fileName)
        let archivedPreferences = try? Data(contentsOf: preferencesURL)
        if archivedPreferences != nil {
            try? fileManager.removeItem(at: preferencesURL)
        }

        onProgress(.installing)
        let parent = rootURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let preservedRoot = parent.appendingPathComponent(
            "\(rootURL.lastPathComponent).pre-restore-\(Self.timestamp())",
            isDirectory: true
        )
        var movedExistingRoot = false
        do {
            if fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.moveItem(at: rootURL, to: preservedRoot)
                movedExistingRoot = true
            }
            try fileManager.copyItem(at: restoredRoot, to: rootURL)
        } catch {
            try? fileManager.removeItem(at: rootURL)
            if movedExistingRoot {
                try? fileManager.moveItem(at: preservedRoot, to: rootURL)
            }
            throw LocalDataArchiveError.restoreFailed(error.localizedDescription)
        }
        // 文件就位后再写偏好：文件恢复失败会整体回滚，那时偏好也不该动。
        // 老备份没有这个文件，跳过就是（那种包里本来也没有偏好）。
        if let archivedPreferences {
            try LocalPreferencesArchive.restore(from: archivedPreferences, into: defaults)
        }
    }

    private func copyContents(
        from source: URL,
        to destination: URL,
        relativePath: String
    ) throws {
        let fileManager = FileManager.default
        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            let name = item.lastPathComponent
            guard name != "launch-marker.json", !name.hasSuffix(".lock") else { continue }
            let relative = relativePath.isEmpty ? name : relativePath + "/" + name
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw LocalDataArchiveError.symbolicLinkNotAllowed(relative)
            }
            let destinationItem = destination.appendingPathComponent(name)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: destinationItem, withIntermediateDirectories: true)
                try copyContents(from: item, to: destinationItem, relativePath: relative)
            } else if values.isDirectory == false {
                try fileManager.copyItem(at: item, to: destinationItem)
            } else {
                throw LocalDataArchiveError.unsupportedFile(relative)
            }
        }
    }

    private func validateContents(at directory: URL, relativePath: String) throws {
        let fileManager = FileManager.default
        for item in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            let name = item.lastPathComponent
            guard name != "launch-marker.json", !name.hasSuffix(".lock") else { continue }
            let relative = relativePath.isEmpty ? name : relativePath + "/" + name
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw LocalDataArchiveError.symbolicLinkNotAllowed(relative)
            }
            if values.isDirectory == true {
                try validateContents(at: item, relativePath: relative)
            } else if values.isDirectory != false {
                throw LocalDataArchiveError.unsupportedFile(relative)
            }
        }
    }

    private func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let message: String
        do {
            try process.run()
            // Drain before waiting: ditto blocks once it fills the pipe buffer,
            // and waiting first would deadlock against it.
            message = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            process.waitUntilExit()
        } catch {
            throw LocalDataArchiveError.archiveFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            throw LocalDataArchiveError.archiveFailed(message)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }
}
