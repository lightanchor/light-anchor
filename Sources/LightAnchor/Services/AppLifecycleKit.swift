import Foundation

#if os(macOS)
import AppKit
#endif

private struct AppLaunchMarker: Codable {
    let schemaVersion: Int
    let processIdentifier: Int32
    let startedAt: Date
    let appVersion: String
}

final class AppLifecycleTracker: @unchecked Sendable {
    static let shared = AppLifecycleTracker()

    private let lock = NSLock()
    private let markerURL: URL
    private let diagnostics: LocalDiagnostics

    init(
        markerURL: URL? = nil,
        diagnostics: LocalDiagnostics = .shared
    ) {
        self.markerURL = markerURL ?? LightAnchorStorage.launchMarkerURL()
        self.diagnostics = diagnostics
    }

    @discardableResult
    func start(now: Date = Date()) -> Bool {
        let fileManager = FileManager.default
        let hadPreviousMarker = fileManager.fileExists(atPath: markerURL.path)
        let previousMarker = hadPreviousMarker ? readMarker() : nil
        let marker = AppLaunchMarker(
            schemaVersion: 1,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            startedAt: now,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.0"
        )

        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(marker).write(to: markerURL, options: .atomic)
        } catch {
            diagnostics.record(
                operation: "lifecycle.marker-write",
                message: error.localizedDescription
            )
        }

        guard hadPreviousMarker else { return false }
        let detail: String
        if let previousMarker {
            detail = "上一次运行未完成正常退出清理，进程 \(previousMarker.processIdentifier) 于 \(previousMarker.startedAt) 启动。"
        } else {
            detail = "上一次运行留下了无法读取的启动 marker，已视为异常退出。"
        }
        diagnostics.record(operation: "lifecycle.previous-run", message: detail)
        return true
    }

    func markCleanExit() {
        do {
            try FileManager.default.removeItem(at: markerURL)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            diagnostics.record(
                operation: "lifecycle.marker-cleanup",
                message: error.localizedDescription
            )
        }
    }

    private func readMarker() -> AppLaunchMarker? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(AppLaunchMarker.self, from: data)
    }
}

#if os(macOS)
final class LightAnchorApplicationDelegate: NSObject, NSApplicationDelegate {
    private var contextObservation: ContextObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppPermissionSnapshotter.reportURL() != nil {
            NSApp.setActivationPolicy(.prohibited)
        }
        if AppContextSnapshotter.reportURL() != nil {
            NSApp.setActivationPolicy(.prohibited)
            contextObservation = MacContextRecorder().capture(note: "真实 App identity 上下文采集探针")
        }
        if AppContextRestorationSnapshotter.inputURL() != nil {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppPermissionSnapshotter.reportURL() != nil
            || AppContextSnapshotter.reportURL() != nil
            || AppContextRestorationSnapshotter.inputURL() != nil
        else {
            return
        }
        Task { @MainActor in
            if AppPermissionSnapshotter.reportURL() != nil {
                do {
                    _ = try await AppPermissionSnapshotter.writeIfRequested()
                } catch {
                    FileHandle.standardError.write(
                        Data("Unable to write app permission report: \(error.localizedDescription)\n".utf8)
                    )
                }
            }
            if let contextObservation, AppContextSnapshotter.reportURL() != nil {
                do {
                    _ = try AppContextSnapshotter.write(observation: contextObservation)
                } catch {
                    FileHandle.standardError.write(
                        Data("Unable to write app context report: \(error.localizedDescription)\n".utf8)
                    )
                }
            }
            if AppContextRestorationSnapshotter.inputURL() != nil {
                do {
                    guard let source = try AppContextRestorationSnapshotter.loadSource() else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    let report = MacContextRestorer().restore(source.capsule)
                    _ = try AppContextRestorationSnapshotter.write(source: source, report: report)
                } catch {
                    FileHandle.standardError.write(
                        Data("Unable to write app context restoration report: \(error.localizedDescription)\n".utf8)
                    )
                }
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        AppTerminationController.shared.applicationShouldTerminate(sender)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    /// 返回 true 就是让 AppKit 走默认流程，SwiftUI 会自己恢复一个工作区窗口。
    /// 不要在这里再自己开一个：`openWindow(id:)` 对 WindowGroup 是「新开」而不是
    /// 「聚焦」，两条路一起走会得到两个主窗。
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLifecycleTracker.shared.markCleanExit()
    }
}
#endif
