#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/EdgeProfileDock-tests.XXXXXXXX")"
trap 'find "$WORK" -depth -delete' EXIT
mkdir -p "$WORK/tmp"

cd "$ROOT"
TMPDIR="$WORK/tmp" swift test --scratch-path "$WORK/swift" --jobs 2
