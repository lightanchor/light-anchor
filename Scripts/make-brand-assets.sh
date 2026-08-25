#!/bin/zsh
# 生成品牌资源（应用图标、logo、审阅图）到 Support/Brand/。
#
# 渲染器和应用共用 Design/LightAnchorMark.swift 的几何。它是顶层代码，
# 多文件编译时 Swift 只接受 main.swift 这个文件名，所以先拷进临时目录。
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-brand.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT

cp "$SCRIPT_DIR/make-brand-assets.swift" "$BUILD_DIR/main.swift"
xcrun swiftc -O \
    "$ROOT_DIR/Sources/LightAnchor/Design/LightAnchorMark.swift" \
    "$BUILD_DIR/main.swift" \
    -o "$BUILD_DIR/make-brand-assets"

"$BUILD_DIR/make-brand-assets"
