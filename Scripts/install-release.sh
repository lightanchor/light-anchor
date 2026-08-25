#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PRODUCT=${LIGHTANCHOR_PRODUCT:-LightAnchor}
SOURCE_APP=${1:-}
DESTINATION_APP=${2:-}

if [[ -z "$SOURCE_APP" || -z "$DESTINATION_APP" ]]; then
    printf '%s\n' "Usage: Scripts/install-release.sh /path/to/Signed.app /Applications/LightAnchor.app" >&2
    exit 2
fi
if [[ ! -d "$SOURCE_APP" || "${SOURCE_APP:t}" != *.app ]]; then
    printf '%s\n' "Source must be an .app bundle: $SOURCE_APP" >&2
    exit 1
fi
if [[ ! "$DESTINATION_APP" = /* || "$DESTINATION_APP" == "/" || "${DESTINATION_APP:t}" != *.app ]]; then
    printf '%s\n' "Destination must be an absolute .app path: $DESTINATION_APP" >&2
    exit 1
fi
if [[ -L "$SOURCE_APP" || -L "$DESTINATION_APP" ]]; then
    printf '%s\n' "Symlinked app bundles are refused." >&2
    exit 1
fi

SOURCE_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$SOURCE_APP/Contents/Info.plist")
if [[ "$SOURCE_BUNDLE_ID" != "com.lightanchor.app" ]]; then
    printf '%s\n' "Unexpected bundle identifier: $SOURCE_BUNDLE_ID" >&2
    exit 1
fi

if ! codesign --verify --deep --strict --verbose "$SOURCE_APP"; then
    printf '%s\n' "Refusing to install an unsigned or invalid app bundle." >&2
    exit 1
fi
# `codesign --verify` only proves the signature is internally consistent, so an
# ad-hoc signature passes it. Require a real identity unless a test opts out.
SIGNATURE_INFO=$(codesign -dvv "$SOURCE_APP" 2>&1)
if [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]]; then
    if [[ ${LIGHTANCHOR_ALLOW_ADHOC_SIGNATURE:-0} != "1" ]]; then
        printf '%s\n' \
            "Refusing to install an ad-hoc signed app." \
            "Set LIGHTANCHOR_ALLOW_ADHOC_SIGNATURE=1 only for local smoke tests." >&2
        exit 1
    fi
    printf '%s\n' "Warning: installing an ad-hoc signed app for local testing."
fi
if [[ ${LIGHTANCHOR_REQUIRE_NOTARIZATION:-0} == "1" ]]; then
    spctl --assess --type execute --context context:primary-signature --verbose "$SOURCE_APP"
fi

DESTINATION_PARENT=${DESTINATION_APP:h}
if [[ ! -d "$DESTINATION_PARENT" ]]; then
    printf '%s\n' "Destination directory does not exist: $DESTINATION_PARENT" >&2
    exit 1
fi
DESTINATION_PARENT_REAL=$(cd "$DESTINATION_PARENT" && pwd -P)
DESTINATION_PATH="$DESTINATION_PARENT_REAL/${DESTINATION_APP:t}"
STAGING_DIRECTORY=$(mktemp -d "$DESTINATION_PARENT_REAL/.${PRODUCT}.staging.XXXXXX")
BACKUP_PATH="$DESTINATION_PARENT_REAL/.${PRODUCT}.previous.$(date +%Y%m%d%H%M%S).$$.app"

cleanup() {
    if [[ -n ${STAGING_DIRECTORY:-} && -d "$STAGING_DIRECTORY" ]]; then
        rm -rf "$STAGING_DIRECTORY"
    fi
}
trap cleanup EXIT

/usr/bin/ditto "$SOURCE_APP" "$STAGING_DIRECTORY/${DESTINATION_APP:t}"
codesign --verify --deep --strict --verbose "$STAGING_DIRECTORY/${DESTINATION_APP:t}"

if [[ -e "$DESTINATION_PATH" ]]; then
    if [[ -L "$DESTINATION_PATH" ]]; then
        printf '%s\n' "Destination app is a symlink; refusing to replace it." >&2
        exit 1
    fi
    mv "$DESTINATION_PATH" "$BACKUP_PATH"
fi

if ! mv "$STAGING_DIRECTORY/${DESTINATION_APP:t}" "$DESTINATION_PATH"; then
    if [[ -e "$BACKUP_PATH" ]]; then
        mv "$BACKUP_PATH" "$DESTINATION_PATH"
    fi
    printf '%s\n' "Install failed; previous app was restored when possible." >&2
    exit 1
fi

# Keep only the backup this install created. Older ones are full copies of every
# superseded version, including any that were replaced for being vulnerable.
for stale_backup in "$DESTINATION_PARENT_REAL"/.${PRODUCT}.previous.*.app(N); do
    [[ "$stale_backup" == "$BACKUP_PATH" ]] && continue
    rm -rf "$stale_backup"
done

printf '%s\n' "Installed signed $PRODUCT at $DESTINATION_PATH"
if [[ -e "$BACKUP_PATH" ]]; then
    printf '%s\n' "Previous app retained at $BACKUP_PATH"
fi
