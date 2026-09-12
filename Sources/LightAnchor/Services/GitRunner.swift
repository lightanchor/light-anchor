import Foundation

/// 在数据根目录里跑 git 命令。全部经系统 git（`/usr/bin/git`），进程直接
/// 开在根目录，`-C` 前缀让参数不依赖当前工作目录。
///
/// 隐私相关：git 命令可能访问远端（push）或弹提示。这里统一把 Prompt 关掉，
/// 需要登录时会直接失败而不是挂住等 `git credential` 交互；失败信息原样
/// 带回来，由上层决定怎么呈现。
enum GitRunner {
    @discardableResult
    static func run(
        in directory: URL,
        _ arguments: [String],
        environment extraEnvironment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = ["-C", directory.path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw GitRunnerError.processStartFailed(error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw GitRunnerError.gitFailed(output.count > 0 ? output : "git 退出码 \(process.terminationStatus)")
        }
        return output
    }
}

enum GitRunnerError: LocalizedError {
    case processStartFailed(String)
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .processStartFailed(let message):
            message
        case .gitFailed(let message):
            message
        }
    }
}
