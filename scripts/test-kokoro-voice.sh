#!/bin/zsh
#
# Tests the Kokoro voice with the real model: loading, per-sentence speed,
# audio format and memory. Silent (audio is generated, not played). Uses
# FluidAudio pinned to the Xcode project's version. The first run downloads
# the model (~174 MB) if it isn't cached yet and builds FluidAudio (~2 min);
# later runs reuse both. No Xcode build, no app bundle.
#
# Usage: scripts/test-kokoro-voice.sh

set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"

fluidaudio_version="0.16.1"
test_package_directory="$HOME/Library/Caches/vesper-kokoro-voice-test"
mkdir -p "$test_package_directory/Sources/KokoroVoiceTest"

# SwiftPM only compiles sources inside the package, so the files under test
# are copied into a small package that depends on FluidAudio.
cp "$repository_root/scripts/kokoro-voice-test/main.swift" \
   "$repository_root/leanring-buddy/KokoroSpeechSynthesisProvider.swift" \
   "$repository_root/leanring-buddy/VesperSpeechSynthesisProvider.swift" \
   "$test_package_directory/Sources/KokoroVoiceTest/"

cat > "$test_package_directory/Package.swift" <<MANIFEST
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KokoroVoiceTest",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "$fluidaudio_version")
    ],
    targets: [
        .executableTarget(
            name: "KokoroVoiceTest",
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
./.build/release/KokoroVoiceTest 2>&1 | grep -v "BNNS"
