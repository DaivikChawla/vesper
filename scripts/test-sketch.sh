#!/bin/zsh
#
# Tests drawing-to-point (VesperSketch.swift): taps vs strokes, the marked
# area, screenshot mapping, the close-up's area, and that the marks land
# on the image Claude sees. No app build, no windows, no permissions.
#
# Usage: scripts/test-sketch.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

swiftc -o "$temporary_directory/test-sketch" \
  -swift-version 5 \
  leanring-buddy/VesperSketch.swift \
  scripts/sketch-test/main.swift 2>&1 | grep -v "warning:" || true
"$temporary_directory/test-sketch"
