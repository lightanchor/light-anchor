# 轻锚工作台接入

外部工具只需要发布最小事件——开始时 `started`、结束时 `completed` / `failed` / `cancelled`，同一 `correlationID` 归并到同一项等待。不需要把源代码、命令输出或完整通信内容交给轻锚。

**接入是手动的。** 先跑一次 `Scripts/install-event-cli.sh`，把事件发布器装进 `~/.local/bin/lightanchor-event`；再按各目录的 README 把对应脚本挂进那个工具自己的配置。轻锚不代你改写 `~/.claude/settings.json`、`~/.codex/config.toml` 或 `~/.zshrc`——**挂上就是接入，删掉就是断开，应用里没有第二个开关。**

## 五个接入

| 目录 | 工具 | 行为 |
| --- | --- | --- |
| [`claude-code/`](./claude-code/README.md) | Claude Code | hook 让每个会话回合自动成为一项等待，回合结束或需要确认时变「可以返回」，失败同样是可返回的结果 |
| [`codex/`](./codex/README.md) | Codex CLI | notify 报回合结束，同一线程复用同一项等待；检测到已有 notify 配置时拒绝覆盖、提示手动合并 |
| [`pi/`](./pi/) | PI | TypeScript 扩展，回合落定进等待 |
| [`dsh/`](./dsh/) | dsh | CommonJS 插件，回合落定进等待 |
| [`shell/`](./shell/README.md) | zsh | 跑超过阈值的终端命令自动可等，结束按退出码报告完成或失败 |

事件发布器 `LightAnchorEvent` 随 App 包分发并单独签名；开发者也可以用 `Scripts/install-event-cli.sh` 把它装进 `~/.local/bin`（命名为 `lightanchor-event`）。

## 其他工具

任何工具都可以直接走统一事件入口，不需要专用脚本：

```text
Scripts/lightanchor-event.sh publish \
  --source terminal \
  --kind completed \
  --correlation build-42 \
  --title "项目构建"
```

或打开 `lightanchor://event?source=terminal&kind=completed&correlation=build-42`。事件里只放标题、来源、correlation 和一句结果说明。
