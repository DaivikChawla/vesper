#!/bin/zsh
#
# Tests VesperInk.swift — her hand-drawn circles, underlines, arrows and
# frames — without building the app. With a file path, also draws a
# sample of every mark over a mock screen to that PNG.
#
# Usage: scripts/test-ink-geometry.sh [picture.png]

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

swiftc -o "$temporary_directory/test-ink-geometry" \
  -swift-version 5 \
  leanring-buddy/VesperInk.swift \
  scripts/ink-geometry-test/main.swift 2>&1 | grep -v "warning:" || true
"$temporary_directory/test-ink-geometry" "$@"
