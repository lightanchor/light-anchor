# 轻锚 × Codex CLI

让 Codex 的每个回合自动出现在轻锚的等待里：回合结束（`agent-turn-complete`）
变成宜绿的「可以返回」，同一线程的下一个回合会重开同一项等待——等待页
始终只有一行，不刷屏。


## 安装

跑一次 `Scripts/install-event-cli.sh`，再在 `~/.codex/config.toml` 顶部
（任何 `[table]` 之前——TOML 要求顶层键在前）加：

```toml
notify = ["/绝对路径/Integrations/codex/lightanchor-codex-notify.sh"]
```

新开的 Codex 会话生效。**Codex 只允许一个 `notify`**：已经有自己的
notify 程序时不要直接覆盖，把轻锚脚本加进那个程序的调用链。

## 事件映射

Codex 的 notify 只有一种事件：

| Codex | 轻锚事件 | 等待状态 |
|---|---|---|
| agent-turn-complete | completed | 可以返回：「回合结束，等你回看」；下一回合自动重开再就绪 |

没有回合开始事件，所以 Codex 的等待不会出现「进行中」段——结束即出现。

## 隐私边界

脚本只发送：线程 ID（做关联）、项目目录名和一句状态说明。
payload 里的 `last-assistant-message`（模型输出）和输入内容一概不发送。
脚本永远以 0 退出，不会影响 Codex 本身。
