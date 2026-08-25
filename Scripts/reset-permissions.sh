#!/bin/zsh
# 清掉系统里轻锚的 TCC 授权记录，让下次启动重新走一遍授权。
#
# 为什么需要它：TCC 把授权钉在应用的代码签名上。ad-hoc 包每次重新签名
# CDHash 都变，旧的那条授权会留在「系统设置 → 隐私与安全性」的列表里、
# 开关看着是开的，但对不上新包——AXIsProcessTrusted() 一直是 false，
# 界面上就表现为「辅助功能明明开着却没用」。重置后重新添加即可。
#
# 用法：Scripts/reset-permissions.sh [bundle-id]
set -euo pipefail

BUNDLE_ID=${1:-com.lightanchor.app}

if pgrep -f "$BUNDLE_ID" >/dev/null 2>&1 || pgrep -x LightAnchor >/dev/null 2>&1; then
    echo "轻锚正在运行，先退出再重置（授权变更要重启进程才干净）。" >&2
    exit 1
fi

# ListenEvent 是全局快捷键用的「输入监控」，一并清掉。
for SERVICE in Accessibility ScreenCapture Microphone SpeechRecognition ListenEvent; do
    if tccutil reset "$SERVICE" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "已重置 $SERVICE"
    else
        echo "跳过 $SERVICE（本机没有这条记录）"
    fi
done

echo
echo "接下来：重新打开轻锚 → 设置 → 权限，逐项重新授权。"
echo "辅助功能和屏幕录制要在系统设置里手动拨开关；屏幕录制拨完还要重开轻锚。"
