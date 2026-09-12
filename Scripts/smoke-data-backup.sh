#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

SMOKE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-backup-smoke.XXXXXX")
DATA_ROOT="$SMOKE_DIR/data"
BACKUP="$SMOKE_DIR/lightanchor-backup.tar.gz"
TAMPERED_BACKUP="$SMOKE_DIR/lightanchor-tampered.tar.gz"
RESTORED_FILE="$DATA_ROOT/events.json"
trap 'rm -rf "$SMOKE_DIR"' EXIT

mkdir -p "$DATA_ROOT/assets/nested"
print -r -- '{"events":[{"id":"backup-smoke"}]}' > "$DATA_ROOT/events.json"
print -r -- 'attachment bytes' > "$DATA_ROOT/assets/nested/attachment.txt"
print -r -- 'should not be archived' > "$DATA_ROOT/launch-marker.json"
print -r -- 'should not be archived' > "$DATA_ROOT/events.json.lock"

LIGHTANCHOR_DATA_ROOT="$DATA_ROOT" \
    LIGHTANCHOR_BACKUP_OUTPUT="$BACKUP" \
    "$SCRIPT_DIR/backup-data.sh" >/dev/null

tar -tzf "$BACKUP" > "$SMOKE_DIR/members.txt"
! rg -n 'launch-marker\.json|\.lock$' "$SMOKE_DIR/members.txt" >/dev/null
rg -n '^manifest\.json$|^data/events\.json$|^data/assets/nested/attachment\.txt$' \
    "$SMOKE_DIR/members.txt" >/dev/null

mkdir -p "$SMOKE_DIR/tampered"
tar -xzf "$BACKUP" -C "$SMOKE_DIR/tampered"
print -r -- '{"events":[{"id":"tampered"}]}' \
    > "$SMOKE_DIR/tampered/data/events.json"
tar -C "$SMOKE_DIR/tampered" -czf "$TAMPERED_BACKUP" manifest.json data
if "$SCRIPT_DIR/restore-data.sh" --backup "$TAMPERED_BACKUP" --verify >/dev/null 2>&1; then
    print -u2 -- "tampered backup unexpectedly passed integrity verification"
    exit 1
fi

print -r -- '{"events":[{"id":"old-data"}]}' > "$RESTORED_FILE"
if LIGHTANCHOR_DATA_ROOT="$DATA_ROOT" \
    "$SCRIPT_DIR/restore-data.sh" --backup "$BACKUP" >/dev/null 2>&1; then
    print -u2 -- "restore unexpectedly succeeded without --replace"
    exit 1
fi

LIGHTANCHOR_DATA_ROOT="$DATA_ROOT" \
    "$SCRIPT_DIR/restore-data.sh" --backup "$BACKUP" --replace > "$SMOKE_DIR/restore.log"

/usr/bin/jq -e '.events[0].id == "backup-smoke"' "$RESTORED_FILE" >/dev/null
[[ -f "$DATA_ROOT/assets/nested/attachment.txt" ]]
PRESERVED=$(sed -n 's/^Previous data preserved at: //p' "$SMOKE_DIR/restore.log")
[[ -n "$PRESERVED" && -f "$PRESERVED/events.json" ]]
/usr/bin/jq -e '.events[0].id == "old-data"' "$PRESERVED/events.json" >/dev/null

print -r -- "Local data backup smoke passed: integrity, exclusions, explicit replace, recoverable restore."
