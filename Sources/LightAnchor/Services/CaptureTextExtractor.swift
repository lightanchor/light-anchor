import Foundation

#if os(macOS)
import Vision
#endif

/// 截图文字提取：本机 Vision OCR（中英），让截图变得可检索。
/// 完全离线，不产生网络流量；识别不出内容时返回 nil。
enum CaptureTextExtractor {
    static let maximumCharacters = 4_000

    static func extractText(from fileURL: URL) async -> String? {
        #if os(macOS)
        await Task.detached(priority: .utility) {
            recognizeText(at: fileURL)
        }.value
        #else
        nil
        #endif
    }

    #if os(macOS)
    private static func recognizeText(at fileURL: URL) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(url: fileURL)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results
        else { return nil }

        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maximumCharacters))
    }
    #endif
}
