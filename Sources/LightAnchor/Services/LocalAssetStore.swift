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

    func removeIfPresent(at url: URL?) {
        guard let url else { return }
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
