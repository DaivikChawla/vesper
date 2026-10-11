#!/bin/zsh
#
# Tests the fast lane (VesperInstantCommands.swift): plain commands done on
# the Mac without Claude, and the phrasings that must still go to Claude.
# No app build, no actions run.
#
# Usage: scripts/test-instant-commands.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

swiftc -o "$temporary_directory/test-instant-commands" \
  -swift-version 5 \
  leanring-buddy/VesperInstantCommands.swift \
  leanring-buddy/VesperResponseStreamParser.swift \
  scripts/instant-commands-test/main.swift 2>&1 | grep -v "warning:" || true
"$temporary_directory/test-instant-commands"
