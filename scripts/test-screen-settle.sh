#!/bin/zsh
#
# Tests VesperScreenSettle.swift — when she decides the screen has finished
# reacting between hands-on steps — with made-up screens: still screens,
# clicks with and without a visible effect, pages that load late or keep
# filling in, playing videos, endless flicker, a blinking text cursor.
# Silent: no screen capture, no permissions.
#
# Usage: scripts/test-screen-settle.sh

set -euo pipefail
cd "$(dirname "$0")/.."

buildDirectory="$(mktemp -d)"
trap 'rm -rf "$buildDirectory"' EXIT

swiftc -O \
  -swift-version 5 \
  -target arm64-apple-macosx26.0 \
  leanring-buddy/VesperScreenSettle.swift \
  scripts/screen-settle-test/main.swift \
  -o "$buildDirectory/test-screen-settle" 2>&1 | grep -v "warning:" || true

"$buildDirectory/test-screen-settle"
