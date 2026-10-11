#!/bin/zsh
#
# Tests "only my voice" with the real CAM++ model (pinned FluidAudio): model
# load and per-check time, a voiceprint learned from three clips, and
# accept/reject on new clips. macOS voices stand in for different people,
# so this is a sanity check; real tuning comes from the similarity scores
# Vesper logs on the owner's voice. Silent, touches no Keychain items, no
# Xcode build. First run downloads the model (a few MB).
#
# Usage: scripts/test-voice-id.sh

set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"

fluidaudio_version="0.16.1"
test_package_directory="$HOME/Library/Caches/vesper-voice-id-test"
clips_directory="$test_package_directory/clips"
mkdir -p "$test_package_directory/Sources/VoiceIDTest" "$clips_directory"

cp "$repository_root/scripts/voice-id-test/main.swift" \
   "$repository_root/leanring-buddy/VesperVoiceIdentity.swift" \
   "$repository_root/leanring-buddy/VesperKeychain.swift" \
   "$test_package_directory/Sources/VoiceIDTest/"

# Clips: the "owner" is Samantha; everyone else is a different voice.
make_clip() {
  say -v "$1" -o "$clips_directory/$2.wav" --file-format=WAVE --data-format=LEF32@16000 "$3"
}
make_clip Samantha owner-1 "Hey, can you find the export button in this app for me?"
make_clip Samantha owner-2 "Open YouTube in Chrome and search for some lo-fi beats."
make_clip Samantha owner-3 "What does this error in my terminal actually mean?"
make_clip Samantha owner-4 "Remind me what my Fiverr basic package costs right now."
make_clip Samantha owner-5 "Play something by Queen and turn the volume down a bit."
make_clip Samantha short-yes "Yes."
make_clip Daniel other-daniel "Open YouTube in Chrome and search for some lo-fi beats."
make_clip Karen other-karen "Remind me what my Fiverr basic package costs right now."
make_clip Moira other-moira "What does this error in my terminal actually mean?"
make_clip "Rishi (English (India))" other-rishi "Hey, can you find the export button in this app for me?"
make_clip Fred other-fred "Play something by Queen and turn the volume down a bit."
make_clip Tessa other-tessa "Remind me what my Fiverr basic package costs right now."

cat > "$test_package_directory/Package.swift" <<MANIFEST
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceIDTest",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "$fluidaudio_version")
    ],
    targets: [
        .executableTarget(
            name: "VoiceIDTest",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            // Same settings as the app target.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
MANIFEST

cd "$test_package_directory"
swift build -c release 2>&1 | grep -E "error:" || true
./.build/release/VoiceIDTest "$clips_directory" 2>&1 | grep -vE "BNNS|^\[.*INFO"
