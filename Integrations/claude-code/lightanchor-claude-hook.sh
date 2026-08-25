#!/bin/zsh
# lightanchor-integration-version: 1
# 轻锚 · Claude Code hook
#
# 把 Claude Code 会话的回合翻译成轻锚外部事件：
#   UserPromptSubmit -> started    （回合开始，等待重新打开）
#   Stop             -> completed  （回合结束，等待变成「可以返回」）
#   Notification     -> completed  （需要你确认权限/输入，同样值得回来看）
#   SessionEnd       -> cancelled  （会话关闭；已就绪的结果保持就绪）
#
# 隐私边界：只发送事件种类、会话 ID、项目目录名和一句状态说明；
# 不发送 prompt、模型输出或任何文件内容。
#
# 安装方式见同目录 README：跑一次 Scripts/install-event-cli.sh，再把本脚本
# 的绝对路径配进 ~/.claude/settings.json 的四个 hook 事件。
# 脚本永远以 0 退出——它绝不能阻塞会话。

set -u
payload=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

event_name=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[[ -n "$event_name" && -n "$session_id" ]] || exit 0

correlation="claude-${session_id}"
project=${cwd:t}
[[ -n "$project" ]] || project="会话"
title="Claude Code · ${project}"

case "$event_name" in
    UserPromptSubmit)
        kind=started
        detail="正在处理你的请求"
        ;;
    Stop)
        kind=completed
        detail="回合结束，等你回看"
        ;;
    Notification)
        kind=completed
        detail=$(printf '%s' "$payload" | jq -r '.message // "需要你确认"' 2>/dev/null)
        [[ -n "$detail" ]] || detail="需要你确认"
        ;;
    SessionEnd)
        kind=cancelled
        detail="会话已结束"
        ;;
    *)
        exit 0
        ;;
esac

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
    local -a cwd_args=()
    [[ -n "$cwd" ]] && cwd_args=(--cwd "$cwd")
    # UserPromptSubmit 的 stdout 会被注入会话上下文，必须全部吞掉。
    "$bin" publish \
        --source agent \
        --kind "$kind" \
        --correlation "$correlation" \
        --title "$title" \
        --detail "$detail" \
        "${cwd_args[@]}" >/dev/null 2>&1
}

publish_with_deep_link() {
    # 指定了自定义收件箱（测试/隔离）时绝不走深链——深链只会写进
    # 正在运行的应用自己的收件箱。
    [[ -z "${LIGHTANCHOR_EVENT_INBOX:-}" ]] || return 1
    # 退路：轻锚在运行时走深链；不在运行就放弃（不为一条事件启动整个应用）。
    pgrep -xq LightAnchor 2>/dev/null || return 1
    local encoded_title encoded_detail encoded_correlation
    encoded_title=$(printf '%s' "$title" | jq -rR '@uri' 2>/dev/null) || return 1
    encoded_detail=$(printf '%s' "$detail" | jq -rR '@uri' 2>/dev/null) || return 1
    encoded_correlation=$(printf '%s' "$correlation" | jq -rR '@uri' 2>/dev/null) || return 1
    open -g "lightanchor://event?source=agent&kind=${kind}&correlation=${encoded_correlation}&title=${encoded_title}&detail=${encoded_detail}" \
        >/dev/null 2>&1
}

publish_with_cli || publish_with_deep_link || true
exit 0
