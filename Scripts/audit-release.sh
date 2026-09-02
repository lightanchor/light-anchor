#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

"$SCRIPT_DIR/performance-baseline.sh"
"$SCRIPT_DIR/smoke-update-release.sh" --help >/dev/null
"$SCRIPT_DIR/smoke-data-backup.sh"
"$SCRIPT_DIR/smoke-release-signature.sh"
"$SCRIPT_DIR/update-release.sh" --help >/dev/null
"$SCRIPT_DIR/build-release.sh"
"$SCRIPT_DIR/verify-release.sh"

printf '%s\n' "Release audit passed."
