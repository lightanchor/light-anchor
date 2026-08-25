# 轻锚 × Claude Code

让每个 Claude Code 会话自动出现在轻锚的等待里：Agent 在干活时是一项后台等待，
回合结束或需要你确认权限时变成宜绿的「可以返回」，菜单栏和系统通知都会看到。
同一会话的下一个回合会重新打开同一项等待，不会刷屏。


## 安装

跑一次 `Scripts/install-event-cli.sh`（或自己设 `LIGHTANCHOR_EVENT_BIN`
指向事件发布器），然后把本目录 `lightanchor-claude-hook.sh` 的绝对路径配进
`~/.claude/settings.json` 的 UserPromptSubmit / Stop / Notification /
SessionEnd 四个事件，重启 Claude Code 会话后生效：

```json
{ "hooks": [{ "type": "command", "command": "/绝对路径/lightanchor-claude-hook.sh" }] }
```

## 事件映射

| Claude Code | 轻锚事件 | 等待状态 |
|---|---|---|
| UserPromptSubmit | started | 等待中（或重新打开） |
| Stop | completed | 可以返回：「回合结束，等你回看」 |
| Notification | completed | 可以返回：带上通知原文（如权限确认） |
| SessionEnd | cancelled | 仍在等待才收场；已就绪的结果保留 |

## 隐私边界

hook 只发送：事件种类、会话 ID（做关联）、项目目录名、一句状态说明和工作目录路径。
prompt 正文、模型输出、文件内容一概不发送。脚本永远以 0 退出，不会阻塞会话；
stdout 全部丢弃（UserPromptSubmit 的 stdout 会进入模型上下文，必须为空）。

## 其他 Agent CLI

任何工具都可以用同一协议接入：开始干活时发 `started`，干完发 `completed`，
出错发 `failed`（同样会变成「可以返回」——失败恰恰最需要回去看）：

```sh
lightanchor-event publish --source agent --kind started \
  --correlation my-agent-42 --title "Codex · demo"
```
