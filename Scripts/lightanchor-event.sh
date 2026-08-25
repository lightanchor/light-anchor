#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

swift build -c release --product LightAnchorEvent
BIN_DIR=$(swift build -c release --product LightAnchorEvent --show-bin-path)
exec "$BIN_DIR/LightAnchorEvent" "$@"
