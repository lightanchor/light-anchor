#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
PRODUCT=${LIGHTANCHOR_PRODUCT:-LightAnchor}
APP=${1:-$ROOT_DIR/dist/$PRODUCT.app}
PROFILE=${LIGHTANCHOR_NOTARY_PROFILE:-}

if [[ ! -d "$APP" ]]; then
    printf '%s\n' "App bundle not found: $APP" >&2
    exit 1
fi
if [[ -z "$PROFILE" ]]; then
    printf '%s\n' "Set LIGHTANCHOR_NOTARY_PROFILE to an xcrun notarytool keychain profile." >&2
    exit 1
fi

# Stapling mutates the app, so any archive and manifest built from it earlier are
# now stale. Refuse rather than leave a manifest whose checksums no longer match
# the artifact it describes; `build-release.sh` notarizes in the right order.
MANIFEST="$ROOT_DIR/dist/$PRODUCT-release-manifest.json"
if [[ -f "$MANIFEST" ]]; then
    printf '%s\n' \
        "A release manifest already exists: $MANIFEST" \
        "Stapling would invalidate its archive checksum." \
        "Run Scripts/build-release.sh with LIGHTANCHOR_NOTARY_PROFILE set instead," \
        "which notarizes before archiving so the manifest matches." >&2
    exit 1
fi

# notarytool accepts only .zip, .pkg and .dmg -- never a bundle directory.
SUBMISSION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-notary.XXXXXX")
trap 'rm -rf "$SUBMISSION_DIR"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION_DIR/submission.zip"

xcrun notarytool submit "$SUBMISSION_DIR/submission.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
printf '%s\n' "Notarized and stapled: $APP"
printf '%s\n' "Re-run Scripts/build-release.sh to produce a matching archive and manifest."
