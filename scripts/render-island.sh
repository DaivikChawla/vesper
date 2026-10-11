#!/bin/zsh
#
# Draws every state of Vesper's island to PNGs (with and without a notch,
# light and dark menu bar) so its layout can be checked without running
# the app. Offscreen only: no windows, no screen capture, no permissions.
#
# Usage: scripts/render-island.sh [output-directory]

set -euo pipefail
cd "$(dirname "$0")/.."

outputDirectory="${1:-${TMPDIR:-/tmp}/vesper-island-renders}"
buildDirectory="$(mktemp -d)"
trap 'rm -rf "$buildDirectory"' EXIT

swiftc -O \
  -swift-version 5 \
  -target arm64-apple-macosx26.0 \
  -parse-as-library \
  leanring-buddy/VesperIsland.swift \
  leanring-buddy/DesignSystem.swift \
  scripts/island-render-test/main.swift \
  -o "$buildDirectory/render-island" 2>&1 | grep -v "warning:" || true

"$buildDirectory/render-island" "$outputDirectory"
