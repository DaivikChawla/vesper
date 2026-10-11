#!/bin/zsh
#
# Runs the real ClaudeCodeCLIBridge.swift against a fake `claude` CLI
# (scripts/bridge-test/fake-claude-cli.py) and checks the hard cases:
# streaming, barge-in, crash recovery with recap, usage limits, logout,
# context rollover, model switching, new conversations, and stalls.
#
# Costs nothing: no real Claude requests, no internet, no Xcode build, no
# app bundle or signing (so no permission impact). Takes ~30s because one
# check waits out the 25s "Claude didn't answer" timeout.
#
# Usage: scripts/test-claude-bridge.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

# The bridge builds the CLI's environment from scratch, so the fake CLI
# finds its log file through a file sitting next to it instead.
cp scripts/bridge-test/fake-claude-cli.py "$temporary_directory/claude"
chmod +x "$temporary_directory/claude"
echo "$temporary_directory/fake-claude.log" > "$temporary_directory/fake-claude-cli.logpath"

# Same compiler settings as the app target (see scripts/typecheck.sh).
swiftc \
  -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature DisableOutwardActorInference \
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature InferSendableFromCaptures \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -o "$temporary_directory/test-claude-bridge" \
  scripts/bridge-test/main.swift \
  leanring-buddy/ClaudeCodeCLIBridge.swift \
  leanring-buddy/AppBundleConfiguration.swift \
  2>&1 | grep -E "error" || true

"$temporary_directory/test-claude-bridge" "$temporary_directory/claude" "$temporary_directory/fake-claude.log"
