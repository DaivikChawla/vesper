#!/bin/zsh
#
# Draws the menu bar panel's pages (Home, Home with a task running, empty
# Home, the whole Settings page) to PNGs with mock data, so the layout can
# be checked without running the app. Offscreen: no window is shown, no
# screen capture, no permissions.
#
# Usage: scripts/render-panel.sh [output-directory]

set -euo pipefail
cd "$(dirname "$0")/.."

outputDirectory="${1:-${TMPDIR:-/tmp}/vesper-panel-renders}"
buildDirectory="$(mktemp -d)"
trap 'rm -rf "$buildDirectory"' EXIT

swiftc -O \
  -swift-version 5 \
  -target arm64-apple-macosx26.0 \
  -parse-as-library \
  leanring-buddy/VesperPanelComponents.swift \
  leanring-buddy/VesperIsland.swift \
  leanring-buddy/DesignSystem.swift \
  scripts/panel-render-test/main.swift \
  -o "$buildDirectory/render-panel" 2>&1 | grep -v "warning:" || true

"$buildDirectory/render-panel" "$outputDirectory"
