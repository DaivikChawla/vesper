#!/bin/zsh
#
# Tests VesperClickTargetCheck.swift — "look before you click" — on real UI
# pictures (the panel's renders): an unchanged screen must look the same
# despite JPEG and scaling, the pointer mustn't count, and a page that moved
# or changed under the point must be caught. Silent, no screen capture.
#
# Usage: scripts/test-click-target-check.sh

set -euo pipefail
cd "$(dirname "$0")/.."

buildDirectory="$(mktemp -d)"
trap 'rm -rf "$buildDirectory"' EXIT

scripts/render-panel.sh "$buildDirectory/pictures" > /dev/null

swiftc -O \
  -swift-version 5 \
  -target arm64-apple-macosx26.0 \
  leanring-buddy/VesperClickTargetCheck.swift \
  scripts/click-target-check-test/main.swift \
  -o "$buildDirectory/test-click-target-check" 2>&1 | grep -v "warning:" || true

"$buildDirectory/test-click-target-check" "$buildDirectory/pictures/1-home.png" "$buildDirectory/pictures/3-home-empty.png"
