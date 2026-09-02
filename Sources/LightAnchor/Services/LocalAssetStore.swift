import Foundation

enum LocalAssetStoreError: LocalizedError {
    case invalidExtension
    case assetMissing

    var errorDescription: String? {
        switch self {
        case .invalidExtension:
            tr("invalid_attachment_format")
        case .assetMissing:
            tr("the_attachment_to_save_is_missing")
        }
    }
}

final class LocalAssetStore {
    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
    }

    func save(data: Data, fileExtension: String) throws -> URL {
        let normalizedExtension = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalizedExtension.isEmpty,
              !normalizedExtension.contains("/"),
              !normalizedExtension.contains("\\")
        else {
            throw LocalAssetStoreError.invalidExtension
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(normalizedExtension)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    func copyItem(at sourceURL: URL, fileExtension: String? = nil) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LocalAssetStoreError.assetMissing
        }
        let extensionToUse = fileExtension ?? sourceURL.pathExtension
        let data = try Data(contentsOf: sourceURL)
        return try save(data: data, fileExtension: extensionToUse)
    }

    /// 附件路径是从事件日志里原样解码出来的，恢复过一份别人给的备份之后就不可信。
    /// 只有落在 assets 目录内的普通文件才算本店的附件；别处的路径既不读也不删。
    func isManaged(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        let root = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.hasPrefix(root + "/") else { return false }
        // 附件都是平铺的 <uuid>.<ext>，不允许再往下一层。
        guard !candidate.dropFirst(root.count + 1).contains("/") else { return false }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { return false }
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                return false
            }
        }
        return true
    }

    func removeIfPresent(at url: URL?) {
        guard let url, isManaged(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.removeItem(at: directoryURL)
    }

    static func defaultDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        LightAnchorStorage.assetsURL(fileManager: fileManager)
    }
}
