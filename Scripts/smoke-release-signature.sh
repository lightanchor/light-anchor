#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

for command in openssl jq; do
    command -v "$command" >/dev/null 2>&1 || {
        print -u2 -- "Required command is unavailable: $command"
        exit 1
    }
done

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-release-signature.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT
PRIVATE_KEY="$TEMP_DIR/update-private.pem"
PUBLIC_KEY="$TEMP_DIR/update-public.pem"
# Build into a throwaway dist. Writing to the shared one would leave behind a
# manifest marked signed with a key this script destroys on exit, pointing at a
# placeholder URL, which later release checks would treat as a real artifact.
DIST_DIR="$TEMP_DIR/dist"

openssl genrsa -out "$PRIVATE_KEY" 2048 >/dev/null 2>&1
openssl rsa -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1

LIGHTANCHOR_DIST_DIR="$DIST_DIR" \
LIGHTANCHOR_UPDATE_PRIVATE_KEY="$PRIVATE_KEY" \
LIGHTANCHOR_UPDATE_URL="https://updates.example.invalid/releases" \
    "$SCRIPT_DIR/build-release.sh" >/dev/null

MANIFEST="$DIST_DIR/LightAnchor-release-manifest.json"
LIGHTANCHOR_DIST_DIR="$DIST_DIR" \
LIGHTANCHOR_UPDATE_PUBLIC_KEY="$PUBLIC_KEY" \
    "$SCRIPT_DIR/verify-release.sh" \
    "$DIST_DIR/LightAnchor.app" "$MANIFEST" >/dev/null

SIGNED=$(jq -er '.signed' "$MANIFEST")
SIGNATURE_FILENAME=$(jq -er '.signature.filename' "$MANIFEST")
[[ "$SIGNED" == "true" ]] || {
    print -u2 -- "Release manifest was not marked signed."
    exit 1
}
[[ -f "$DIST_DIR/$SIGNATURE_FILENAME" ]] || {
    print -u2 -- "Release manifest signature file is missing: $SIGNATURE_FILENAME"
    exit 1
}

print -- "Release signature smoke passed: RSA manifest signing and verification."
