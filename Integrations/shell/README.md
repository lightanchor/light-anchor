# 轻锚 × zsh 长命令自动等待

装好之后，终端里任何跑超过 30 秒的命令都会自动出现在轻锚的等待里——
还在跑时是一项后台等待，结束时按退出码变成「可以返回」（失败也一样，
失败恰恰最需要回去看）。短命令不产生任何事件，交互式命令（编辑器、
ssh、REPL、Agent CLI）被排除。

## 安装

跑一次 `Scripts/install-event-cli.sh`，再在 `~/.zshrc` 里加一行：

```sh
source /绝对路径/Integrations/shell/lightanchor.zsh
```

新开的终端窗口开始生效；删掉这行就是断开。

## 可调项（放在 source 之前）

```sh
export LIGHTANCHOR_SHELL_WAIT_SECONDS=45          # 阈值，默认 30 秒
export LIGHTANCHOR_SHELL_WAIT_EXCLUDE="cargo docker"  # 追加排除的命令名
export LIGHTANCHOR_SHELL_WAIT_DISABLE=1           # 整体停用
```

## 工作方式与隐私

- `preexec` 记下命令与时刻，并放一个延迟探针：阈值之后命令还在跑，
  才发布 `started`——所以短命令完全零事件。
- `precmd` 在命令结束时按退出码发布 `completed` / `failed`，带用时。
- 只发送命令行文本、用时、退出码和工作目录；不发送命令输出。
- 事件由 `lightanchor-event` 写入本地事件收件箱。
