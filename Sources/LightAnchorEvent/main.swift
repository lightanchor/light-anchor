import Foundation
import LightAnchorEventCore

@main
private struct LightAnchorEventCLI {
    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty, arguments.removeFirst() == "publish" else {
            printUsage()
            return
        }

        if arguments.contains("--help") {
            printUsage()
            return
        }

        let options = try parse(arguments)
        let event = LightAnchorEventRecord(
            id: UUID(),
            source: options.source,
            kind: options.kind,
            correlationID: options.correlationID,
            title: options.title,
            detail: options.detail,
            payload: options.payload,
            occurredAt: options.occurredAt,
            processIdentifier: options.processIdentifier,
            workingDirectory: options.workingDirectory
        )
        guard !event.correlationID.isEmpty else {
            throw CLIError.invalid("--correlation 不能为空")
        }
        try LightAnchorEventLog(fileURL: options.inboxURL).append(event)
        print(event.id.uuidString)
    }

    private struct Options {
        var source: LightAnchorEventSource = .custom
        var kind: LightAnchorEventKind = .completed
        var correlationID = ""
        var title = ""
        var detail = ""
        var payload: [String: String] = [:]
        var occurredAt = Date()
        var processIdentifier: Int32?
        var workingDirectory: URL?
        var inboxURL: URL?
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else {
                throw CLIError.invalid("缺少 \(flag) 的值")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--source":
                guard let source = LightAnchorEventSource(rawValue: value) else {
                    throw CLIError.invalid("未知 source：\(value)")
                }
                options.source = source
            case "--kind":
                guard let kind = LightAnchorEventKind(rawValue: value) else {
                    throw CLIError.invalid("未知 kind：\(value)")
                }
                options.kind = kind
            case "--correlation": options.correlationID = value
            case "--title": options.title = value
            case "--detail": options.detail = value
            case "--cwd": options.workingDirectory = URL(fileURLWithPath: value)
            case "--pid":
                guard let pid = Int32(value) else { throw CLIError.invalid("--pid 必须是整数") }
                options.processIdentifier = pid
            case "--occurred-at":
                guard let date = ISO8601DateFormatter().date(from: value) else {
                    throw CLIError.invalid("--occurred-at 必须是 ISO 8601 时间")
                }
                options.occurredAt = date
            case "--payload":
                let pair = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, !pair[0].isEmpty else {
                    throw CLIError.invalid("--payload 使用 key=value")
                }
                options.payload[pair[0]] = pair[1]
            case "--inbox": options.inboxURL = URL(fileURLWithPath: value)
            default: throw CLIError.invalid("未知参数：\(flag)")
            }
            index += 2
        }
        return options
    }

    private static func printUsage() {
        print("""
        用法：lightanchor-event publish --source terminal --kind completed --correlation <id> [选项]

        选项：
          --title <文本>          事件标题
          --detail <文本>         结果说明
          --payload key=value     附加字段，可重复
          --cwd <路径>            终端工作目录
          --pid <整数>            外部进程 ID
          --occurred-at <时间>    ISO 8601 时间
          --inbox <路径>          覆盖事件日志路径
        """)
    }
}

private enum CLIError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}
