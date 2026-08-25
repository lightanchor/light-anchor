#!/bin/zsh
# lightanchor-integration-version: 1
# 轻锚 · Codex CLI notify 钩子
#
# Codex 的 notify 只有一种事件：agent-turn-complete（回合结束），JSON 作为
# 最后一个命令行参数传入。轻锚把它翻译成 completed 事件；同一线程的下一个
# 回合会重开同一项等待并立即就绪，所以等待页始终只有一行。
#
# 隐私边界：只发送线程 ID（做关联）、项目目录名和一句状态说明；
# 不发送 last-assistant-message、输入内容或任何文件内容。
#
# 安装方式见同目录 README：跑一次 Scripts/install-event-cli.sh，再把本脚本
# 的绝对路径写进 ~/.codex/config.toml 顶部的 notify。
# 脚本永远以 0 退出——它绝不能影响 Codex 本身。

set -u
payload=${@[-1]:-}
[[ -n "$payload" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

event_type=$(printf '%s' "$payload" | jq -r '."type" // empty' 2>/dev/null)
[[ "$event_type" == "agent-turn-complete" ]] || exit 0

thread_id=$(printf '%s' "$payload" | jq -r '."thread-id" // empty' 2>/dev/null)
payload_cwd=$(printf '%s' "$payload" | jq -r '."cwd" // empty' 2>/dev/null)
[[ -n "$payload_cwd" ]] || payload_cwd=$PWD

project=${payload_cwd:t}
[[ -n "$project" ]] || project="会话"
if [[ -n "$thread_id" ]]; then
    correlation="codex-${thread_id}"
else
    correlation="codex-${project}"
fi
title="Codex · ${project}"
detail="回合结束，等你回看"

resolve_publisher() {
    if [[ -n "${LIGHTANCHOR_EVENT_BIN:-}" && -x "${LIGHTANCHOR_EVENT_BIN}" ]]; then
        print -r -- "${LIGHTANCHOR_EVENT_BIN}"
        return 0
    fi
    local installed="$HOME/Library/Application Support/LightAnchor/Integrations/lightanchor-event"
    if [[ -x "$installed" ]]; then
        print -r -- "$installed"
        return 0
    fi
    command -v lightanchor-event 2>/dev/null
}

publish_with_cli() {
    local bin
    bin=$(resolve_publisher) || return 1
    [[ -x "$bin" ]] || return 1
    "$bin" publish \
        --source agent \
        --kind completed \
        --correlation "$correlation" \
        --title "$title" \
        --detail "$detail" \
        --cwd "$payload_cwd" >/dev/null 2>&1
}

publish_with_deep_link() {
    # 指定了自定义收件箱（测试/隔离）时绝不走深链——深链只会写进
    # 正在运行的应用自己的收件箱。
    [[ -z "${LIGHTANCHOR_EVENT_INBOX:-}" ]] || return 1
    pgrep -xq LightAnchor 2>/dev/null || return 1
    local encoded_title encoded_detail encoded_correlation
    encoded_title=$(printf '%s' "$title" | jq -rR '@uri' 2>/dev/null) || return 1
    encoded_detail=$(printf '%s' "$detail" | jq -rR '@uri' 2>/dev/null) || return 1
    encoded_correlation=$(printf '%s' "$correlation" | jq -rR '@uri' 2>/dev/null) || return 1
    open -g "lightanchor://event?source=agent&kind=completed&correlation=${encoded_correlation}&title=${encoded_title}&detail=${encoded_detail}" \
        >/dev/null 2>&1
}

publish_with_cli || publish_with_deep_link || true
exit 0
