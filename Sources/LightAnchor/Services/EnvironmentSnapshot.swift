import Foundation

/// 把 ContextKit 采集到的现场事实反向生成一份环境配置草稿：
/// 你已经手动打开了需要的一切 → 一次快照变成可复用的环境。
/// 纯映射与去重，不做任何系统调用；采集本身交给 MacContextRecorder。
enum EnvironmentSnapshotBuilder {
    struct Draft: Equatable {
        var name: String
        var actions: [EnvironmentAction]
        var allowedApplicationBundleIdentifiers: Set<String>
    }

    /// 应用 → 打开应用（Bundle ID），文档窗口 → 打开文件，网页窗口 → 打开链接。
    /// 终端工作目录不生成动作：环境负责“把东西打开”，目录恢复交给现场恢复。
    static func draft(from capsule: ContextCapsule, capturedAt: Date = Date()) -> Draft {
        var actions: [EnvironmentAction] = []
        var seen = Set<String>()

        for bundleIdentifier in capsule.applicationBundleIdentifiers {
            let value = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert("app:\(value)").inserted else { continue }
            actions.append(EnvironmentAction(kind: .openApplication, value: value))
        }
        for file in capsule.files where file.isFileURL {
            let path = file.path
            guard !path.isEmpty, seen.insert("file:\(path)").inserted else { continue }
            actions.append(EnvironmentAction(kind: .openFile, value: path))
        }
        for link in capsule.links {
            guard let scheme = link.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }
            let value = link.absoluteString
            guard seen.insert("link:\(value)").inserted else { continue }
            actions.append(EnvironmentAction(kind: .openURL, value: value))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return Draft(
            name: "现场 \(formatter.string(from: capturedAt))",
            actions: actions,
            allowedApplicationBundleIdentifiers: Set(
                capsule.applicationBundleIdentifiers
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
    }

    /// 历史现场 → 环境草稿。只采用当时可恢复的条目；终端目录仍交给
    /// 「重返现场」，不会悄悄变成会执行命令的环境动作。
    static func draft(from snapshot: SceneSnapshot) -> Draft {
        var capsule = ContextCapsule(capturedAt: snapshot.capturedAt)
        for item in snapshot.restorableItems {
            switch item.kind {
            case .application:
                let bundleIdentifier = item.address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !bundleIdentifier.isEmpty else { continue }
                capsule.applicationBundleIdentifiers.append(bundleIdentifier)
                capsule.applications.append(item.title)
            case .file:
                if let url = URL(string: item.address), url.isFileURL {
                    capsule.files.append(url)
                }
            case .link:
                if let url = URL(string: item.address) {
                    capsule.links.append(url)
                }
            case .terminal:
                continue
            }
        }
        return draft(from: capsule, capturedAt: snapshot.capturedAt)
    }
}
