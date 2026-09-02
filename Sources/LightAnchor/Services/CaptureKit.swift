import Foundation

import CoreGraphics

enum CaptureServiceError: LocalizedError {
    case unavailable
    case permissionRequired
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            tr("this_capture_method_isn_t_supported")
        case .permissionRequired:
            tr("screenshots_need_screen_recording_permission")
        case .cancelled:
            tr("capture_cancelled")
        case .failed(let message):
            message
        }
    }
}

struct MacScreenshotCapture {
    func captureSelection() async throws -> Data {
        // 弹窗是 UI，得回主线程发起；而且它只是把人送进系统设置，当场
        // 不会变成「已授权」，所以这一趟截图照样按缺权限处理。
        if !CGPreflightScreenCaptureAccess() {
            _ = await MainActor.run { CGRequestScreenCaptureAccess() }
            guard CGPreflightScreenCaptureAccess() else {
                throw CaptureServiceError.permissionRequired
            }
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("light-anchor-screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")

        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-i", "-t", "png", temporaryURL.path]
                    try process.run()
                    process.waitUntilExit()

                    guard process.terminationStatus == 0 else {
                        continuation.resume(throwing: CaptureServiceError.cancelled)
                        return
                    }
                    guard let data = try? Data(contentsOf: temporaryURL), !data.isEmpty else {
                        continuation.resume(throwing: CaptureServiceError.failed(tr("no_screenshot_was_produced")))
                        return
                    }
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct LinkCaptureParser {
    func parse(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return nil }
        return url
    }
}

struct IncomingCaptureRequest {
    let url: URL
    let title: String?
}

struct IncomingURLCapture {
    func request(from url: URL) -> IncomingCaptureRequest? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            return IncomingCaptureRequest(url: url, title: nil)
        }
        guard scheme == "lightanchor",
              url.host?.lowercased() == "capture",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value
        else { return nil }
        guard let linkURL = LinkCaptureParser().parse(value) else { return nil }
        let title = components.queryItems?.first(where: { $0.name == "title" })?.value
        return IncomingCaptureRequest(url: linkURL, title: title)
    }
}
