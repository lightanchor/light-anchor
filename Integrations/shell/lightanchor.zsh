# lightanchor-integration-version: 1
# 轻锚 · zsh 长命令自动等待
#
# 安装方式见同目录 README：跑一次 Scripts/install-event-cli.sh，再在
# ~/.zshrc 里 source 本文件。任何跑超过阈值（默认 30 秒）的命令都会
# 自动出现在轻锚的等待里：还在跑时是一项后台等待，结束时按退出码变成
# completed / failed（失败同样进入「可以返回」）。短命令不产生任何事件。
#
# 可调：
#   LIGHTANCHOR_SHELL_WAIT_SECONDS   阈值秒数（默认 30）
#   LIGHTANCHOR_SHELL_WAIT_EXCLUDE   追加排除的命令名（空格分隔）
#   LIGHTANCHOR_SHELL_WAIT_DISABLE   设为任意值则整体停用
#   LIGHTANCHOR_EVENT_BIN            事件发布器路径（默认从 PATH 里找）
#
# 隐私边界：只发送命令行文本（标题）、用时、退出码和工作目录；
# 不发送命令输出。事件写入轻锚本地事件收件箱。

(( ${+LIGHTANCHOR_SHELL_WAIT_DISABLE} )) && return 0
[[ -o interactive ]] || return 0

zmodload zsh/datetime 2>/dev/null || return 0
autoload -Uz add-zsh-hook

typeset -g _lightanchor_threshold=${LIGHTANCHOR_SHELL_WAIT_SECONDS:-30}
# 交互式/长驻命令不是「等待」：编辑器、分页器、远程会话、REPL、监视器、Agent CLI。
typeset -g _lightanchor_exclude="vim nvim vi nano emacs hx less more man ssh mosh et tmux screen zellij top htop btop k9s fzf watch tail journalctl claude codex aider python python3 ipython node irb pry psql mysql sqlite3 ${LIGHTANCHOR_SHELL_WAIT_EXCLUDE:-}"
typeset -g _lightanchor_dir=${TMPDIR:-/tmp}/lightanchor-shell-$$
typeset -g _lightanchor_serial=0
typeset -g _lightanchor_cmd=""
typeset -g _lightanchor_started_at=0
typeset -g _lightanchor_correlation=""

_lightanchor_resolve_publisher() {
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

_lightanchor_publish() {
    local kind=$1 title=$2 detail=$3 correlation=$4 workdir=$5
    local bin
    bin=$(_lightanchor_resolve_publisher)
    if [[ -n $bin && -x $bin ]]; then
        "$bin" publish --source terminal --kind "$kind" \
            --correlation "$correlation" --title "$title" --detail "$detail" \
            --cwd "$workdir" >/dev/null 2>&1 &!
        return 0
    fi
    # 指定了自定义收件箱（测试/隔离）时绝不走深链——深链只会写进
    # 正在运行的应用自己的收件箱。
    [[ -n "${LIGHTANCHOR_EVENT_INBOX:-}" ]] && return 0
    # 退路：轻锚在运行时走深链；需要 jq 做 URL 编码，缺一样就静默放弃。
    pgrep -xq LightAnchor 2>/dev/null || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local encoded_title encoded_detail encoded_correlation
    encoded_title=$(printf '%s' "$title" | jq -rR '@uri' 2>/dev/null) || return 0
    encoded_detail=$(printf '%s' "$detail" | jq -rR '@uri' 2>/dev/null) || return 0
    encoded_correlation=$(printf '%s' "$correlation" | jq -rR '@uri' 2>/dev/null) || return 0
    open -g "lightanchor://event?source=terminal&kind=${kind}&correlation=${encoded_correlation}&title=${encoded_title}&detail=${encoded_detail}" \
        >/dev/null 2>&1 &!
}

_lightanchor_elapsed_label() {
    local seconds=$1
    if (( seconds >= 60 )); then
        print -r -- "$(( seconds / 60 )) 分 $(( seconds % 60 )) 秒"
    else
        print -r -- "${seconds} 秒"
    fi
}

_lightanchor_first_word() {
    local -a words=(${(z)1})
    local word
    for word in $words; do
        # 跳过 ENV=value 前缀和常见包装器，找到真正的命令名。
        [[ $word == *=* && $word != */* ]] && continue
        case ${word:t} in
            sudo|time|nohup|command|exec|builtin|noglob|nocorrect) continue ;;
        esac
        print -r -- ${word:t}
        return 0
    done
    return 1
}

_lightanchor_preexec() {
    _lightanchor_cmd=""
    local cmd=$1
    local first
    first=$(_lightanchor_first_word "$cmd") || return 0
    [[ " $_lightanchor_exclude " == *" $first "* ]] && return 0

    (( _lightanchor_serial++ ))
    _lightanchor_cmd=$cmd
    _lightanchor_started_at=$EPOCHSECONDS
    _lightanchor_correlation="sh-$$-$_lightanchor_serial"

    mkdir -p "$_lightanchor_dir" 2>/dev/null || return 0
    local marker=$_lightanchor_dir/$_lightanchor_serial.running
    : >| "$marker"
    # 延迟探针：阈值之后命令还在跑，才宣布 started——短命令零事件。
    (
        sleep "$_lightanchor_threshold"
        [[ -e $marker ]] || exit 0
        : >| "$_lightanchor_dir/$_lightanchor_serial.announced"
        _lightanchor_publish started "${cmd[1,120]}" "已运行超过 $_lightanchor_threshold 秒" \
            "$_lightanchor_correlation" "$PWD"
    ) &!
}

_lightanchor_precmd() {
    local exit_status=$?
    [[ -n $_lightanchor_cmd ]] || return 0
    local cmd=$_lightanchor_cmd
    local correlation=$_lightanchor_correlation
    local serial=$_lightanchor_serial
    _lightanchor_cmd=""

    local marker=$_lightanchor_dir/$serial.running
    local announced=$_lightanchor_dir/$serial.announced
    rm -f "$marker" 2>/dev/null
    local elapsed=$(( EPOCHSECONDS - _lightanchor_started_at ))
    if [[ -e $announced ]] || (( elapsed >= _lightanchor_threshold )); then
        rm -f "$announced" 2>/dev/null
        local label
        label=$(_lightanchor_elapsed_label $elapsed)
        if (( exit_status == 0 )); then
            _lightanchor_publish completed "${cmd[1,120]}" "用时 ${label}，退出码 0" \
                "$correlation" "$PWD"
        else
            _lightanchor_publish failed "${cmd[1,120]}" "用时 ${label}，退出码 ${exit_status}" \
                "$correlation" "$PWD"
        fi
    fi
}

_lightanchor_zshexit() {
    rm -rf "$_lightanchor_dir" 2>/dev/null
}

add-zsh-hook preexec _lightanchor_preexec
add-zsh-hook precmd _lightanchor_precmd
add-zsh-hook zshexit _lightanchor_zshexit
