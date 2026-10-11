#!/bin/zsh
#
# Type-checks every Swift file in the app target without building an app.
#
# Why this exists: never run `xcodebuild` from the terminal for this app,
# because producing and signing a new app bundle invalidates macOS privacy
# permissions (Screen Recording, Accessibility, Microphone). `swiftc
# -typecheck` produces no output files at all, so it catches compile errors
# without touching permissions. It works with just the Xcode Command Line
# Tools installed.
#
# The flags mirror the target's build settings in project.pbxproj:
#   SWIFT_VERSION = 5.0
#   SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
#   SWIFT_APPROACHABLE_CONCURRENCY = YES
#   SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES
#   MACOSX_DEPLOYMENT_TARGET = 26.0
#   SWIFT_OBJC_BRIDGING_HEADER = leanring-buddy/leanring-buddy-Bridging-Header.h
#
# The Objective-C files themselves (.m) aren't compiled here; Xcode builds
# them. Swift is checked against their headers through the bridging header.
#
# Usage: scripts/typecheck.sh

set -euo pipefail
cd "$(dirname "$0")/.."

# The app depends on FluidAudio (Kokoro voice). Type-checking needs its
# compiled module, so a copy pinned to the same version as the Xcode project
# is built once into ~/Library/Caches and reused afterwards (~1.5 min).
fluidaudio_version="v0.16.1"
fluidaudio_directory="$HOME/Library/Caches/vesper-typecheck/FluidAudio-$fluidaudio_version"
# A compiled Swift module only loads in the compiler version that built it,
# so the cache is rebuilt whenever the toolchain changes (e.g. an Xcode update).
toolchain_stamp_file="$fluidaudio_directory/.vesper-toolchain-version"
current_toolchain_version="$(swiftc --version 2>&1 | head -1)"

find_fluidaudio_modules_directory() {
  # Where SwiftPM puts modules differs between toolchains
  # (.build/<triple>/debug/Modules on older ones, .build/out/Products/Debug on newer).
  local swiftmodule_path
  swiftmodule_path="$(find "$fluidaudio_directory/.build" -maxdepth 5 -name FluidAudio.swiftmodule 2>/dev/null | head -1)"
  [ -n "$swiftmodule_path" ] && dirname "$swiftmodule_path"
}

fluidaudio_modules="$(find_fluidaudio_modules_directory || true)"
if [ -z "$fluidaudio_modules" ] || [ "$(cat "$toolchain_stamp_file" 2>/dev/null)" != "$current_toolchain_version" ]; then
  echo "Building FluidAudio $fluidaudio_version for type-checking (once per Swift toolchain)..."
  mkdir -p "$(dirname "$fluidaudio_directory")"
  [ -d "$fluidaudio_directory" ] || git clone --quiet --depth 1 --branch "$fluidaudio_version" \
    https://github.com/FluidInference/FluidAudio.git "$fluidaudio_directory" 2>/dev/null
  rm -rf "$fluidaudio_directory/.build"
  (cd "$fluidaudio_directory" && swift build --target FluidAudio >/dev/null)
  echo "$current_toolchain_version" > "$toolchain_stamp_file"
  fluidaudio_modules="$(find_fluidaudio_modules_directory)"
fi

# FluidAudio's own C dependencies, which its module references.
fluidaudio_c_module_maps=(
  "$fluidaudio_directory/Sources/FastClusterWrapper/include/module.modulemap"
  "$fluidaudio_directory/Sources/MachTaskSelfWrapper/include/module.modulemap"
  "$fluidaudio_directory/.build/artifacts/fluidaudio-$fluidaudio_version/NemoTextProcessing/NemoTextProcessing.xcframework/macos-arm64_x86_64/Headers/CNemoTextProcessing/module.modulemap"
)
fluidaudio_c_module_flags=()
for module_map in "${fluidaudio_c_module_maps[@]}"; do
  fluidaudio_c_module_flags+=(-Xcc "-fmodule-map-file=$module_map")
done

swiftc -typecheck \
  -I "$fluidaudio_modules" \
  "${fluidaudio_c_module_flags[@]}" \
  -parse-as-library \
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
  -D DEBUG \
  -import-objc-header leanring-buddy/leanring-buddy-Bridging-Header.h \
  leanring-buddy/*.swift

echo "✅ typecheck passed"
