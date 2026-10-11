#!/bin/zsh
#
# Tests VesperVoiceRouter — which voice speaks each sentence — with fake
# voices of controlled speed: the Auto race (Google preferred, Kokoro if
# Google is slow), one voice per reply, the Google cooldown, fixed modes,
# and fallbacks. Silent (nothing is played), no network, no Xcode build.
#
# Usage: scripts/test-voice-router.sh

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
  -o "$temporary_directory/test-voice-router" \
  scripts/voice-router-test/main.swift \
  leanring-buddy/VesperVoiceRouter.swift \
  leanring-buddy/VesperSpeechSynthesisProvider.swift \
  2>&1 | grep -E "error" || true

"$temporary_directory/test-voice-router"
