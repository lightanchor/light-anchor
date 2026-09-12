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

# 额外的 swift build 参数，按空白拆分。只装 Command Line Tools 的机器缺
# FoundationModels 宏插件，需要：
#   LIGHTANCHOR_SWIFT_BUILD_FLAGS="-Xswiftc -DLIGHTANCHOR_DISABLE_FOUNDATIONMODELS"
# （通常还要 SDKROOT 钉到带宏插件的 SDK；Xcode / CI 上留空即可。）
SWIFT_BUILD_FLAGS=(${=LIGHTANCHOR_SWIFT_BUILD_FLAGS:-})

# jq 是硬依赖：manifest 用 jq 生成（不再 printf 拼 JSON），verify-release.sh 也要它。
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "jq is required to build the release manifest (brew install jq)." >&2
    exit 1
fi

# 快捷指令元数据。App Intents 不是运行期注册的：「快捷指令」只读
# Contents/Resources/Metadata.appintents，Xcode 在 ExtractAppIntentsMetadata 阶段用
# appintentsmetadataprocessor 生成它，swift build 不会。这里照 Xcode 的做法自己跑：
#   1. 编译时让 swiftc 把 AppIntent / AppShortcutsProvider 等协议的实现抽成
#      .swiftconstvalues（-emit-const-values + -const-gather-protocols-file）；
#   2. 拷完二进制、签名之前，把这些文件喂给处理器写出元数据（见下文）。
# 处理器只随 Xcode 分发（Command Line Tools 没有）。缺 Xcode 的机器要么装上并
# xcode-select 过去，要么 LIGHTANCHOR_SKIP_APPINTENTS_METADATA=1 明确接受一个
# 快捷指令看不见的本地包；verify-release.sh 会按同一变量跳过对应检查。
SKIP_APPINTENTS_METADATA=${LIGHTANCHOR_SKIP_APPINTENTS_METADATA:-0}
APPINTENTS_PROCESSOR=""
if [[ "$SKIP_APPINTENTS_METADATA" != "1" ]]; then
    APPINTENTS_PROCESSOR=$(xcrun --find appintentsmetadataprocessor 2>/dev/null) || {
        printf '%s\n' \
            "appintentsmetadataprocessor not found (xcrun --find). It ships with Xcode only, not the Command Line Tools;" \
            "without it the app has no Metadata.appintents and the Shortcuts app cannot see its intents." \
            "Install Xcode and select it (sudo xcode-select -s /Applications/Xcode.app), or set" \
            "LIGHTANCHOR_SKIP_APPINTENTS_METADATA=1 to knowingly build a package without Shortcuts support." >&2
        exit 1
    }
    # 协议名单与 Xcode 的 SwiftBuild（AppIntentsMetadata 规格）一致；文件放在固定路径，
    # 否则路径进了编译参数，每次都会触发全量重编。
    APPINTENTS_PROTOCOLS="$ROOT_DIR/.build/appintents/const-extract-protocols.json"
    mkdir -p "${APPINTENTS_PROTOCOLS:h}"
    jq -n '[
        "AppIntent", "EntityQuery", "AppEntity", "TransientEntity", "AppEnum",
        "AppShortcutProviding", "AppShortcutsProvider", "AnyResolverProviding",
        "AppIntentsPackage", "DynamicOptionsProvider", "_IntentValueRepresentable",
        "_AssistantIntentsProvider", "_GenerativeFunctionExtractable",
        "IntentValueQuery", "Resolver"
    ]' > "$APPINTENTS_PROTOCOLS"
    SWIFT_BUILD_FLAGS+=(
        -Xswiftc -emit-const-values
        -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
        -Xswiftc -Xfrontend -Xswiftc "$APPINTENTS_PROTOCOLS"
    )
fi

# 更新信任锚随构建内置：有更新私钥时先派生公钥放进 Resources，swift build 会把它
# 打进资源 bundle，应用内 ReleaseTrust 只认这把内置公钥。派生出来的 pem 是构建产物，
# 结束时清掉，免得烟测的一次性密钥留在源码树里被下一次开发构建带走。
EMBEDDED_PUBLIC_KEY="$ROOT_DIR/Sources/LightAnchor/Resources/update-public.pem"
EMBEDDED_PUBLIC_KEY_CREATED=0
NOTARY_DIR=""
APPINTENTS_TMP=""
cleanup() {
    if [[ -n "$NOTARY_DIR" && -d "$NOTARY_DIR" ]]; then
        rm -rf "$NOTARY_DIR"
    fi
    if [[ -n "$APPINTENTS_TMP" && -d "$APPINTENTS_TMP" ]]; then
        rm -rf "$APPINTENTS_TMP"
    fi
    if (( EMBEDDED_PUBLIC_KEY_CREATED )); then
        rm -f "$EMBEDDED_PUBLIC_KEY"
    fi
}
trap cleanup EXIT
if [[ -n ${LIGHTANCHOR_UPDATE_PRIVATE_KEY:-} ]]; then
    if [[ ! -f "$LIGHTANCHOR_UPDATE_PRIVATE_KEY" ]]; then
        printf '%s\n' "Update signing key not found: $LIGHTANCHOR_UPDATE_PRIVATE_KEY" >&2
        exit 1
    fi
    DERIVED_PUBLIC_KEY=$(openssl rsa -in "$LIGHTANCHOR_UPDATE_PRIVATE_KEY" -pubout 2>/dev/null) || {
        printf '%s\n' "Could not derive the update public key from LIGHTANCHOR_UPDATE_PRIVATE_KEY." >&2
        exit 1
    }
    if [[ -e "$EMBEDDED_PUBLIC_KEY" ]]; then
        # 源码树里已有一把公钥却和签名私钥不配，说明是别的密钥留下的；宁可停下。
        if [[ "$(cat "$EMBEDDED_PUBLIC_KEY")" != "$DERIVED_PUBLIC_KEY" ]]; then
            printf '%s\n' \
                "Existing $EMBEDDED_PUBLIC_KEY does not match LIGHTANCHOR_UPDATE_PRIVATE_KEY." \
                "Remove the stale file before building a signed release." >&2
            exit 1
        fi
    else
        printf '%s\n' "$DERIVED_PUBLIC_KEY" > "$EMBEDDED_PUBLIC_KEY"
        EMBEDDED_PUBLIC_KEY_CREATED=1
    fi
    printf '%s\n' "Embedding update public key into the app bundle."
elif [[ -e "$EMBEDDED_PUBLIC_KEY" ]]; then
    printf '%s\n' "Note: bundling the existing $EMBEDDED_PUBLIC_KEY as the update trust anchor."
fi

swift build -c release --product "$PRODUCT" $SWIFT_BUILD_FLAGS
BIN_DIR=$(swift build -c release --show-bin-path $SWIFT_BUILD_FLAGS)
BIN="$BIN_DIR/$PRODUCT"
test -x "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
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

# 快捷指令元数据必须在签名之前落进 Resources，否则封条对不上。参数照抄 Xcode 的
# ExtractAppIntentsMetadata 命令行；--compile-time-extraction 让处理器只信
# .swiftconstvalues，二进制只作校验，不再依赖运行期反射元数据。
APPINTENTS_METADATA="$APP/Contents/Resources/Metadata.appintents"
if [[ -n "$APPINTENTS_PROCESSOR" ]]; then
    APPINTENTS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-appintents.XXXXXX")
    SOURCE_LIST="$APPINTENTS_TMP/sources.txt"
    CONST_VALUES_LIST="$APPINTENTS_TMP/const-values.txt"
    find "$ROOT_DIR/Sources/$PRODUCT" -type f -name '*.swift' | sort > "$SOURCE_LIST"
    # .swiftconstvalues 的位置随 SwiftPM 后端不同：原生后端在 <bin>/<模块>.build/ 下，
    # Swift Build 后端在 .build/out/Intermediates.noindex/<模块>.build/Release/ 下。
    # 都按模块目录过滤，只收本模块的抽取结果。
    typeset -a CONST_VALUE_ROOTS=("$BIN_DIR")
    if [[ -d "$BIN_DIR/../../Intermediates.noindex/$PRODUCT.build/Release" ]]; then
        CONST_VALUE_ROOTS+=("$BIN_DIR/../../Intermediates.noindex/$PRODUCT.build/Release")
    fi
    # 排除 -testable- 中间产物：swift test 留下的旧文件也在同一个模块目录下，
    # 处理器会把两份都读进去，其中过期的那份足以让整次导出判错。
    find "${CONST_VALUE_ROOTS[@]}" -type f -name '*.swiftconstvalues' -path "*/$PRODUCT.build/*" \
        ! -path '*testable*' \
        | sort > "$CONST_VALUES_LIST"
    if [[ ! -s "$CONST_VALUES_LIST" ]]; then
        printf '%s\n' \
            "swift build emitted no .swiftconstvalues for $PRODUCT under $BIN_DIR;" \
            "cannot extract App Intents metadata (is -emit-const-values being dropped?)." >&2
        exit 1
    fi
    DEPLOYMENT_TARGET=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
    SWIFTC_PATH=$(xcrun --find swiftc)
    TOOLCHAIN_DIR=${SWIFTC_PATH:h:h:h}
    APPINTENTS_SDKROOT=${SDKROOT:-$(xcrun --show-sdk-path --sdk macosx)}
    XCODE_BUILD_VERSION=$(xcodebuild -version | sed -n 's/^Build version //p')
    if [[ -z "$XCODE_BUILD_VERSION" ]]; then
        printf '%s\n' "Could not read the Xcode build version (xcodebuild -version)." >&2
        exit 1
    fi
    # 每个架构一条 --target-triple，和 Xcode 对 ARCHS 的展开一致。
    typeset -a TARGET_TRIPLES=()
    for arch in $(lipo -archs "$APP/Contents/MacOS/$PRODUCT"); do
        TARGET_TRIPLES+=(--target-triple "$arch-apple-macos$DEPLOYMENT_TARGET")
    done
    "$APPINTENTS_PROCESSOR" \
        --toolchain-dir "$TOOLCHAIN_DIR" \
        --module-name "$PRODUCT" \
        --sdk-root "$APPINTENTS_SDKROOT" \
        --xcode-version "$XCODE_BUILD_VERSION" \
        --platform-family macOS \
        --deployment-target "$DEPLOYMENT_TARGET" \
        "${TARGET_TRIPLES[@]}" \
        --bundle-identifier "$BUNDLE_ID" \
        --output "$APP/Contents/Resources" \
        --binary-file "$APP/Contents/MacOS/$PRODUCT" \
        --source-file-list "$SOURCE_LIST" \
        --swift-const-vals-list "$CONST_VALUES_LIST" \
        --stringsdata-file "$APPINTENTS_TMP/ExtractedAppShortcutsMetadata.stringsdata" \
        --compile-time-extraction \
        --deployment-aware-processing \
        --no-app-shortcuts-localization
    if [[ ! -f "$APPINTENTS_METADATA/extract.actionsdata" ]]; then
        printf '%s\n' "appintentsmetadataprocessor exited 0 but wrote no $APPINTENTS_METADATA/extract.actionsdata." >&2
        exit 1
    fi
    printf '%s\n' "Wrote App Intents metadata: $APPINTENTS_METADATA"
else
    printf '%s\n' "Skipped App Intents metadata (LIGHTANCHOR_SKIP_APPINTENTS_METADATA=1): the Shortcuts app will not see this build's intents."
fi

if [[ -n ${LIGHTANCHOR_SIGNING_IDENTITY:-} ]]; then
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT_DIR/Support/LightAnchor.entitlements" \
        --sign "$LIGHTANCHOR_SIGNING_IDENTITY" "$APP"
else
    # 没有 Developer ID 时退回 ad-hoc：给整个 bundle 打上真实封条。
    # 只靠链接器的 linker-signed 可执行文件没有资源封条，包一旦带上
    # com.apple.quarantine（浏览器/解压工具都会打），Gatekeeper 会直接报
    # "已损坏"。ad-hoc 包每次签名 CDHash 都变，换包后 TCC 权限需要重授。
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
MANIFEST_SCHEMA=$(sed -n 's/.*releaseManifestVersion = \([0-9][0-9]*\).*/\1/p' \
    "$ROOT_DIR/Sources/LightAnchor/Domain/Schema.swift")
# An empty scrape leaves `sed` exiting 0, which would emit a manifest with a
# blank value and then sign the broken JSON.
if [[ ! "$MANIFEST_SCHEMA" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "Could not read release manifest version from Schema.swift." >&2
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
if [[ -n ${LIGHTANCHOR_UPDATE_PRIVATE_KEY:-} ]]; then
    MANIFEST_SIGNED=true
fi
if [[ ! "$ARCHIVE_SIZE" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "Could not read the archive size for $ARCHIVE." >&2
    exit 1
fi
# 所有值都经 --arg/--argjson 传入，由 jq 负责转义；字段名和顺序与
# ReleaseManifestVerifier.decode 的白名单一致。
jq -n \
    --argjson manifestVersion "$MANIFEST_SCHEMA" \
    --arg product "$PRODUCT" \
    --arg version "$VERSION" \
    --arg build "$BUILD_NUMBER" \
    --arg binarySHA256 "$SHA256" \
    --arg artifactFilename "$ARCHIVE_NAME" \
    --arg artifactURL "$ARTIFACT_URL" \
    --arg artifactSHA256 "$ARCHIVE_SHA256" \
    --argjson artifactSize "$ARCHIVE_SIZE" \
    --arg minimumOS "15.0" \
    --arg channel "${LIGHTANCHOR_RELEASE_CHANNEL:-stable}" \
    --argjson signed "$MANIFEST_SIGNED" \
    --arg signatureFilename "$SIGNATURE_FILENAME" \
    '{
        manifestVersion: $manifestVersion,
        product: $product,
        version: $version,
        build: $build,
        binarySHA256: $binarySHA256,
        artifact: {
            filename: $artifactFilename,
            url: $artifactURL,
            sha256: $artifactSHA256,
            size: $artifactSize
        },
        minimumOS: $minimumOS,
        channel: $channel,
        signed: $signed,
        signature: (if $signed then {algorithm: "rsa-sha256", filename: $signatureFilename} else null end)
    }' > "$MANIFEST"
jq empty "$MANIFEST"

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
