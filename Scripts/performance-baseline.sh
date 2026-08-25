#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
cd "$ROOT_DIR"

MAX_SECONDS=${LIGHTANCHOR_MAX_VERIFICATION_SECONDS:-180}

started_at=$(date +%s)
swift test
tests_finished_at=$(date +%s)
swift build -c release --product LightAnchor
build_finished_at=$(date +%s)

tests_seconds=$((tests_finished_at - started_at))
build_seconds=$((build_finished_at - tests_finished_at))
total_seconds=$((build_finished_at - started_at))

if (( total_seconds > MAX_SECONDS )); then
    printf '%s\n' "Verification exceeded ${MAX_SECONDS}s: ${total_seconds}s" >&2
    exit 1
fi

printf '%s\n' "{\"testsSeconds\":$tests_seconds,\"releaseBuildSeconds\":$build_seconds,\"totalSeconds\":$total_seconds}"
