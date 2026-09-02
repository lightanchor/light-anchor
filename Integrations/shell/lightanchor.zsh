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
# 不发送命令输出。命令行文本在发出前会先遮掉常见的密钥写法
# （Bearer 令牌、-p/--password、*TOKEN*=/*SECRET*=/*PASSWORD*=/*API_KEY*=
# 之类的赋值），值替换成 <REDACTED>。事件写入轻锚本地事件收件箱。

(( ${+LIGHTANCHOR_SHELL_WAIT_DISABLE} )) && return 0
[[ -o interactive ]] || return 0

zmodload zsh/datetime 2>/dev/null || return 0
autoload -Uz add-zsh-hook

typeset -g _lightanchor_threshold=${LIGHTANCHOR_SHELL_WAIT_SECONDS:-30}
# 交互式/长驻命令不是「等待」：编辑器、分页器、远程会话、REPL、监视器、Agent CLI。
typeset -g _lightanchor_exclude="vim nvim vi nano emacs hx less more man ssh mosh et tmux screen zellij top htop btop k9s fzf watch tail journalctl claude codex aider python python3 ipython node irb pry psql mysql sqlite3 ${LIGHTANCHOR_SHELL_WAIT_EXCLUDE:-}"
# 每个 shell 一个私有标记目录，用 mktemp 建（不可预测、0700），shell 退出时删掉。
typeset -g _lightanchor_dir=""
typeset -g _lightanchor_serial=0
typeset -g _lightanchor_cmd=""
typeset -g _lightanchor_started_at=0
typeset -g _lightanchor_correlation=""

# 只建一次；mktemp 失败才退回可预测路径，且不用 mkdir -p 去「接管」已存在的目录。
_lightanchor_ensure_dir() {
    [[ -n $_lightanchor_dir && -d $_lightanchor_dir && ! -L $_lightanchor_dir ]] && return 0
    _lightanchor_dir=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-shell.XXXXXX" 2>/dev/null) && return 0
    _lightanchor_dir=${TMPDIR:-/tmp}/lightanchor-shell-$$
    mkdir -m 0700 "$_lightanchor_dir" 2>/dev/null && return 0
    _lightanchor_dir=""
    return 1
}
_lightanchor_ensure_dir || return 0

# 发出去之前把命令行里的密钥遮掉。按 zsh 词法切词（尊重引号），逐词处理：
#   Bearer <token>                      -> Bearer <REDACTED>
#   -p<value>                           -> -p<REDACTED>
#   --password[= ]value（及 --passwd/--token/--secret/--api-key 等）
#   NAME=value（NAME 含 TOKEN/SECRET/PASSWORD/PASSWD/API_KEY/APIKEY/ACCESS_KEY/CREDENTIAL，不分大小写）
# 只处理标题文本，宁可多遮不可漏遮。
typeset -g _lightanchor_redact_next=0
# 处理期间用不含 shell 元字符的占位符，免得 (z) 切词把 <REDACTED> 当成重定向拆开；输出前再换回。
typeset -g _lightanchor_redact_mark="__LIGHTANCHOR_REDACTED__"
# 处理单个词：结果放进 REPLY；若该词是取值在下一个词里的选项，置 _lightanchor_redact_next。
_lightanchor_redact_token() {
    setopt localoptions extendedglob
    local word=$1 lower
    REPLY=$word
    if (( _lightanchor_redact_next )); then
        REPLY=$_lightanchor_redact_mark
        _lightanchor_redact_next=0
        return 0
    fi
    lower=${(L)word}
    case $lower in
        --password|--passwd|--token|--secret|--api-key|--apikey|--access-key|--credential|--credentials)
            _lightanchor_redact_next=1
            return 0
            ;;
        --password=*|--passwd=*|--token=*|--secret=*|--api-key=*|--apikey=*|--access-key=*|--credential=*|--credentials=*)
            REPLY="${word%%=*}=$_lightanchor_redact_mark"
            return 0
            ;;
    esac
    case $word in
        -p?*)
            REPLY="-p$_lightanchor_redact_mark"
            return 0
            ;;
    esac
    if [[ $word == [\"\']#[[:alnum:]_]#(#i)(token|secret|password|passwd|api_key|apikey|access_key|credential)[[:alnum:]_]#=* ]]; then
        REPLY="${word%%=*}=$_lightanchor_redact_mark"
    fi
    return 0
}

_lightanchor_redact() {
    setopt localoptions extendedglob
    local text=$1
    # Bearer 常出现在引号里或用反斜杠转义空格的 header 中，先在整段文本上替换。
    text=${text//(#i)bearer[\\[:space:]]##[^[:space:]\"\']##/Bearer $_lightanchor_redact_mark}
    local -a words=(${(z)text})
    local -a out=() parts=()
    local word part
    _lightanchor_redact_next=0
    for word in "${words[@]}"; do
        if [[ $word == *[[:space:]]* && $word != \"*\" && $word != \'*\' ]]; then
            # 带空白且引号没闭合的残段（如 "quote TOKEN=x）：再按空白拆一层逐个处理，
            # 免得赋值整段漏出去。闭合引号的词保持整体，由单词规则处理。
            parts=()
            for part in ${=word}; do
                _lightanchor_redact_token "$part"
                parts+=("$REPLY")
            done
            out+=("${(j: :)parts}")
            continue
        fi
        _lightanchor_redact_token "$word"
        out+=("$REPLY")
    done
    text="${(j: :)out}"
    print -r -- "${text//$_lightanchor_redact_mark/<REDACTED>}"
}

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

    _lightanchor_ensure_dir || return 0
    local marker=$_lightanchor_dir/$_lightanchor_serial.running
    # 普通 `>`（不是 `>|`）：目录是私有的，标记不该已存在；开了 noclobber 时
    # 已存在就失败，此时放弃本次跟踪而不是覆盖别人的文件。
    : > "$marker" 2>/dev/null || return 0
    local title
    title=$(_lightanchor_redact "$cmd")
    title=${title[1,120]}
    # 延迟探针：阈值之后命令还在跑，才宣布 started——短命令零事件。
    (
        sleep "$_lightanchor_threshold"
        [[ -e $marker ]] || exit 0
        : > "$_lightanchor_dir/$_lightanchor_serial.announced" 2>/dev/null
        _lightanchor_publish started "$title" "已运行超过 $_lightanchor_threshold 秒" \
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
        local label title
        label=$(_lightanchor_elapsed_label $elapsed)
        title=$(_lightanchor_redact "$cmd")
        title=${title[1,120]}
        if (( exit_status == 0 )); then
            _lightanchor_publish completed "$title" "用时 ${label}，退出码 0" \
                "$correlation" "$PWD"
        else
            _lightanchor_publish failed "$title" "用时 ${label}，退出码 ${exit_status}" \
                "$correlation" "$PWD"
        fi
    fi
}

_lightanchor_zshexit() {
    [[ -n $_lightanchor_dir && -d $_lightanchor_dir && ! -L $_lightanchor_dir ]] || return 0
    rm -rf "$_lightanchor_dir" 2>/dev/null
}

add-zsh-hook preexec _lightanchor_preexec
add-zsh-hook precmd _lightanchor_precmd
add-zsh-hook zshexit _lightanchor_zshexit
