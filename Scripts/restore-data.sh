#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

DATA_ROOT=${LIGHTANCHOR_DATA_ROOT:-${HOME}/Library/Application\ Support/LightAnchor}
BACKUP=""
VERIFY_ONLY=false
REPLACE=false

usage() {
    cat <<'EOF'
Usage: Scripts/restore-data.sh --backup PATH [options]

Verifies a local data backup, or restores it after an explicit replacement flag.

Options:
  --backup PATH     .tar.gz archive to verify or restore.
  --data-root PATH  Destination Light Anchor data directory.
  --verify          Verify the archive without changing local data.
  --replace         Required to replace the destination data directory.
  -h, --help        Show this help.

Restoration preserves an existing destination as a sibling .pre-restore directory.
EOF
}

fail() {
    print -u2 -- "$1"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --backup)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            BACKUP=$2
            shift 2
            ;;
        --backup=*)
            BACKUP=${1#*=}
            shift
            ;;
        --data-root)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            DATA_ROOT=$2
            shift 2
            ;;
        --data-root=*)
            DATA_ROOT=${1#*=}
            shift
            ;;
        --verify)
            VERIFY_ONLY=true
            shift
            ;;
        --replace)
            REPLACE=true
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

[[ -n "$BACKUP" ]] || { usage >&2; exit 2; }
BACKUP=${BACKUP:A}
DATA_ROOT=${DATA_ROOT:A}

[[ -f "$BACKUP" ]] || fail "Backup archive does not exist: $BACKUP"
[[ "$DATA_ROOT" != "/" ]] || fail "Refusing to restore into the filesystem root."
[[ ! -L "$DATA_ROOT" ]] || fail "Destination data directory must not be a symbolic link: $DATA_ROOT"
if [[ "$VERIFY_ONLY" != true && "$REPLACE" != true ]]; then
    fail "Restoration requires the explicit --replace flag."
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-restore.XXXXXX")
EXTRACTED_DIR="$TEMP_DIR/extracted"
mkdir -p "$EXTRACTED_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

ARCHIVE_MEMBERS=$(tar -tzf "$BACKUP") || fail "Could not read backup archive: $BACKUP"
while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    member=${member%/}
    [[ "$member" == "manifest.json" || "$member" == data || "$member" == data/* ]] \
        || fail "Backup contains an unexpected path: $member"
    [[ "$member" != /* && "$member" != *"/../"* && "$member" != ../* && "$member" != *"/.." ]] \
        || fail "Backup contains an unsafe path: $member"
    [[ "$member" != data/launch-marker.json && "$member" != *.lock ]] \
        || fail "Backup contains an excluded runtime file: $member"
done <<< "$ARCHIVE_MEMBERS"

tar -xzf "$BACKUP" -C "$EXTRACTED_DIR" || fail "Could not extract backup archive."
[[ -f "$EXTRACTED_DIR/manifest.json" ]] || fail "Backup manifest is missing."
[[ -d "$EXTRACTED_DIR/data" ]] || fail "Backup data directory is missing."

node - "$EXTRACTED_DIR/data" "$EXTRACTED_DIR/manifest.json" <<'NODE'
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const [dataRoot, manifestPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
if (manifest.schemaVersion !== 1 || manifest.kind !== "LightAnchorLocalDataBackup") {
  throw new Error("unsupported local data backup manifest");
}
if (!Array.isArray(manifest.files) || manifest.fileCount !== manifest.files.length) {
  throw new Error("backup manifest file count is invalid");
}

const excludedNames = new Set(["launch-marker.json"]);
const actual = [];
function walk(current, relative) {
  for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
    if (entry.name === "." || entry.name === ".." || excludedNames.has(entry.name) || entry.name.endsWith(".lock")) {
      throw new Error(`excluded runtime file is present in backup data: ${entry.name}`);
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
      actual.push({
        path: nextRelative,
        size: data.length,
        sha256: crypto.createHash("sha256").update(data).digest("hex")
      });
    } else {
      throw new Error(`unsupported filesystem entry in backup data: ${nextRelative}`);
    }
  }
}

walk(dataRoot, "");
actual.sort((a, b) => a.path.localeCompare(b.path));
const expected = [...manifest.files].sort((a, b) => a.path.localeCompare(b.path));
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  const actualText = JSON.stringify(actual);
  const expectedText = JSON.stringify(expected);
  throw new Error(`backup integrity check failed\nexpected: ${expectedText}\nactual: ${actualText}`);
}
const totalBytes = actual.reduce((sum, file) => sum + file.size, 0);
if (manifest.totalBytes !== totalBytes) {
  throw new Error(`backup total size mismatch: expected ${manifest.totalBytes}, got ${totalBytes}`);
}
NODE

print -r -- "Backup integrity verified: $BACKUP"
if [[ "$VERIFY_ONLY" == true ]]; then
    exit 0
fi

PARENT_DIR="$DATA_ROOT:h"
mkdir -p "$PARENT_DIR"
if [[ -e "$DATA_ROOT" ]]; then
    [[ -d "$DATA_ROOT" ]] || fail "Destination exists but is not a directory: $DATA_ROOT"
    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    PRESERVED_ROOT="$PARENT_DIR/${DATA_ROOT:t}.pre-restore-$STAMP-$RANDOM"
    while [[ -e "$PRESERVED_ROOT" ]]; do
        PRESERVED_ROOT="$PARENT_DIR/${DATA_ROOT:t}.pre-restore-$STAMP-$RANDOM"
    done
    mv "$DATA_ROOT" "$PRESERVED_ROOT" || fail "Could not preserve the existing data directory."
else
    PRESERVED_ROOT=""
fi

if mv "$EXTRACTED_DIR/data" "$DATA_ROOT"; then
    print -r -- "Local data restore passed: $DATA_ROOT"
    [[ -n "$PRESERVED_ROOT" ]] && print -r -- "Previous data preserved at: $PRESERVED_ROOT"
else
    if [[ -n "$PRESERVED_ROOT" && ! -e "$DATA_ROOT" ]]; then
        mv "$PRESERVED_ROOT" "$DATA_ROOT" || true
    fi
    fail "Could not install restored data; previous data was restored when possible."
fi
