import CryptoKit
import Foundation

#if os(macOS)
import Security
#endif

struct ReleaseArtifact: Codable, Equatable, Sendable {
    let filename: String
    let url: String
    let sha256: String
    let size: Int
}

struct ReleaseManifestSignature: Codable, Equatable, Sendable {
    let algorithm: String
    let filename: String
}

struct ReleaseManifest: Codable, Equatable, Sendable {
    let manifestVersion: Int
    let product: String
    let version: String
    let build: String
    let eventSchemaVersion: Int
    let syncEnvelopeVersion: Int
    let binarySHA256: String
    let artifact: ReleaseArtifact
    let minimumOS: String
    let channel: String
    let signed: Bool
    let signature: ReleaseManifestSignature?
}

enum ReleaseUpdateError: LocalizedError {
    case invalidManifest
    case invalidEndpoint
    case signatureRequired
    case invalidSignature
    case unsupportedSignatureAlgorithm(String)
    case httpError(Int)
    case transportUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidManifest: tr("invalid_update_manifest")
        case .invalidEndpoint: tr("the_update_url_must_use_https")
        case .signatureRequired: tr("the_update_manifest_has_no_verifiable")
        case .invalidSignature: tr("update_manifest_signature_verification_failed")
        case .unsupportedSignatureAlgorithm(let algorithm):
            String(format: tr("unsupported_manifest_signature_algorithm"), algorithm)
        case .httpError(let statusCode): String(format: tr("update_service_returned_http"), statusCode)
        case .transportUnavailable: tr("the_update_service_is_unreachable")
        }
    }
}

struct ReleaseManifestVerifier {
    func verify(
        manifestData: Data,
        signature: Data,
        publicKeyData: Data,
        algorithm: String
    ) throws -> ReleaseManifest {
        let manifest = try decode(manifestData)
        guard algorithm.lowercased() == "rsa-sha256" else {
            throw ReleaseUpdateError.unsupportedSignatureAlgorithm(algorithm)
        }

        #if os(macOS)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        guard let publicKey = SecKeyCreateWithData(
            publicKeyData as CFData,
            attributes as CFDictionary,
            nil
        ) else {
            throw ReleaseUpdateError.invalidSignature
        }
        guard SecKeyIsAlgorithmSupported(
            publicKey,
            .verify,
            .rsaSignatureMessagePKCS1v15SHA256
        ) else {
            throw ReleaseUpdateError.invalidSignature
        }
        guard SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            manifestData as CFData,
            signature as CFData,
            nil
        ) else {
            throw ReleaseUpdateError.invalidSignature
        }
        return manifest
        #else
        throw ReleaseUpdateError.invalidSignature
        #endif
    }

    func decode(_ data: Data) throws -> ReleaseManifest {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ReleaseUpdateError.invalidManifest
            }
            let allowedKeys: Set<String> = [
                "manifestVersion", "product", "version", "build", "eventSchemaVersion",
                "syncEnvelopeVersion", "binarySHA256", "artifact", "minimumOS", "channel",
                "signed", "signature"
            ]
            let requiredKeys = allowedKeys.subtracting(["signature"])
            guard Set(object.keys) == requiredKeys || Set(object.keys) == allowedKeys,
                  let artifact = object["artifact"] as? [String: Any],
                  Set(artifact.keys) == Set(["filename", "url", "sha256", "size"])
            else {
                throw ReleaseUpdateError.invalidManifest
            }
            if let rawSignature = object["signature"] {
                if let signature = rawSignature as? [String: Any] {
                    guard Set(signature.keys) == Set(["algorithm", "filename"]) else {
                        throw ReleaseUpdateError.invalidManifest
                    }
                } else if !(rawSignature is NSNull) {
                    throw ReleaseUpdateError.invalidManifest
                }
            }
            let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
            guard manifest.manifestVersion == LightAnchorSchema.releaseManifestVersion,
                  isSafeToken(manifest.product),
                  isSafeVersion(manifest.version),
                  isSafeToken(manifest.build),
                  manifest.eventSchemaVersion > 0,
                  manifest.syncEnvelopeVersion > 0,
                  isSHA256(manifest.binarySHA256),
                  isSHA256(manifest.artifact.sha256),
                  isSafeFilename(manifest.artifact.filename),
                  !manifest.artifact.url.contains("\n"),
                  manifest.artifact.size > 0,
                  isSafeVersion(manifest.minimumOS),
                  ["stable", "beta", "nightly"].contains(manifest.channel),
                  manifest.signed == (manifest.signature != nil)
            else { throw ReleaseUpdateError.invalidManifest }
            if let signature = manifest.signature {
                guard signature.algorithm.lowercased() == "rsa-sha256",
                      isSafeFilename(signature.filename)
                else { throw ReleaseUpdateError.invalidManifest }
            }
            return manifest
        } catch let error as ReleaseUpdateError {
            throw error
        } catch {
            throw ReleaseUpdateError.invalidManifest
        }
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isNumber || ("a"..."f").contains($0.lowercased())
        }
    }

    private func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") &&
            !value.contains("..") &&
            !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    private func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 &&
            !value.contains(where: {
                $0.isWhitespace || $0.isNewline || $0 == "/" || $0 == "\\"
            })
    }

    private func isSafeVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return !parts.isEmpty && parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isNumber)
        }
    }
}

private final class ReleaseHTTPResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<(Data, HTTPURLResponse), Error>?

    func store(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }

    func load() -> Result<(Data, HTTPURLResponse), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }
}

struct ReleaseUpdateClient: Sendable {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = max(timeout, 1)
    }

    func fetchManifest(
        from manifestURL: URL,
        publicKeyData: Data?,
        signatureURL: URL? = nil
    ) throws -> ReleaseManifest {
        guard manifestURL.scheme?.lowercased() == "https",
              manifestURL.host != nil
        else { throw ReleaseUpdateError.invalidEndpoint }

        let manifestData = try get(manifestURL)
        let unsignedManifest = try ReleaseManifestVerifier().decode(manifestData)
        guard unsignedManifest.signed,
              let signatureInfo = unsignedManifest.signature,
              let publicKeyData
        else { throw ReleaseUpdateError.signatureRequired }
        let signaturePath = signatureURL?.absoluteString ?? signatureInfo.filename
        guard !signaturePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReleaseUpdateError.signatureRequired
        }
        let resolvedSignatureURL = try validatedHTTPSURL(
            signaturePath,
            relativeTo: manifestURL
        )
        let signature = try get(resolvedSignatureURL)
        return try ReleaseManifestVerifier().verify(
            manifestData: manifestData,
            signature: signature,
            publicKeyData: publicKeyData,
            algorithm: signatureInfo.algorithm
        )
    }

    func isNewer(
        _ candidate: ReleaseManifest,
        thanVersion currentVersion: String,
        build currentBuild: String
    ) -> Bool {
        let candidateVersion = versionComponents(candidate.version)
        let currentVersionComponents = versionComponents(currentVersion)
        if candidateVersion != currentVersionComponents {
            let width = max(candidateVersion.count, currentVersionComponents.count)
            let paddedCandidate = candidateVersion + Array(repeating: 0, count: width - candidateVersion.count)
            let paddedCurrent = currentVersionComponents
                + Array(repeating: 0, count: width - currentVersionComponents.count)
            if paddedCandidate != paddedCurrent {
                return paddedCandidate.lexicographicallyPrecedes(paddedCurrent) == false
            }
        }
        return candidate.build.compare(currentBuild, options: .numeric) == .orderedDescending
    }

    private func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    private func validatedHTTPSURL(_ path: String, relativeTo baseURL: URL) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { throw ReleaseUpdateError.invalidEndpoint }
        return url
    }

    private func get(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReleaseHTTPResponseBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.store(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                box.store(.failure(ReleaseUpdateError.transportUnavailable))
                return
            }
            box.store(.success((data ?? Data(), response)))
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw ReleaseUpdateError.transportUnavailable
        }
        guard let result = box.load() else { throw ReleaseUpdateError.transportUnavailable }
        do {
            let (data, response) = try result.get()
            guard (200..<300).contains(response.statusCode) else {
                throw ReleaseUpdateError.httpError(response.statusCode)
            }
            return data
        } catch let error as ReleaseUpdateError {
            throw error
        } catch {
            throw ReleaseUpdateError.transportUnavailable
        }
    }
}

struct ReleaseUpdateCheckResult: Equatable, Sendable {
    let manifest: ReleaseManifest
    let isNewer: Bool
    let checkedAt: Date
}

struct ReleaseUpdateChecker: Sendable {
    let client: ReleaseUpdateClient
    let currentVersion: String
    let currentBuild: String

    init(
        client: ReleaseUpdateClient = ReleaseUpdateClient(),
        currentVersion: String? = nil,
        currentBuild: String? = nil,
        bundle: Bundle = .main
    ) {
        self.client = client
        self.currentVersion = currentVersion
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.1.0"
        self.currentBuild = currentBuild
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "0"
    }

    func check(
        manifestURL: URL,
        publicKeyData: Data,
        now: Date = Date()
    ) throws -> ReleaseUpdateCheckResult {
        let manifest = try client.fetchManifest(
            from: manifestURL,
            publicKeyData: publicKeyData
        )
        return ReleaseUpdateCheckResult(
            manifest: manifest,
            isNewer: client.isNewer(
                manifest,
                thanVersion: currentVersion,
                build: currentBuild
            ),
            checkedAt: now
        )
    }
}

struct ReleaseUpdateSchedule: Codable, Equatable, Sendable {
    var enabled: Bool
    var manifestURL: URL?
    var publicKeyURL: URL?
    var lastCheckedAt: Date?
    var interval: TimeInterval

    init(
        enabled: Bool = false,
        manifestURL: URL? = nil,
        publicKeyURL: URL? = nil,
        lastCheckedAt: Date? = nil,
        interval: TimeInterval = 24 * 60 * 60
    ) {
        self.enabled = enabled
        self.manifestURL = manifestURL
        self.publicKeyURL = publicKeyURL
        self.lastCheckedAt = lastCheckedAt
        self.interval = max(interval, 60)
    }

    func shouldCheck(now: Date = Date()) -> Bool {
        guard enabled, manifestURL != nil, publicKeyURL != nil else { return false }
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= interval
    }
}
