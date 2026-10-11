#!/bin/zsh
#
# Tests Vesper's computer control without touching the screen: the safety
# policy (what needs a yes, what's refused), key parsing, which [OPEN:...]
# targets are allowed, how spoken yes/no answers are read, and the
# hands-on step runner with a fake mouse/keyboard and a fake screen.
# Nothing is clicked or typed for real. No Xcode build.
#
# Usage: scripts/test-computer-control.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

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
  -o "$temporary_directory/test-computer-control" \
  scripts/computer-control-test/main.swift \
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

"$temporary_directory/test-computer-control"
