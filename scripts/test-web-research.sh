#!/bin/zsh
#
# Tests VesperWebResearch.swift — the [RESEARCH] lane — against a fake
# `claude` CLI (scripts/web-research-test/fake-claude-cli.py): the question
# filter, answer cleaning, the command line and environment, stream-json
# parsing, the kill rules (other tools, too many web calls, SIGKILL for a
# process ignoring SIGTERM), the overall time limit and cancellation.
#
# Costs nothing: no real Claude requests, no internet, no Xcode build, no
# app bundle or signing (so no permission impact). Takes ~15 s.
#
# Usage: scripts/test-web-research.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

# The runner builds the CLI's environment from scratch, so the fake CLI
# finds its log file through a file sitting next to it instead.
cp scripts/web-research-test/fake-claude-cli.py "$temporary_directory/claude"
chmod +x "$temporary_directory/claude"
echo "$temporary_directory/fake-claude.log" > "$temporary_directory/fake-claude-cli.logpath"
mkdir -p "$temporary_directory/research-working-directory"

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
  -o "$temporary_directory/test-web-research" \
  scripts/web-research-test/main.swift \
  leanring-buddy/VesperWebResearch.swift \
  leanring-buddy/ClaudeCodeCLIBridge.swift \
  leanring-buddy/AppBundleConfiguration.swift \
  2>&1 | grep -E "error" || true

"$temporary_directory/test-web-research" \
  "$temporary_directory/claude" \
  "$temporary_directory/fake-claude.log" \
  "$temporary_directory/research-working-directory"
