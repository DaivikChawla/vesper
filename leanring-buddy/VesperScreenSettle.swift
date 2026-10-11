//
//  VesperScreenSettle.swift
//  leanring-buddy
//
//  When has the screen finished reacting to what she just did? Between
//  hands-on steps she waits for that before taking the next screenshot:
//  too early and Claude sees the old page (and clicks the wrong thing, or
//  spends a whole step on [WAIT]); too late and every step drags.
//
//  The old rule was "two matching tiny snapshots after 0.4 s". In the
//  logs nearly every click "settled" at that minimum (0.62–0.72 s), often
//  before a page had even started to change, and a page with a playing
//  video never settled at all (its frames never match). So:
//  - after a click, Return or a shortcut, wait to see the screen actually
//    change (compared to just before the action) — or, if nothing changes
//    within 1.3 s, accept that nothing visible happened;
//  - then wait for it to be still for a moment;
//  - and ignore spots that never stop moving (a playing video, a spinner):
//    pixels that changed in 8 of the last 10 snapshots don't count.
//
//  Fingerprints are the 64×40 grayscale thumbnails from
//  CompanionScreenCaptureUtility, taken every 120 ms, without the mouse
//  pointer. This file is plain math, so scripts/test-screen-settle.sh
//  checks it with made-up screens.
//

import Foundation

/// What the step's last action should do to the screen, which decides
/// how she waits before looking again.
nonisolated enum VesperScreenSettleExpectation: String, Equatable, Sendable {
    /// Typing, plain keys, a scroll: the effect is immediate.
    case immediateEffect
    /// A click, Return or a shortcut: a page may load or a dialog open,
    /// sometimes only after a moment.
    case mayChangeScreen
    /// She opened a site or an app: it takes a while to appear.
    case openedSomething
    /// She already waited on purpose ([WAIT]).
    case afterExplicitWait
}

nonisolated struct VesperScreenSettlePlan: Equatable, Sendable {
    /// Nothing counts as settled before this.
    let minimumSeconds: TimeInterval
    /// How long the screen must stay still (outside spots that never stop).
    let stillnessSeconds: TimeInterval
    /// For actions that should change the screen: wait until a change has
    /// been seen, or this long has passed without one. Nil: no change needed.
    let waitForChangeSeconds: TimeInterval?
    /// Never wait longer than this; she looks anyway.
    let maximumSeconds: TimeInterval

    static func plan(for expectation: VesperScreenSettleExpectation) -> VesperScreenSettlePlan {
        switch expectation {
        case .immediateEffect:
            return VesperScreenSettlePlan(minimumSeconds: 0.15, stillnessSeconds: 0.36, waitForChangeSeconds: nil, maximumSeconds: 1.5)
        case .mayChangeScreen:
            return VesperScreenSettlePlan(minimumSeconds: 0.15, stillnessSeconds: 0.48, waitForChangeSeconds: 1.3, maximumSeconds: 3.5)
        case .openedSomething:
            return VesperScreenSettlePlan(minimumSeconds: 0.3, stillnessSeconds: 0.6, waitForChangeSeconds: 3.0, maximumSeconds: 6.0)
        case .afterExplicitWait:
            return VesperScreenSettlePlan(minimumSeconds: 0, stillnessSeconds: 0.36, waitForChangeSeconds: nil, maximumSeconds: 2.0)
        }
    }
}

nonisolated struct VesperScreenSettleDetector {
    enum Verdict: Equatable {
        case keepWaiting
        case settled
        /// The maximum passed while the screen was still changing.
        case gaveUp
    }

    /// A pixel (0–255 gray) "changed" when it moved more than this.
    static let pixelChangeThreshold = 10
    /// A snapshot counts as still with at most this many changed pixels
    /// (of 2,560) outside the spots that never stop: a blinking text
    /// cursor or a tiny spinner.
    static let maximumMovingPixelsWhenStill = 6
    /// Spots that never stop: changed in this many of the last snapshots.
    static let recentSnapshotCount = 10
    static let changesThatMarkASpotAnimated = 8
    /// The action "changed the screen" once this share of pixels differs
    /// from just before it (half a percent: a menu opening, a page, a
    /// message appearing; not a button's hover tint).
    static let changedShareThatCountsAsChange = 0.005

    let plan: VesperScreenSettlePlan
    private let baselineFingerprint: [UInt8]?
    /// Moving spots learned by the previous wait (a video playing before
    /// the action), used until this wait has seen enough snapshots itself.
    private let previouslyAnimatedPixelMask: [Bool]?
    private var recentChangeMasks: [[Bool]] = []
    private var previousFingerprint: [UInt8]?
    private var previousSampleSeconds: TimeInterval?
    private var stillSinceSeconds: TimeInterval?

    /// When the screen was first seen to differ from before the action.
    private(set) var changeSeenAtSeconds: TimeInterval?
    /// For the log, so the thresholds can be tuned from real numbers.
    private(set) var movingPixelCountHistory: [Int] = []
    private(set) var largestChangedShareFromBaseline: Double = 0
    private(set) var animatedPixelCount = 0

    init(plan: VesperScreenSettlePlan, baselineFingerprint: [UInt8]?, previouslyAnimatedPixelMask: [Bool]? = nil) {
        self.plan = plan
        self.baselineFingerprint = baselineFingerprint
        self.previouslyAnimatedPixelMask = previouslyAnimatedPixelMask
    }

    /// The moving spots as of now, for the next wait to start from.
    var animatedPixelMask: [Bool] {
        guard let previousFingerprint else { return previouslyAnimatedPixelMask ?? [] }
        return currentAnimatedPixelMask(pixelCount: previousFingerprint.count)
    }

    mutating func addSample(_ fingerprint: [UInt8], atSeconds sampleSeconds: TimeInterval) -> Verdict {
        defer {
            previousFingerprint = fingerprint
            previousSampleSeconds = sampleSeconds
        }

        if let previousFingerprint, previousFingerprint.count == fingerprint.count {
            var changedPixelMask = [Bool](repeating: false, count: fingerprint.count)
            for pixelIndex in fingerprint.indices {
                changedPixelMask[pixelIndex] = abs(Int(fingerprint[pixelIndex]) - Int(previousFingerprint[pixelIndex])) > Self.pixelChangeThreshold
            }
            recentChangeMasks.append(changedPixelMask)
            if recentChangeMasks.count > Self.recentSnapshotCount {
                recentChangeMasks.removeFirst()
            }

            let animatedMask = currentAnimatedPixelMask(pixelCount: fingerprint.count)
            animatedPixelCount = animatedMask.filter { $0 }.count
            var movingPixelCount = 0
            for pixelIndex in fingerprint.indices where changedPixelMask[pixelIndex] && !animatedMask[pixelIndex] {
                movingPixelCount += 1
            }
            movingPixelCountHistory.append(movingPixelCount)

            if movingPixelCount <= Self.maximumMovingPixelsWhenStill {
                if stillSinceSeconds == nil {
                    // Still since the previous snapshot, at least.
                    stillSinceSeconds = previousSampleSeconds ?? sampleSeconds
                }
            } else {
                stillSinceSeconds = nil
            }
            noteChangeFromBaseline(fingerprint, animatedMask: animatedMask, atSeconds: sampleSeconds)
        } else {
            noteChangeFromBaseline(fingerprint, animatedMask: previouslyAnimatedPixelMask ?? [], atSeconds: sampleSeconds)
        }

        if isSettled(atSeconds: sampleSeconds) {
            return .settled
        }
        return sampleSeconds >= plan.maximumSeconds ? .gaveUp : .keepWaiting
    }

    private func isSettled(atSeconds sampleSeconds: TimeInterval) -> Bool {
        guard sampleSeconds >= plan.minimumSeconds, let stillSinceSeconds else { return false }
        // Without a "before" snapshot there's nothing to compare a change
        // against, so stillness alone decides.
        if let waitForChangeSeconds = plan.waitForChangeSeconds, baselineFingerprint != nil {
            let hasChangeHappenedOrTimedOut = changeSeenAtSeconds != nil || sampleSeconds >= waitForChangeSeconds
            guard hasChangeHappenedOrTimedOut else { return false }
        }
        // A small tolerance: snapshots come every ~120 ms, not exactly.
        return sampleSeconds - stillSinceSeconds >= plan.stillnessSeconds - 0.02
    }

    private mutating func noteChangeFromBaseline(_ fingerprint: [UInt8], animatedMask: [Bool], atSeconds sampleSeconds: TimeInterval) {
        guard changeSeenAtSeconds == nil, let baselineFingerprint, baselineFingerprint.count == fingerprint.count, !fingerprint.isEmpty else { return }
        var changedPixelCount = 0
        for pixelIndex in fingerprint.indices {
            let isAnimated = pixelIndex < animatedMask.count && animatedMask[pixelIndex]
            if !isAnimated && abs(Int(fingerprint[pixelIndex]) - Int(baselineFingerprint[pixelIndex])) > Self.pixelChangeThreshold + 2 {
                changedPixelCount += 1
            }
        }
        let changedShare = Double(changedPixelCount) / Double(fingerprint.count)
        largestChangedShareFromBaseline = max(largestChangedShareFromBaseline, changedShare)
        if changedShare >= Self.changedShareThatCountsAsChange {
            changeSeenAtSeconds = sampleSeconds
        }
    }

    private func currentAnimatedPixelMask(pixelCount: Int) -> [Bool] {
        var animatedMask = [Bool](repeating: false, count: pixelCount)
        if recentChangeMasks.count >= Self.changesThatMarkASpotAnimated {
            for pixelIndex in 0..<pixelCount {
                var changeCount = 0
                for changeMask in recentChangeMasks where pixelIndex < changeMask.count && changeMask[pixelIndex] {
                    changeCount += 1
                }
                animatedMask[pixelIndex] = changeCount >= Self.changesThatMarkASpotAnimated
            }
        }
        // Until this wait has seen enough snapshots, trust what the last
        // one learned (a video that was already playing).
        if recentChangeMasks.count < Self.recentSnapshotCount, let previouslyAnimatedPixelMask, previouslyAnimatedPixelMask.count == pixelCount {
            for pixelIndex in 0..<pixelCount where previouslyAnimatedPixelMask[pixelIndex] {
                animatedMask[pixelIndex] = true
            }
        }
        return animatedMask
    }

    /// "change seen at 0.36s · moving 812,40,3,0,0,1 · animated 140 px ·
    /// baseline share 0.214" for the log.
    var diagnosticSummary: String {
        let changeText = changeSeenAtSeconds.map { String(format: "change seen at %.2fs", $0) }
            ?? (baselineFingerprint == nil ? "no before-snapshot" : "no change seen")
        let movingText = movingPixelCountHistory.suffix(12).map(String.init).joined(separator: ",")
        return String(format: "%@ · moving %@ · animated %d px · largest change %.3f", changeText, movingText, animatedPixelCount, largestChangedShareFromBaseline)
    }
}
