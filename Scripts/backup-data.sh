#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

DATA_ROOT=${LIGHTANCHOR_DATA_ROOT:-${HOME}/Library/Application\ Support/LightAnchor}
OUTPUT=${LIGHTANCHOR_BACKUP_OUTPUT:-$ROOT_DIR/dist/lightanchor-data-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz}
FORCE=false

usage() {
    cat <<'EOF'
Usage: Scripts/backup-data.sh [options]

Creates a compressed local data backup with a schema and SHA-256 manifest.

Options:
  --data-root PATH  Source Light Anchor data directory.
  --output PATH     Destination .tar.gz archive.
  --force           Replace an existing archive at the destination.
  -h, --help        Show this help.
EOF
}

fail() {
    print -u2 -- "$1"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --data-root)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            DATA_ROOT=$2
            shift 2
            ;;
        --data-root=*)
            DATA_ROOT=${1#*=}
            shift
            ;;
        --output)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            OUTPUT=$2
            shift 2
            ;;
        --output=*)
            OUTPUT=${1#*=}
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            print -u2 -- "Unknown argument: $1"
            exit 2
            ;;
    esac
done

DATA_ROOT=${DATA_ROOT:A}
OUTPUT=${OUTPUT:A}

[[ "$DATA_ROOT" != "/" ]] || fail "Refusing to back up the filesystem root."
[[ -d "$DATA_ROOT" ]] || fail "Data directory does not exist: $DATA_ROOT"
[[ ! -L "$DATA_ROOT" ]] || fail "Data directory must not be a symbolic link: $DATA_ROOT"
[[ "$OUTPUT" != "$DATA_ROOT" && "$OUTPUT" != "$DATA_ROOT"/* ]] \
    || fail "Backup output must be outside the data directory."

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-backup.XXXXXX")
STAGING_DIR="$TEMP_DIR/archive"
mkdir -p "$STAGING_DIR/data"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Tar provides a consistent directory snapshot while the app's lock files are excluded.
tar -C "$DATA_ROOT" \
    --exclude='launch-marker.json' \
    --exclude='*.lock' \
    -cf - . | tar -C "$STAGING_DIR/data" -xf -

node - "$STAGING_DIR/data" "$STAGING_DIR/manifest.json" "$DATA_ROOT" <<'NODE'
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const [dataRoot, manifestPath, sourceRoot] = process.argv.slice(2);
const excludedNames = new Set(["launch-marker.json"]);
const files = [];

function walk(current, relative) {
  for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
    if (entry.name === "." || entry.name === ".." || excludedNames.has(entry.name) || entry.name.endsWith(".lock")) {
      continue;
    }
    const next = path.join(current, entry.name);
    const nextRelative = relative ? path.posix.join(relative, entry.name) : entry.name;
    if (entry.isSymbolicLink()) {
      throw new Error(`symbolic links are not supported in local backups: ${nextRelative}`);
    }
    if (entry.isDirectory()) {
      walk(next, nextRelative);
    } else if (entry.isFile()) {
      const data = fs.readFileSync(next);
      files.push({
        path: nextRelative,
        size: data.length,
        sha256: crypto.createHash("sha256").update(data).digest("hex")
      });
    } else {
      throw new Error(`unsupported filesystem entry in local data: ${nextRelative}`);
    }
  }
}

walk(dataRoot, "");
files.sort((a, b) => a.path.localeCompare(b.path));
const manifest = {
  schemaVersion: 1,
  kind: "LightAnchorLocalDataBackup",
  source: "LightAnchor",
  sourceRootName: path.basename(sourceRoot),
  createdAt: new Date().toISOString(),
  fileCount: files.length,
  totalBytes: files.reduce((sum, file) => sum + file.size, 0),
  files
};
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE

mkdir -p "${OUTPUT:h}"
if [[ -e "$OUTPUT" && "$FORCE" != true ]]; then
    fail "Backup output already exists; choose another path or use --force: $OUTPUT"
fi
# Build and verify somewhere disposable first. Writing straight to $OUTPUT would
# destroy a previous backup at that path whenever tar or the verify step failed,
# which is exactly when the old one is still needed.
STAGED_ARCHIVE="$TEMP_DIR/staged-backup.tar.gz"
tar -C "$STAGING_DIR" -czf "$STAGED_ARCHIVE" manifest.json data

"$SCRIPT_DIR/restore-data.sh" --backup "$STAGED_ARCHIVE" --verify >/dev/null

mv -f "$STAGED_ARCHIVE" "$OUTPUT"

SIZE=$(stat -f%z "$OUTPUT")
SHA256=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
print -r -- "Local data backup passed: $OUTPUT"
print -r -- "Archive size: ${SIZE} bytes"
print -r -- "Archive SHA-256: $SHA256"
