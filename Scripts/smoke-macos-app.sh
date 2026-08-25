#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

APP=${LIGHTANCHOR_APP_PATH:-$ROOT_DIR/dist/LightAnchor.app}
SKIP_BUILD=${LIGHTANCHOR_SKIP_BUILD:-false}
DATA_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lightanchor-app-smoke.XXXXXX")
SMOKE_BUNDLE_ID="com.lightanchor.smoke.$$"
DATA_ROOT=${DATA_ROOT:A}
SMOKE_APP="$DATA_ROOT/LightAnchorSmoke.app"
APP_LOG="$DATA_ROOT/app.log"
EVENT_LOG="$DATA_ROOT/external-events.jsonl"
MARKER="$DATA_ROOT/launch-marker.json"
APP_PID=""
QUIT_REQUESTED=false

cleanup() {
    if [[ -x "$SMOKE_APP/Contents/MacOS/LightAnchor" ]]; then
        while IFS= read -r smoke_pid; do
            [[ -n "$smoke_pid" ]] || continue
            kill "$smoke_pid" 2>/dev/null || true
        done < <(/usr/bin/pgrep -f "$SMOKE_APP/Contents/MacOS/LightAnchor" 2>/dev/null || true)
    fi
    if [[ -d "$DATA_ROOT" ]]; then
        rm -rf "$DATA_ROOT"
    fi
}
trap cleanup EXIT INT TERM

fail() {
    print -u2 -- "$1"
    if [[ -s "$APP_LOG" ]]; then
        tail -n 20 "$APP_LOG" >&2 || true
    fi
    exit 1
}

if [[ "$SKIP_BUILD" != "true" ]]; then
    "$SCRIPT_DIR/build-release.sh" >/dev/null
fi

[[ -d "$APP" ]] || fail "macOS app bundle is missing: $APP"
[[ -x "$APP/Contents/MacOS/LightAnchor" ]] || fail "app executable is missing"
[[ -f "$APP/Contents/Info.plist" ]] || fail "app Info.plist is missing"

# Use a unique local bundle identity so smoke automation never attaches to a
# user's already-running LightAnchor instance or routes its deep link there.
/usr/bin/ditto "$APP" "$SMOKE_APP"
/usr/bin/plutil -replace CFBundleIdentifier -string "$SMOKE_BUNDLE_ID" \
    "$SMOKE_APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "LightAnchor Smoke" \
    "$SMOKE_APP/Contents/Info.plist" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$SMOKE_APP" >/dev/null 2>&1 || true
APP="$SMOKE_APP"

LIGHTANCHOR_DATA_ROOT="$DATA_ROOT" \
    /usr/bin/open -n "$APP" --stdout "$APP_LOG" --stderr "$APP_LOG"

for _ in {1..40}; do
    APP_PID=$(/usr/bin/pgrep -f "$APP/Contents/MacOS/LightAnchor" | sort -n | tail -n 1 || true)
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    sleep 0.25
done
[[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null || fail "app exited during launch"
for _ in {1..40}; do
    [[ -f "$MARKER" ]] && break
    sleep 0.25
done
[[ -f "$MARKER" ]] || fail "app did not create the launch marker"
sleep 1

run_close_script() {
    /usr/bin/osascript - "$APP_PID" >"$DATA_ROOT/close-window.log" 2>&1 <<'APPLESCRIPT' &
on run argv
    set appPID to (item 1 of argv) as integer
    tell application "System Events"
        repeat with processRef in application processes
            if unix id of processRef is appPID then
                tell processRef to keystroke "w" using {command down}
                return
            end if
        end repeat
    end tell
    error "smoke process was not found"
end run
APPLESCRIPT
    local script_pid=$!
    for _ in {1..40}; do
        if ! kill -0 "$script_pid" 2>/dev/null; then
            wait "$script_pid"
            return $?
        fi
        sleep 0.25
    done
    kill -9 "$script_pid" 2>/dev/null || true
    wait "$script_pid" 2>/dev/null || true
    return 124
}

if ! run_close_script; then
    fail "could not close the main window"
fi
sleep 1
kill -0 "$APP_PID" 2>/dev/null || fail "app exited after its main window was closed"

/usr/bin/open "$APP" >/dev/null 2>&1 || fail "could not ask macOS to reopen the app"
sleep 1
[[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null || fail "smoke app disappeared after reopen"
for _ in {1..40}; do
    WINDOW_COUNT=$(/usr/bin/osascript - "$APP_PID" 2>/dev/null <<'APPLESCRIPT' || print -r -- 0
on run argv
    set appPID to (item 1 of argv) as integer
    tell application "System Events"
        repeat with processRef in application processes
            if unix id of processRef is appPID then return count windows of processRef
        end repeat
    end tell
    return 0
end run
APPLESCRIPT
    )
    [[ "$WINDOW_COUNT" -gt 0 ]] && break
    sleep 0.25
done
[[ "${WINDOW_COUNT:-0}" -gt 0 ]] || fail "app did not reopen a main window"
# Exactly one: AppKit's default reopen already restores a workspace window, so
# anything that also opens one on the side shows up here as a duplicate.
[[ "${WINDOW_COUNT:-0}" -eq 1 ]] || fail "reopen produced $WINDOW_COUNT windows, expected 1"

CORRELATION="macos-app-smoke-${APP_PID}-${RANDOM}"
EVENT_URL="lightanchor://event?source=custom&kind=completed&correlation=${CORRELATION}&title=Smoke%20deep%20link&detail=Event%20arrived"

send_event() {
    /usr/bin/osascript \
        -e "tell application id \"$SMOKE_BUNDLE_ID\" to open location \"$EVENT_URL\"" \
        >/dev/null 2>&1 || true
}

send_event
for _ in {1..40}; do
    if [[ -s "$EVENT_LOG" ]] && \
        /usr/bin/jq -e --arg correlation "$CORRELATION" \
        'select(.correlationID == $correlation)' "$EVENT_LOG" >/dev/null 2>&1; then
        break
    fi
    sleep 0.25
done
[[ -s "$EVENT_LOG" ]] || fail "deep-link event was not written to the isolated store"
/usr/bin/jq -e --arg correlation "$CORRELATION" \
    'select(.correlationID == $correlation and .kind == "completed")' \
    "$EVENT_LOG" >/dev/null \
    || fail "deep-link event did not match the expected completion record"

if /usr/bin/osascript \
    -e "tell application id \"$SMOKE_BUNDLE_ID\" to quit" \
    >/dev/null 2>&1; then
    QUIT_REQUESTED=true
fi

for _ in {1..40}; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        wait "$APP_PID" 2>/dev/null || true
        break
    fi
    sleep 0.25
done

if kill -0 "$APP_PID" 2>/dev/null; then
    fail "app did not terminate after the quit request"
fi
wait "$APP_PID" 2>/dev/null || true
[[ "$QUIT_REQUESTED" == "true" ]] || fail "could not send a normal quit request"
[[ ! -e "$MARKER" ]] || fail "normal app termination did not clean the launch marker"

print -r -- "macOS app smoke passed: window close/reopen (single window), isolated data root, deep link, event persistence, clean exit."
