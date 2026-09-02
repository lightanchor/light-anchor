#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
PRODUCT=${LIGHTANCHOR_PRODUCT:-LightAnchor}
DESTINATION_APP=${LIGHTANCHOR_DESTINATION_APP:-/Applications/LightAnchor.app}
MANIFEST_URL=${LIGHTANCHOR_MANIFEST_URL:-}
PUBLIC_KEY=${LIGHTANCHOR_UPDATE_PUBLIC_KEY:-}

usage() {
    cat <<'EOF'
Usage: Scripts/update-release.sh --manifest-url https://host/path/manifest.json --public-key /path/update-public.pem [options]

Options:
  --manifest-url URL  HTTPS release manifest URL (or LIGHTANCHOR_MANIFEST_URL)
  --public-key PATH    RSA public key PEM (or LIGHTANCHOR_UPDATE_PUBLIC_KEY)
  --destination PATH   Absolute destination .app path (default: /Applications/LightAnchor.app)
  --product NAME       Expected product name (default: LightAnchor)
  -h, --help           Show this help

The updater verifies the manifest signature, artifact size and SHA-256, extracts a
single product app, verifies its bundle identifier, main-binary SHA-256 and code
signature, then uses Scripts/install-release.sh for staging installation.
install-release.sh pins the signing identity (LIGHTANCHOR_TEAM_ID) and requires
notarization unless LIGHTANCHOR_REQUIRE_NOTARIZATION=0.
EOF
}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

is_safe_filename() {
    local value=$1
    [[ "$value" != */* && "$value" != *\\* && "$value" != "." && "$value" != ".." \
        && "$value" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]]
}

is_https_url() {
    local value=$1
    [[ "$value" =~ '^https://[^/?#]+(/[^?#]*)?([?][^#]*)?(#.*)?$' ]]
}

manifest_root_url() {
    local value=$1
    local without_query=${value%%\?*}
    without_query=${without_query%%\#*}
    [[ "$without_query" == */* ]] || return 1
    printf '%s\n' "${without_query%/*}"
}

json_value() {
    local key=$1
    jq -er --arg path "$key" \
        'getpath($path | split("."))' \
        "$MANIFEST_FILE"
}

while (( $# > 0 )); do
    case "$1" in
        --manifest-url)
            (( $# >= 2 )) || fail "--manifest-url requires a value."
            MANIFEST_URL=$2
            shift 2
            ;;
        --manifest-url=*)
            MANIFEST_URL=${1#*=}
            shift
            ;;
        --public-key)
            (( $# >= 2 )) || fail "--public-key requires a value."
            PUBLIC_KEY=$2
            shift 2
            ;;
        --public-key=*)
            PUBLIC_KEY=${1#*=}
            shift
            ;;
        --destination)
            (( $# >= 2 )) || fail "--destination requires a value."
            DESTINATION_APP=$2
            shift 2
            ;;
        --destination=*)
            DESTINATION_APP=${1#*=}
            shift
            ;;
        --product)
            (( $# >= 2 )) || fail "--product requires a value."
            PRODUCT=$2
            shift 2
            ;;
        --product=*)
            PRODUCT=${1#*=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$MANIFEST_URL" ]] || fail "Manifest URL is required."
[[ -n "$PUBLIC_KEY" ]] || fail "RSA public key is required."
is_https_url "$MANIFEST_URL" || fail "Manifest URL must use HTTPS and include a host."
[[ "$MANIFEST_URL" != *\?* && "$MANIFEST_URL" != *\#* ]] \
    || fail "Manifest URL must not contain a query or fragment."
[[ -f "$PUBLIC_KEY" ]] || fail "Public key file not found: $PUBLIC_KEY"
[[ "$PRODUCT" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] \
    || fail "Product name contains unsupported characters: $PRODUCT"
[[ "$DESTINATION_APP" = /* && "$DESTINATION_APP" == *.app ]] \
    || fail "Destination must be an absolute .app path: $DESTINATION_APP"

for command in curl jq openssl shasum wc unzip ditto codesign; do
    command -v "$command" >/dev/null 2>&1 \
        || fail "Required command is unavailable: $command"
done

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-update.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
MANIFEST_FILE="$WORK_DIR/manifest.json"
SIGNATURE_FILE="$WORK_DIR/manifest.sig"
ARCHIVE_FILE="$WORK_DIR/artifact.zip"

curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --output "$MANIFEST_FILE" "$MANIFEST_URL"
jq -e . "$MANIFEST_FILE" >/dev/null \
    || fail "Downloaded release manifest is not valid JSON."

MANIFEST_VERSION=$(json_value manifestVersion) \
    || fail "Manifest is missing manifestVersion."
EXPECTED_MANIFEST_VERSION=$(sed -n 's/.*releaseManifestVersion = \([0-9][0-9]*\).*/\1/p' \
    "$ROOT_DIR/Sources/LightAnchor/Domain/Schema.swift")
[[ -n "$EXPECTED_MANIFEST_VERSION" && "$MANIFEST_VERSION" == "$EXPECTED_MANIFEST_VERSION" ]] \
    || fail "Unsupported manifest version: $MANIFEST_VERSION"

MANIFEST_PRODUCT=$(json_value product) || fail "Manifest is missing product."
[[ "$MANIFEST_PRODUCT" == "$PRODUCT" ]] \
    || fail "Manifest product does not match expected product: $MANIFEST_PRODUCT"

SIGNED=$(json_value signed) || fail "Manifest is missing signed metadata."
[[ "$SIGNED" == "true" ]] || fail "Release manifest is not marked as signed."
SIGNATURE_ALGORITHM=$(json_value signature.algorithm) \
    || fail "Manifest is missing signature algorithm."
[[ "${SIGNATURE_ALGORITHM:l}" == "rsa-sha256" ]] \
    || fail "Unsupported manifest signature algorithm: $SIGNATURE_ALGORITHM"
SIGNATURE_FILENAME=$(json_value signature.filename) \
    || fail "Manifest is missing signature filename."
is_safe_filename "$SIGNATURE_FILENAME" \
    || fail "Manifest signature filename is unsafe: $SIGNATURE_FILENAME"

MANIFEST_ROOT=$(manifest_root_url "$MANIFEST_URL") \
    || fail "Cannot determine manifest HTTPS directory."
SIGNATURE_URL="$MANIFEST_ROOT/$SIGNATURE_FILENAME"
is_https_url "$SIGNATURE_URL" || fail "Resolved signature URL is not HTTPS."

curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --output "$SIGNATURE_FILE" "$SIGNATURE_URL"
openssl dgst -sha256 -verify "$PUBLIC_KEY" \
    -signature "$SIGNATURE_FILE" "$MANIFEST_FILE" >/dev/null \
    || fail "Release manifest signature verification failed."

ARTIFACT_FILENAME=$(json_value artifact.filename) \
    || fail "Manifest is missing artifact filename."
is_safe_filename "$ARTIFACT_FILENAME" \
    || fail "Manifest artifact filename is unsafe: $ARTIFACT_FILENAME"
[[ "$ARTIFACT_FILENAME" == *.zip ]] \
    || fail "Release artifact must be a zip archive: $ARTIFACT_FILENAME"
ARTIFACT_URL_FIELD=$(json_value artifact.url 2>/dev/null || true)
if [[ -z "$ARTIFACT_URL_FIELD" ]]; then
    ARTIFACT_URL="$MANIFEST_ROOT/$ARTIFACT_FILENAME"
elif is_https_url "$ARTIFACT_URL_FIELD"; then
    ARTIFACT_URL=$ARTIFACT_URL_FIELD
elif is_safe_filename "$ARTIFACT_URL_FIELD"; then
    ARTIFACT_URL="$MANIFEST_ROOT/$ARTIFACT_URL_FIELD"
else
    fail "Manifest artifact URL must be HTTPS or a safe relative filename."
fi
is_https_url "$ARTIFACT_URL" || fail "Resolved artifact URL is not HTTPS."

EXPECTED_SIZE=$(json_value artifact.size) || fail "Manifest is missing artifact size."
[[ "$EXPECTED_SIZE" =~ '^[0-9]+$' ]] || fail "Manifest artifact size is invalid: $EXPECTED_SIZE"
EXPECTED_SHA256=$(json_value artifact.sha256) || fail "Manifest is missing artifact SHA-256."
[[ "$EXPECTED_SHA256" =~ '^[A-Fa-f0-9]{64}$' ]] \
    || fail "Manifest artifact SHA-256 is invalid."

curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --output "$ARCHIVE_FILE" "$ARTIFACT_URL"
ACTUAL_SIZE=$(wc -c < "$ARCHIVE_FILE" | tr -d '[:space:]')
[[ "$ACTUAL_SIZE" == "$EXPECTED_SIZE" ]] \
    || fail "Artifact size does not match the manifest: $ACTUAL_SIZE != $EXPECTED_SIZE"
ACTUAL_SHA256=$(shasum -a 256 "$ARCHIVE_FILE" | awk '{print tolower($1)}')
[[ "$ACTUAL_SHA256" == "${EXPECTED_SHA256:l}" ]] \
    || fail "Artifact SHA-256 does not match the manifest."

while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    case "$entry" in
        "$PRODUCT.app"|"$PRODUCT.app"/*) ;;
        *) fail "Artifact contains an unexpected archive entry: $entry" ;;
    esac
done < <(unzip -Z1 "$ARCHIVE_FILE")

EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ARCHIVE_FILE" "$EXTRACT_DIR"
APP_PATH="$EXTRACT_DIR/$PRODUCT.app"
[[ -d "$APP_PATH" ]] || fail "Artifact does not contain $PRODUCT.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null) \
    || fail "Extracted app is missing CFBundleIdentifier."
[[ "$BUNDLE_ID" == "com.lightanchor.app" ]] \
    || fail "Unexpected extracted bundle identifier: $BUNDLE_ID"
codesign --verify --deep --strict --verbose "$APP_PATH" >/dev/null \
    || fail "Extracted app has an invalid or missing code signature."

# The archive checksum covers the zip; binarySHA256 pins the main executable
# itself, so a tampered archive whose manifest was re-signed for a different
# build, or an extraction that substituted the binary, is caught here too.
EXPECTED_BINARY_SHA256=$(json_value binarySHA256) \
    || fail "Manifest is missing binarySHA256."
[[ "$EXPECTED_BINARY_SHA256" =~ '^[A-Fa-f0-9]{64}$' ]] \
    || fail "Manifest binarySHA256 is invalid."
BINARY_PATH="$APP_PATH/Contents/MacOS/$PRODUCT"
[[ -f "$BINARY_PATH" && ! -L "$BINARY_PATH" ]] \
    || fail "Extracted app is missing its main executable: Contents/MacOS/$PRODUCT"
ACTUAL_BINARY_SHA256=$(shasum -a 256 "$BINARY_PATH" | awk '{print tolower($1)}')
[[ "$ACTUAL_BINARY_SHA256" == "${EXPECTED_BINARY_SHA256:l}" ]] \
    || fail "Extracted binary SHA-256 does not match the manifest binarySHA256."

MANIFEST_BUILD=$(json_value build) || fail "Manifest is missing build."
ARTIFACT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null) \
    || fail "Extracted app is missing CFBundleVersion."
[[ "$ARTIFACT_BUILD" == "$MANIFEST_BUILD" ]] \
    || fail "Manifest build $MANIFEST_BUILD does not match the artifact build $ARTIFACT_BUILD."

# Refuse to replay an older but still correctly signed release: a stale mirror or
# a network attacker could otherwise roll the user back to a vulnerable build.
if [[ -d "$DESTINATION_APP" ]]; then
    CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
        "$DESTINATION_APP/Contents/Info.plist" 2>/dev/null || printf '0')
    if [[ "$MANIFEST_BUILD" =~ '^[0-9]+$' && "$CURRENT_BUILD" =~ '^[0-9]+$' ]] &&
       (( MANIFEST_BUILD < CURRENT_BUILD )); then
        [[ ${LIGHTANCHOR_ALLOW_DOWNGRADE:-0} == "1" ]] \
            || fail "Refusing to downgrade from build $CURRENT_BUILD to $MANIFEST_BUILD. Set LIGHTANCHOR_ALLOW_DOWNGRADE=1 to override."
    fi
fi

"$SCRIPT_DIR/install-release.sh" "$APP_PATH" "$DESTINATION_APP"
printf '%s\n' "Release update verified and installed: $PRODUCT"
