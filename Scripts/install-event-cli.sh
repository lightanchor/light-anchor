#!/bin/zsh
# 构建 LightAnchorEvent 并安装为 lightanchor-event，供 shell 插件和
# Claude Code hook 直接调用。用法：Scripts/install-event-cli.sh [目标目录]
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

swift build -c release --product LightAnchorEvent
BIN_DIR=$(swift build -c release --product LightAnchorEvent --show-bin-path)

DEST=${1:-$HOME/.local/bin}
mkdir -p "$DEST"
install -m 755 "$BIN_DIR/LightAnchorEvent" "$DEST/lightanchor-event"
echo "已安装 $DEST/lightanchor-event"

case ":$PATH:" in
    *":$DEST:"*) ;;
    *)
        echo "提示：$DEST 不在 PATH 里。可在 ~/.zshrc 加："
        echo "  export PATH=\"$DEST:\$PATH\""
        echo "或设置 LIGHTANCHOR_EVENT_BIN=$DEST/lightanchor-event"
        ;;
esac
