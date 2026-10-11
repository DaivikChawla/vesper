#!/bin/zsh
#
# Tests VesperSpeechPlaybackEngine — the single speech player — with fake
# voices that return silent audio: sentence order, a reply reporting that it
# finished, barge-in during synthesis (the interrupted reply never starts
# or finishes), and stop. Silent, no network, no Xcode build.
#
# Usage: scripts/test-playback-engine.sh

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
  -o "$temporary_directory/test-playback-engine" \
  -import-objc-header leanring-buddy/leanring-buddy-Bridging-Header.h \
  "$temporary_directory/VesperObjectiveCExceptionCatcher.o" \
  leanring-buddy/VesperObjectiveCExceptions.swift \
  scripts/playback-engine-test/main.swift \
  leanring-buddy/VesperSpeechPlaybackEngine.swift \
  leanring-buddy/VesperVoiceRouter.swift \
  leanring-buddy/VesperSpeechSynthesisProvider.swift \
  2>&1 | grep -E "error" || true

# Compiler output is filtered to errors above, so a failed build or link
# would otherwise only show up as a missing binary.
if [ ! -x "$temporary_directory/test-playback-engine" ]; then
  echo "❌ the test didn't build"
  exit 1
fi

"$temporary_directory/test-playback-engine"
