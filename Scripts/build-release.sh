#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

PRODUCT=${LIGHTANCHOR_PRODUCT:-LightAnchor}
VERSION=${LIGHTANCHOR_VERSION:-0.1.0}
BUILD_NUMBER=${LIGHTANCHOR_BUILD_NUMBER:-1}
DIST_DIR=${LIGHTANCHOR_DIST_DIR:-$ROOT_DIR/dist}
APP="$DIST_DIR/$PRODUCT.app"
ARCHIVE_NAME="$PRODUCT-$VERSION-$BUILD_NUMBER-macos.zip"
ARCHIVE="$DIST_DIR/$ARCHIVE_NAME"

swift build -c release --product "$PRODUCT"
swift build -c release --product LightAnchorEvent
BIN_DIR=$(swift build -c release --show-bin-path)
BIN="$BIN_DIR/$PRODUCT"
EVENT_BIN="$BIN_DIR/LightAnchorEvent"
test -x "$BIN"
test -x "$EVENT_BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
# 事件发布器随应用分发：设置 → 连接 的一键接入会把它复制到
# Application Support，Claude Code hook 和 zsh 插件都调它写事件。
cp "$EVENT_BIN" "$APP/Contents/MacOS/LightAnchorEvent"
cp "$ROOT_DIR/Support/LightAnchor-Info.plist" "$APP/Contents/Info.plist"

# 本地化表随 SPM 资源 bundle 进 App（key 为英文标识符，zh-Hans 是开发语言事实源；
# Bundle.module 会在 Contents/Resources 里找到它）。
RESOURCE_BUNDLE="$BIN_DIR/${PRODUCT}_${PRODUCT}.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    printf '%s\n' "缺少资源 bundle $RESOURCE_BUNDLE（应由 swift build 生成）。" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

# 应用图标。Info.plist 里的 CFBundleIconFile 指向它；缺文件时 Dock 和 Finder
# 会静默回落到通用图标，所以这里硬性要求资源存在（Scripts/make-brand-assets.sh 生成）。
ICON="$ROOT_DIR/Support/Brand/AppIcon.icns"
if [[ ! -f "$ICON" ]]; then
    printf '%s\n' "缺少应用图标 $ICON，请先运行 Scripts/make-brand-assets.sh。" >&2
    exit 1
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

if [[ -n ${LIGHTANCHOR_SIGNING_IDENTITY:-} ]]; then
    # 嵌套可执行文件必须先单独签名，否则外层签名和公证都会拒绝它。
    codesign --force --options runtime --timestamp \
        --sign "$LIGHTANCHOR_SIGNING_IDENTITY" "$APP/Contents/MacOS/LightAnchorEvent"
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT_DIR/Support/LightAnchor.entitlements" \
        --sign "$LIGHTANCHOR_SIGNING_IDENTITY" "$APP"
else
    # 没有 Developer ID 时退回 ad-hoc：给整个 bundle 打上真实封条。
    # 只靠链接器的 linker-signed 可执行文件没有资源封条，包一旦带上
    # com.apple.quarantine（浏览器/解压工具都会打），Gatekeeper 会直接报
    # "已损坏"。ad-hoc 包每次签名 CDHash 都变，换包后 TCC 权限需要重授。
    codesign --force --sign - "$APP/Contents/MacOS/LightAnchorEvent"
    # 权利也要签进去，否则本地包和正式包的能力边界不一样，测出来的问题不算数。
    codesign --force --deep \
        --entitlements "$ROOT_DIR/Support/LightAnchor.entitlements" \
        --sign - "$APP"
    printf '%s\n' "Release app is ad-hoc signed. Set LIGHTANCHOR_SIGNING_IDENTITY for Developer ID signing."
fi

NOTARY_PROFILE=${LIGHTANCHOR_NOTARY_PROFILE:-}
if [[ -n "$NOTARY_PROFILE" ]]; then
    if [[ -z ${LIGHTANCHOR_SIGNING_IDENTITY:-} ]]; then
        printf '%s\n' "Notarization requires LIGHTANCHOR_SIGNING_IDENTITY." >&2
        exit 1
    fi
    # Notarize before archiving. Stapling mutates the app, so an archive made
    # first would ship without the ticket and its checksum would not match the
    # one recorded in the manifest below.
    NOTARY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-notary.XXXXXX")
    trap 'rm -rf "$NOTARY_DIR"' EXIT
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_DIR/submission.zip"
    xcrun notarytool submit "$NOTARY_DIR/submission.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
    printf '%s\n' "Notarized and stapled: $APP"
else
    printf '%s\n' "Release app is not notarized. Set LIGHTANCHOR_NOTARY_PROFILE to notarize before archiving."
fi

rm -f "$ARCHIVE"
pushd "$DIST_DIR" >/dev/null
zip -q -r -X -y "$ARCHIVE" "$PRODUCT.app"
popd >/dev/null

SHA256=$(shasum -a 256 "$APP/Contents/MacOS/$PRODUCT" | awk '{print $1}')
ARCHIVE_SHA256=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
ARCHIVE_SIZE=$(stat -f%z "$ARCHIVE")
EVENT_SCHEMA=$(sed -n 's/.*eventDocumentVersion = \([0-9][0-9]*\).*/\1/p' \
    "$ROOT_DIR/Sources/LightAnchor/Domain/Schema.swift")
SYNC_SCHEMA=$(sed -n 's/.*syncEnvelopeVersion = \([0-9][0-9]*\).*/\1/p' \
    "$ROOT_DIR/Sources/LightAnchor/Domain/Schema.swift")
MANIFEST_SCHEMA=$(sed -n 's/.*releaseManifestVersion = \([0-9][0-9]*\).*/\1/p' \
    "$ROOT_DIR/Sources/LightAnchor/Domain/Schema.swift")
# An empty scrape leaves `sed` exiting 0, which would emit a manifest with a
# blank value and then sign the broken JSON.
if [[ ! "$EVENT_SCHEMA" =~ ^[0-9]+$ ]] ||
   [[ ! "$SYNC_SCHEMA" =~ ^[0-9]+$ ]] ||
   [[ ! "$MANIFEST_SCHEMA" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "Could not read schema versions from Schema.swift." >&2
    exit 1
fi
MANIFEST="$DIST_DIR/$PRODUCT-release-manifest.json"
SIGNATURE_FILENAME="$PRODUCT-release-manifest.json.sig"
SIGNATURE_FILE="$DIST_DIR/$SIGNATURE_FILENAME"
ARTIFACT_URL=${LIGHTANCHOR_UPDATE_URL:-}
if [[ -n "$ARTIFACT_URL" ]]; then
    ARTIFACT_URL="${ARTIFACT_URL%/}/$ARCHIVE_NAME"
fi
MANIFEST_SIGNED=false
SIGNATURE_JSON=null
if [[ -n ${LIGHTANCHOR_UPDATE_PRIVATE_KEY:-} ]]; then
    MANIFEST_SIGNED=true
    SIGNATURE_JSON="{\"algorithm\":\"rsa-sha256\",\"filename\":\"$SIGNATURE_FILENAME\"}"
fi
printf '%s\n' \
    '{' \
    "  \"manifestVersion\": $MANIFEST_SCHEMA," \
    "  \"product\": \"$PRODUCT\"," \
    "  \"version\": \"$VERSION\"," \
    "  \"build\": \"$BUILD_NUMBER\"," \
    "  \"eventSchemaVersion\": $EVENT_SCHEMA," \
    "  \"syncEnvelopeVersion\": $SYNC_SCHEMA," \
    "  \"binarySHA256\": \"$SHA256\"," \
    "  \"artifact\": {\"filename\": \"$ARCHIVE_NAME\", \"url\": \"$ARTIFACT_URL\", \"sha256\": \"$ARCHIVE_SHA256\", \"size\": $ARCHIVE_SIZE}," \
    "  \"minimumOS\": \"15.0\"," \
    "  \"channel\": \"${LIGHTANCHOR_RELEASE_CHANNEL:-stable}\"," \
    "  \"signed\": $MANIFEST_SIGNED," \
    "  \"signature\": $SIGNATURE_JSON" \
    '}' > "$MANIFEST"

if command -v jq >/dev/null 2>&1; then
    jq empty "$MANIFEST"
fi

rm -f "$SIGNATURE_FILE"
if [[ -n ${LIGHTANCHOR_UPDATE_PRIVATE_KEY:-} ]]; then
    openssl dgst -sha256 \
        -sign "$LIGHTANCHOR_UPDATE_PRIVATE_KEY" \
        -out "$SIGNATURE_FILE" "$MANIFEST"
    printf '%s\n' "Signed update manifest: $SIGNATURE_FILE"
else
    printf '%s\n' "Update manifest is unsigned. Set LIGHTANCHOR_UPDATE_PRIVATE_KEY for RSA manifest signing."
fi

printf '%s\n' "Built $APP"
printf '%s\n' "Archive: $ARCHIVE"
printf '%s\n' "Manifest: $MANIFEST"
