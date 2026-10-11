#!/bin/zsh
#
# Tests VesperBrowserTask.swift — the [BROWSER] lane (Claude in Chrome) —
# against a fake `claude --chrome` (scripts/browser-task-test/fake-claude-cli.py):
# the command line, the kill rules (other tools, JavaScript, mail, too many
# calls, SIGKILL), the time limit, cancellation and summary cleaning.
#
# Costs nothing: no Claude requests, no Chrome, no Xcode build. ~10 s.
#
# Usage: scripts/test-browser-task.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

# The runner builds the CLI's environment from scratch, so the fake CLI
# finds its log file through a file sitting next to it instead.
cp scripts/browser-task-test/fake-claude-cli.py "$temporary_directory/claude"
chmod +x "$temporary_directory/claude"
echo "$temporary_directory/fake-claude.log" > "$temporary_directory/fake-claude-cli.logpath"
mkdir -p "$temporary_directory/browser-working-directory"

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
  -o "$temporary_directory/test-browser-task" \
  scripts/browser-task-test/main.swift \
  leanring-buddy/VesperBrowserTask.swift \
  leanring-buddy/VesperWebResearch.swift \
  leanring-buddy/ClaudeCodeCLIBridge.swift \
  leanring-buddy/AppBundleConfiguration.swift \
  2>&1 | grep -E "error" || true

"$temporary_directory/test-browser-task" \
  "$temporary_directory/claude" \
  "$temporary_directory/fake-claude.log" \
  "$temporary_directory/browser-working-directory"
