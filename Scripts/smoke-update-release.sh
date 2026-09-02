#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

PORT=${LIGHTANCHOR_UPDATE_SMOKE_PORT:-18889}
CHROME_PORT_CHECK=""

usage() {
    cat <<'EOF'
Usage: Scripts/smoke-update-release.sh

Builds an ad-hoc signed local release, serves its manifest and archive over a
temporary HTTPS server, and runs the real updater against a temporary install
directory. It verifies the RSA manifest, artifact checksum, App signature,
bundle identity, staging install, and previous-version retention.

Environment:
  LIGHTANCHOR_UPDATE_SMOKE_PORT  HTTPS fixture port (default 18889).
EOF
}

case "${1:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; print -u2 -- "Unknown argument: $1"; exit 2 ;;
esac

for command in openssl node curl codesign plutil ditto rg jq; do
    command -v "$command" >/dev/null 2>&1 || {
        print -u2 -- "Required command is unavailable: $command"
        exit 1
    }
done

if /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | rg -q LISTEN; then
    print -u2 -- "Update smoke HTTPS port is already in use: $PORT"
    exit 1
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-update-smoke.XXXXXX")
CERT_FILE="$TEMP_DIR/server.crt"
SERVER_KEY="$TEMP_DIR/server.key"
UPDATE_PRIVATE_KEY="$TEMP_DIR/update-private.pem"
UPDATE_PUBLIC_KEY="$TEMP_DIR/update-public.pem"
SERVER_LOG="$TEMP_DIR/server.log"
DESTINATION_PARENT="$TEMP_DIR/install"
DESTINATION_APP="$DESTINATION_PARENT/LightAnchor.app"
SERVER_PID=""
mkdir -p "$DESTINATION_PARENT"

cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$SERVER_KEY" \
    -out "$CERT_FILE" \
    -days 1 \
    -subj "/CN=127.0.0.1" \
    -addext "subjectAltName = IP:127.0.0.1" >/dev/null 2>&1
openssl genrsa -out "$UPDATE_PRIVATE_KEY" 2048 >/dev/null 2>&1
openssl rsa -in "$UPDATE_PRIVATE_KEY" -pubout -out "$UPDATE_PUBLIC_KEY" >/dev/null 2>&1

LIGHTANCHOR_SIGNING_IDENTITY=- \
LIGHTANCHOR_UPDATE_PRIVATE_KEY="$UPDATE_PRIVATE_KEY" \
LIGHTANCHOR_UPDATE_URL="https://127.0.0.1:$PORT" \
    "$SCRIPT_DIR/build-release.sh" > "$TEMP_DIR/build.log" 2>&1 || {
    cat "$TEMP_DIR/build.log" >&2
    exit 1
}

node - "$SERVER_KEY" "$CERT_FILE" "$ROOT_DIR/dist" "$PORT" > "$SERVER_LOG" 2>&1 <<'NODE' &
const fs = require("node:fs");
const https = require("node:https");
const path = require("node:path");

const [keyFile, certFile, root, port] = process.argv.slice(2);
const server = https.createServer({
  key: fs.readFileSync(keyFile),
  cert: fs.readFileSync(certFile)
}, (request, response) => {
  let relative;
  try {
    relative = decodeURIComponent(new URL(request.url, "https://127.0.0.1").pathname)
      .replace(/^\/+/, "");
  } catch (_) {
    response.writeHead(400); response.end("bad request"); return;
  }
  if (!relative || relative.includes("..") || relative.includes("\\")) {
    response.writeHead(404); response.end("not found"); return;
  }
  const file = path.join(root, relative);
  if (!file.startsWith(`${root}${path.sep}`)) {
    response.writeHead(404); response.end("not found"); return;
  }
  fs.stat(file, (error, stat) => {
    if (error || !stat.isFile()) {
      response.writeHead(404); response.end("not found"); return;
    }
    response.writeHead(200, { "Content-Length": stat.size });
    fs.createReadStream(file).pipe(response);
  });
});
server.listen(Number(port), "127.0.0.1", () => process.stdout.write("ready\n"));
NODE
SERVER_PID=$!

for _ in {1..50}; do
    if curl --fail --silent --show-error --cacert "$CERT_FILE" \
        "https://127.0.0.1:$PORT/LightAnchor-release-manifest.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
curl --fail --silent --show-error --cacert "$CERT_FILE" \
    "https://127.0.0.1:$PORT/LightAnchor-release-manifest.json" >/dev/null

# This smoke builds with an ad-hoc identity that is neither Developer ID signed
# nor notarized, which install-release.sh refuses by default; opt out of both
# gates explicitly here rather than weakening the production defaults.
CURL_CA_BUNDLE="$CERT_FILE" \
LIGHTANCHOR_ALLOW_ADHOC_SIGNATURE=1 \
LIGHTANCHOR_REQUIRE_NOTARIZATION=0 \
    "$SCRIPT_DIR/update-release.sh" \
    --manifest-url "https://127.0.0.1:$PORT/LightAnchor-release-manifest.json" \
    --public-key "$UPDATE_PUBLIC_KEY" \
    --destination "$DESTINATION_APP" >/dev/null

LIGHTANCHOR_ALLOW_ADHOC_SIGNATURE=1 \
LIGHTANCHOR_REQUIRE_NOTARIZATION=0 \
    "$SCRIPT_DIR/install-release.sh" \
    "$ROOT_DIR/dist/LightAnchor.app" \
    "$DESTINATION_APP" >/dev/null

# install-release.sh keeps the superseded app inside an unpredictable
# `.LightAnchor.previous.XXXXXX/` slot created with mktemp.
BACKUP_COUNT=$(find "$DESTINATION_PARENT" -maxdepth 2 -path '*/.LightAnchor.previous.*/LightAnchor.app' -type d | wc -l | tr -d '[:space:]')
[[ "$BACKUP_COUNT" -ge 1 ]] || {
    print -u2 -- "Update smoke did not retain the previous installed app."
    exit 1
}

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION_APP/Contents/Info.plist")
[[ "$BUNDLE_ID" == "com.lightanchor.app" ]] || {
    print -u2 -- "Update smoke installed an unexpected bundle identifier: $BUNDLE_ID"
    exit 1
}

print -r -- "Update release smoke passed: HTTPS manifest, RSA signature, artifact checksum, signed App validation, staging install and previous-version retention."
