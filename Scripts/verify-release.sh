#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
PRODUCT=${LIGHTANCHOR_PRODUCT:-LightAnchor}
DIST_DIR=${LIGHTANCHOR_DIST_DIR:-$ROOT_DIR/dist}
APP=${1:-$DIST_DIR/$PRODUCT.app}
MANIFEST=${2:-$DIST_DIR/$PRODUCT-release-manifest.json}
REQUIRE_SIGNATURE=${LIGHTANCHOR_REQUIRE_SIGNATURE:-0}

if [[ ! -d "$APP" ]]; then
    printf '%s\n' "App bundle not found: $APP" >&2
    exit 1
fi

/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist"
if codesign --verify --deep --strict --verbose "$APP"; then
    printf '%s\n' "Signature verification passed."
else
    if [[ "$REQUIRE_SIGNATURE" == "1" ]]; then
        printf '%s\n' "Signed distribution verification failed." >&2
        exit 1
    fi
    printf '%s\n' "Package is unsigned; continuing with local artifact verification."
fi

BINARY="$APP/Contents/MacOS/$PRODUCT"
if [[ ! -x "$BINARY" ]]; then
    printf '%s\n' "Release binary not found or not executable: $BINARY" >&2
    exit 1
fi
typeset -a BUILD_INPUTS=(
    "$ROOT_DIR/Sources/LightAnchor"
    "$ROOT_DIR/Package.swift"
)
if [[ -f "$ROOT_DIR/Package.resolved" ]]; then
    BUILD_INPUTS+=("$ROOT_DIR/Package.resolved")
fi
STALE_INPUT=$(find "${BUILD_INPUTS[@]}" -type f -newer "$BINARY" -print -quit)
if [[ -n "$STALE_INPUT" ]]; then
    printf '%s\n' "Release binary is older than build input: $STALE_INPUT" >&2
    exit 1
fi
# 快捷指令元数据：没有 Metadata.appintents，App Intents 在发布包里等于不存在。
# 只查文件还不够——处理器可能只抽到一部分，所以按源码里声明的每个 AppIntent 核对。
APPINTENTS_ACTIONS="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [[ "${LIGHTANCHOR_SKIP_APPINTENTS_METADATA:-0}" == "1" ]]; then
    printf '%s\n' "Skipped App Intents metadata check (LIGHTANCHOR_SKIP_APPINTENTS_METADATA=1)."
else
    if [[ ! -f "$APPINTENTS_ACTIONS" ]]; then
        printf '%s\n' "App Intents metadata is missing: $APPINTENTS_ACTIONS" >&2
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' "jq is required to verify the App Intents metadata." >&2
        exit 1
    fi
    jq empty "$APPINTENTS_ACTIONS"
    typeset -a INTENT_TYPES=(${(f)"$(sed -n 's/^struct \([A-Za-z0-9_]*\): AppIntent[ {].*/\1/p' \
        "$ROOT_DIR/Sources/LightAnchor/Services/LightAnchorAppIntents.swift")"})
    if (( ${#INTENT_TYPES} == 0 )); then
        printf '%s\n' "Could not read any AppIntent declarations from LightAnchorAppIntents.swift." >&2
        exit 1
    fi
    for intent in "${INTENT_TYPES[@]}"; do
        if ! jq -e --arg id "$intent" '.actions[$id]' "$APPINTENTS_ACTIONS" >/dev/null; then
            printf '%s\n' "App Intents metadata does not list $intent: $APPINTENTS_ACTIONS" >&2
            exit 1
        fi
    done
    printf '%s\n' "App Intents metadata lists ${#INTENT_TYPES} intents."
fi
if [[ -f "$MANIFEST" ]]; then
    # Parse as JSON only. `plutil` also accepts XML and binary plists, so an
    # attacker-supplied plist would otherwise pass as a release manifest.
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' "jq is required to verify the release manifest." >&2
        exit 1
    fi
    jq empty "$MANIFEST"
    EXPECTED_SHA256=$(jq -er '.binarySHA256' "$MANIFEST")
    ACTUAL_SHA256=$(shasum -a 256 "$BINARY" | awk '{print $1}')
    if [[ "$EXPECTED_SHA256" != "$ACTUAL_SHA256" ]]; then
        printf '%s\n' "Manifest binary checksum does not match the app." >&2
        exit 1
    fi
    ARCHIVE_NAME=$(jq -er '.artifact.filename' "$MANIFEST")
    ARCHIVE="$DIST_DIR/$ARCHIVE_NAME"
    if [[ ! -f "$ARCHIVE" ]]; then
        printf '%s\n' "Manifest archive is missing: $ARCHIVE" >&2
        exit 1
    fi
    EXPECTED_ARCHIVE_SHA256=$(jq -er '.artifact.sha256' "$MANIFEST")
    ACTUAL_ARCHIVE_SHA256=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
    if [[ "$EXPECTED_ARCHIVE_SHA256" != "$ACTUAL_ARCHIVE_SHA256" ]]; then
        printf '%s\n' "Manifest archive checksum does not match the archive." >&2
        exit 1
    fi

    SIGNATURE_FILENAME=$(jq -r '.signature.filename // empty' "$MANIFEST")
    if [[ -n "$SIGNATURE_FILENAME" ]]; then
        SIGNATURE_FILE="$DIST_DIR/$SIGNATURE_FILENAME"
        if [[ -f "$SIGNATURE_FILE" ]]; then
            if [[ -n ${LIGHTANCHOR_UPDATE_PUBLIC_KEY:-} ]]; then
                openssl dgst -sha256 \
                    -verify "$LIGHTANCHOR_UPDATE_PUBLIC_KEY" \
                    -signature "$SIGNATURE_FILE" "$MANIFEST" >/dev/null
                printf '%s\n' "Update manifest signature verification passed."
            elif [[ "$REQUIRE_SIGNATURE" == "1" ]]; then
                printf '%s\n' "Set LIGHTANCHOR_UPDATE_PUBLIC_KEY to verify the update manifest signature." >&2
                exit 1
            else
                printf '%s\n' "Update manifest signature found; public key not configured, skipped cryptographic verification."
            fi
        elif [[ "$REQUIRE_SIGNATURE" == "1" ]]; then
            printf '%s\n' "Required update manifest signature is missing: $SIGNATURE_FILE" >&2
            exit 1
        else
            printf '%s\n' "Update manifest signature is missing; continuing local verification."
        fi
    elif [[ "$REQUIRE_SIGNATURE" == "1" ]]; then
        printf '%s\n' "Required update manifest signature metadata is missing." >&2
        exit 1
    fi
elif [[ "$REQUIRE_SIGNATURE" == "1" ]]; then
    # Without this the checksum, archive and signature checks are all skipped
    # together and the script still reports success.
    printf '%s\n' "Required release manifest is missing: $MANIFEST" >&2
    exit 1
else
    printf '%s\n' "Manifest not found; skipped manifest checksum verification."
fi
printf '%s\n' "Release verification passed: $APP"
