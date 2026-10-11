#!/bin/zsh
#
# Tests the pure logic behind two on-screen guides, without building the
# app: the [HIGHLIGHT] rectangle's geometry (corners in either order, the
# minimum size, staying on its screen, a corner radius CGPath accepts) and
# the walkthrough step chip ("2/4"). Silent, no permissions, no usage.
#
# Usage: scripts/test-on-screen-guides.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

cat > "$temporary_directory/main.swift" <<'SWIFT'
import CoreGraphics
import Foundation

var failureCount = 0

func check(_ testName: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("✅ \(testName)")
    } else {
        failureCount += 1
        print("❌ \(testName) \(detail())")
    }
}

let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

do {
    // Flipping the y axis swaps which corner is on top: the same rect either way.
    let rectFromTopLeftFirst = VesperHighlightGeometry.drawableRect(
        betweenCorner: CGPoint(x: 100, y: 800), andCorner: CGPoint(x: 400, y: 600), displayFrame: displayFrame
    )
    let rectFromBottomRightFirst = VesperHighlightGeometry.drawableRect(
        betweenCorner: CGPoint(x: 400, y: 600), andCorner: CGPoint(x: 100, y: 800), displayFrame: displayFrame
    )
    check("corners in either order make the same rectangle", rectFromTopLeftFirst == rectFromBottomRightFirst)
    check("the rectangle sits just outside the area",
          rectFromTopLeftFirst == CGRect(x: 96, y: 596, width: 308, height: 208), "\(rectFromTopLeftFirst)")
}

do {
    let thinLineRect = VesperHighlightGeometry.drawableRect(
        betweenCorner: CGPoint(x: 200, y: 500), andCorner: CGPoint(x: 600, y: 500), displayFrame: displayFrame
    )
    check("a zero-height area grows to the minimum size around its middle",
          thinLineRect.height == VesperHighlightGeometry.minimumSidePoints && thinLineRect.midY == 500, "\(thinLineRect)")
}

do {
    let edgeRect = VesperHighlightGeometry.drawableRect(
        betweenCorner: CGPoint(x: 0, y: 982), andCorner: CGPoint(x: 300, y: 940), displayFrame: displayFrame
    )
    check("an area at the screen's corner stays on the screen", displayFrame.contains(edgeRect), "\(edgeRect)")
    check("…and keeps its size", edgeRect.width == 308 && edgeRect.height == 50, "\(edgeRect)")
}

do {
    let secondScreenFrame = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
    let secondScreenRect = VesperHighlightGeometry.drawableRect(
        betweenCorner: CGPoint(x: 1500, y: -210), andCorner: CGPoint(x: 1600, y: -150), displayFrame: secondScreenFrame
    )
    check("works on a screen with an offset origin", secondScreenFrame.contains(secondScreenRect), "\(secondScreenRect)")
}

do {
    let smallRect = CGRect(x: 0, y: 0, width: 40, height: 10)
    let bigRect = CGRect(x: 0, y: 0, width: 400, height: 300)
    check("corner radius never exceeds half the shorter side", VesperHighlightGeometry.cornerRadius(for: smallRect) == 5)
    check("corner radius is 8 for normal areas", VesperHighlightGeometry.cornerRadius(for: bigRect) == 8)
}

check("one pointed step isn't a walkthrough",
      VesperWalkthroughStepProgress.makeIfWalkthrough(currentStepNumber: 1, totalStepCount: 1) == nil)
check("no step playing yet shows nothing",
      VesperWalkthroughStepProgress.makeIfWalkthrough(currentStepNumber: 0, totalStepCount: 3) == nil)
check("step two of four reads 2/4",
      VesperWalkthroughStepProgress.makeIfWalkthrough(currentStepNumber: 2, totalStepCount: 4)?.chipText == "2/4")

print(failureCount == 0 ? "\n✅ all on-screen guide tests passed" : "\n❌ \(failureCount) on-screen guide test(s) failed")
exit(failureCount == 0 ? 0 : 1)
SWIFT

swiftc -o "$temporary_directory/test-on-screen-guides" \
  "$temporary_directory/main.swift" \
  leanring-buddy/VesperOnScreenGuides.swift
"$temporary_directory/test-on-screen-guides"
