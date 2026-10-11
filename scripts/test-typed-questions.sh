#!/bin/zsh
#
# Tests typed questions and the panel's recent conversation without the
# app: typed text never approves a risky confirmation, typed text cleaning,
# and recent-exchange recording (tag stripping, caps, hands-on steps
# joining one entry). Silent, no Claude usage, no Xcode build.
#
# Usage: scripts/test-typed-questions.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

# Same compiler settings as the app target (see scripts/typecheck.sh).
# The confirmation classifier lives in VesperActionSafety.swift, which
# needs the same neighbours as scripts/test-computer-control.sh; the tag
# stripping comes from ClaudeCodeCLIBridge.swift.
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
  -o "$temporary_directory/test-typed-questions" \
  scripts/typed-questions-test/main.swift \
  leanring-buddy/VesperTypedQuestions.swift \
  leanring-buddy/VesperRecentConversation.swift \
  leanring-buddy/ClaudeCodeCLIBridge.swift \
  leanring-buddy/AppBundleConfiguration.swift \
  leanring-buddy/VesperComputerControl.swift \
  leanring-buddy/VesperActionSafety.swift \
  leanring-buddy/VesperScreenSettle.swift \
  leanring-buddy/VesperClickTargetCheck.swift \
  leanring-buddy/VesperResponseStreamParser.swift \
  leanring-buddy/VesperMemoryStore.swift \
  leanring-buddy/VesperOpenLinkPolicy.swift \
  leanring-buddy/VesperCalendarAssistant.swift \
  leanring-buddy/VesperFrontWindowContext.swift \
  leanring-buddy/VesperShortcuts.swift \
  leanring-buddy/VesperLookups.swift \
  leanring-buddy/VesperWindowControl.swift \
  leanring-buddy/CompanionScreenCaptureUtility.swift \
  leanring-buddy/VesperSketch.swift \
  2>&1 | grep -E "error" || true

"$temporary_directory/test-typed-questions"
