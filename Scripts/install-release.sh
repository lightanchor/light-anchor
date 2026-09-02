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

verify_signature() {
    local app=$1
    if ! codesign --verify --deep --strict --verbose "$app"; then
        printf '%s\n' "Refusing to install an unsigned or invalid app bundle." >&2
        exit 1
    fi
    # `codesign --verify` only proves the signature is internally consistent, so
    # an ad-hoc signature passes it. Pin the identity with a designated
    # requirement instead of scraping `codesign -d` text: with
    # LIGHTANCHOR_TEAM_ID the leaf must carry that Team ID; without it the app
    # must at least be anchored to Apple (which an ad-hoc signature never is).
    local requirement
    if [[ -n ${LIGHTANCHOR_TEAM_ID:-} ]]; then
        if [[ ! "$LIGHTANCHOR_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
            printf '%s\n' "LIGHTANCHOR_TEAM_ID must be a 10-character Apple Team ID." >&2
            exit 1
        fi
        requirement="anchor apple generic and certificate leaf[subject.OU] = \"$LIGHTANCHOR_TEAM_ID\""
    else
        requirement="anchor apple generic"
    fi
    if ! codesign --verify --deep --strict -R="$requirement" "$app" 2>/dev/null; then
        if [[ ${LIGHTANCHOR_ALLOW_ADHOC_SIGNATURE:-0} != "1" ]]; then
            printf '%s\n' \
                "Refusing to install: the app signature does not satisfy \"$requirement\"." \
                "Set LIGHTANCHOR_TEAM_ID to pin the expected Developer ID team." \
                "Set LIGHTANCHOR_ALLOW_ADHOC_SIGNATURE=1 only for local smoke tests." >&2
            exit 1
        fi
        printf '%s\n' "Warning: installing an app that fails the identity requirement (local testing only)."
    fi
    # Notarization is mandatory by default; smoke tests with throwaway
    # signatures must opt out explicitly with LIGHTANCHOR_REQUIRE_NOTARIZATION=0.
    if [[ ${LIGHTANCHOR_REQUIRE_NOTARIZATION:-1} != "0" ]]; then
        # Gatekeeper acceptance alone is not enough: on a machine where Gatekeeper
        # is disabled `spctl` accepts anything ("override=security disabled"), so
        # also demand that the assessment attributes the app to a notarization
        # ticket rather than to a local override.
        local assessment
        if ! assessment=$(spctl --assess --type execute --context context:primary-signature --verbose=2 "$app" 2>&1); then
            printf '%s\n' "$assessment" \
                "Refusing to install: Gatekeeper did not accept the app (not notarized?)." \
                "Set LIGHTANCHOR_REQUIRE_NOTARIZATION=0 only for local smoke tests." >&2
            exit 1
        fi
        if [[ "$assessment" != *"source=Notarized Developer ID"* ]]; then
            printf '%s\n' "$assessment" \
                "Refusing to install: the app is not attributed to a notarization ticket." \
                "If Gatekeeper is disabled on this Mac the ticket cannot be verified here." \
                "Set LIGHTANCHOR_REQUIRE_NOTARIZATION=0 only for local smoke tests." >&2
            exit 1
        fi
    else
        printf '%s\n' "Warning: notarization check skipped (LIGHTANCHOR_REQUIRE_NOTARIZATION=0)."
    fi
}

verify_signature "$SOURCE_APP"

DESTINATION_PARENT=${DESTINATION_APP:h}
if [[ ! -d "$DESTINATION_PARENT" ]]; then
    printf '%s\n' "Destination directory does not exist: $DESTINATION_PARENT" >&2
    exit 1
fi
DESTINATION_PARENT_REAL=$(cd "$DESTINATION_PARENT" && pwd -P)
DESTINATION_PATH="$DESTINATION_PARENT_REAL/${DESTINATION_APP:t}"
STAGING_DIRECTORY=$(mktemp -d "$DESTINATION_PARENT_REAL/.${PRODUCT}.staging.XXXXXX")
# The backup slot is an unpredictable mktemp directory owned by us, so nobody can
# pre-create the path and have the old app land somewhere they control.
BACKUP_SLOT=$(mktemp -d "$DESTINATION_PARENT_REAL/.${PRODUCT}.previous.XXXXXX")
BACKUP_PATH="$BACKUP_SLOT/${DESTINATION_APP:t}"
BACKUP_USED=0

cleanup() {
    if [[ -n ${STAGING_DIRECTORY:-} && -d "$STAGING_DIRECTORY" ]]; then
        rm -rf "$STAGING_DIRECTORY"
    fi
    if (( ! BACKUP_USED )) && [[ -n ${BACKUP_SLOT:-} && -d "$BACKUP_SLOT" ]]; then
        rmdir "$BACKUP_SLOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

/usr/bin/ditto "$SOURCE_APP" "$STAGING_DIRECTORY/${DESTINATION_APP:t}"
# Re-run the full gate on the staged copy so a swap between check and copy is caught.
verify_signature "$STAGING_DIRECTORY/${DESTINATION_APP:t}"

if [[ -e "$DESTINATION_PATH" ]]; then
    if [[ -L "$DESTINATION_PATH" ]]; then
        printf '%s\n' "Destination app is a symlink; refusing to replace it." >&2
        exit 1
    fi
    if [[ -e "$BACKUP_PATH" ]]; then
        printf '%s\n' "Backup slot is unexpectedly occupied: $BACKUP_PATH" >&2
        exit 1
    fi
    mv -n "$DESTINATION_PATH" "$BACKUP_PATH"
    if [[ -e "$DESTINATION_PATH" ]]; then
        printf '%s\n' "Could not move the existing app aside: $DESTINATION_PATH" >&2
        exit 1
    fi
    BACKUP_USED=1
fi

if [[ -e "$DESTINATION_PATH" ]]; then
    printf '%s\n' "Destination reappeared before install: $DESTINATION_PATH" >&2
    exit 1
fi
mv -n "$STAGING_DIRECTORY/${DESTINATION_APP:t}" "$DESTINATION_PATH" || true
if [[ ! -e "$DESTINATION_PATH" ]] || [[ -e "$STAGING_DIRECTORY/${DESTINATION_APP:t}" ]]; then
    if (( BACKUP_USED )) && [[ -e "$BACKUP_PATH" && ! -e "$DESTINATION_PATH" ]]; then
        mv -n "$BACKUP_PATH" "$DESTINATION_PATH" && BACKUP_USED=0
    fi
    printf '%s\n' "Install failed; previous app was restored when possible." >&2
    exit 1
fi

# Keep only the backup this install created. Older ones are full copies of every
# superseded version, including any that were replaced for being vulnerable.
for stale_backup in "$DESTINATION_PARENT_REAL"/.${PRODUCT}.previous.*(N/); do
    [[ "$stale_backup" == "$BACKUP_SLOT" ]] && continue
    rm -rf "$stale_backup"
done

printf '%s\n' "Installed signed $PRODUCT at $DESTINATION_PATH"
if [[ -e "$BACKUP_PATH" ]]; then
    printf '%s\n' "Previous app retained at $BACKUP_PATH"
fi
