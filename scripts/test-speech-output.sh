#!/bin/zsh
#
# Plays Vesper's voice OUT LOUD through the real speech engine
# (VesperSpeechPlaybackEngine + the macOS system voice) and checks sentence
# ordering, start callbacks, first-word latency, output level, and barge-in.
#
# No Xcode build, no app bundle or signing (so no permission impact), no
# Claude usage. Takes ~15s.
#
# Usage: scripts/test-speech-output.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

# The engine turns AVAudioEngine's Objective-C exceptions into Swift
# errors through a small Objective-C file, compiled separately and linked.
clang -c -fobjc-arc \
  -target arm64-apple-macos26.0 \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -o "$temporary_directory/VesperObjectiveCExceptionCatcher.o" \
  leanring-buddy/VesperObjectiveCExceptionCatcher.m

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
  -o "$temporary_directory/test-speech-output" \
  -import-objc-header leanring-buddy/leanring-buddy-Bridging-Header.h \
  "$temporary_directory/VesperObjectiveCExceptionCatcher.o" \
  leanring-buddy/VesperObjectiveCExceptions.swift \
  scripts/speech-test/main.swift \
  leanring-buddy/VesperSpeechPlaybackEngine.swift \
  leanring-buddy/VesperSpeechSynthesisProvider.swift \
  leanring-buddy/VesperVoiceRouter.swift \
  2>&1 | grep -E "error" || true

# Compiler output is filtered to errors above, so a failed build or link
# would otherwise only show up as a missing binary.
if [ ! -x "$temporary_directory/test-speech-output" ]; then
  echo "❌ the test didn't build"
  exit 1
fi

"$temporary_directory/test-speech-output"
