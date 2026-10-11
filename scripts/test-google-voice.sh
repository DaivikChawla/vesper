#!/bin/zsh
#
# Tests the Google Chirp 3 HD voice provider against a fake Google server
# (scripts/google-voice-test/fake-google-tts-server.py): success and what's
# sent, the 950,000-character monthly stop, API/billing/voice errors, busy
# responses and a slow network. Silent, no real key, no internet, no Xcode.
#
# Usage: scripts/test-google-voice.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
python3 scripts/google-voice-test/fake-google-tts-server.py "$temporary_directory" &
fake_server_pid=$!
trap 'kill $fake_server_pid 2>/dev/null; rm -rf "$temporary_directory"' EXIT

for _ in {1..50}; do
  [ -f "$temporary_directory/port" ] && break
  sleep 0.1
done
fake_server_url="http://127.0.0.1:$(cat "$temporary_directory/port")"

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
  -o "$temporary_directory/test-google-voice" \
  scripts/google-voice-test/main.swift \
  leanring-buddy/GoogleChirpSpeechSynthesisProvider.swift \
  leanring-buddy/VesperSpeechSynthesisProvider.swift \
  2>&1 | grep -E "error" || true

"$temporary_directory/test-google-voice" "$fake_server_url" "$temporary_directory"
