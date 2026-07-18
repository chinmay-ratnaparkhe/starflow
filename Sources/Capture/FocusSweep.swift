import Foundation
import CoreGraphics

// MARK: - Focus sweep (star-focus autotune)
//
// Builds on the existing focus telemetry (FocusMetric / RollingSharpness in
// ExposurePlanner.swift): instead of only WATCHING sharpness drift, a sweep
// actively tries a ladder of lens positions near the infinity end of travel,
// scores each on live star frames, and locks the sharpest.
//
// Layering (everything simulator-testable):
//  - `FocusSweepPlan`   — pure math: the position ladders and the peak pick.
//  - `FocusSweep.run`   — the @MainActor sweep driver. It talks to the world
//    only through injected closures (`FocusSweep.IO`), so tests script a lens
//    model, device builds route to the real `AVCaptureDevice` (via
//    `CaptureEngine.setLensPosition`), and simulator builds route to
//    `FocusSweepSimulator` below.
//  - `FocusSweepSimulator` — a synthetic sharpness peak near (not at) infinity,
//    so the whole flow runs end-to-end without camera hardware. Synthetic
//    starfield frames don't defocus, so the simulator must simulate the peak.
//
// Field truth this encodes: stars live at infinity, but on real phone modules
// the sharpest star image often sits a hair INSIDE the infinity hard stop
// (lensPosition slightly below 1.0). The sweep finds that hair; when the curve
// is flat or the signal is weak, it honestly falls back to the 1.0 infinity
// lock the capture engine already applies.

// MARK: - FocusSweepPlan (pure, deterministic)

/// Sweep planning + best-position math. No camera, no clocks — tests feed
/// synthetic score curves and assert the pick.
public struct FocusSweepPlan: Equatable, Sendable {

    /// Infinity end of lens travel (the capture engine's default lock).
    public var upperBound: Double
    /// How far inside the travel the coarse ladder reaches.
    public var lowerBound: Double
    /// Number of coarse positions, upper → lower inclusive.
    public var coarseSteps: Int
    /// Number of fine positions around the coarse best (0 disables refinement).
    public var fineSteps: Int
    /// Half-width of the fine ladder around the coarse best.
    public var fineHalfWidth: Double
    /// Frames scored per position (scores are averaged).
    public var framesPerStep: Int
    /// Frames captured and DISCARDED after each lens move, before scoring. The
    /// device capture loop is sequential and always running: the first frame
    /// delivered after a move was exposed while the lens was still travelling
    /// (or entirely at the previous rung), and scoring it would smear
    /// neighbouring rungs together. 0 disables the settle discard.
    public var settleFramesPerStep: Int
    /// The peak must beat the sweep's weakest score by this ratio to count as a
    /// real peak; anything flatter keeps the infinity default.
    public var minPeakContrast: Double
    /// Minimum stars in the probe frame for a sweep to be worth running.
    public var minProbeStars: Int

    public init(upperBound: Double = 1.0,
                lowerBound: Double = 0.85,
                coarseSteps: Int = 6,
                fineSteps: Int = 5,
                fineHalfWidth: Double = 0.02,
                framesPerStep: Int = 2,
                settleFramesPerStep: Int = 1,
                minPeakContrast: Double = 1.15,
                minProbeStars: Int = 5) {
        self.upperBound = min(1, max(0, upperBound))
        self.lowerBound = min(self.upperBound, max(0, lowerBound))
        self.coarseSteps = max(1, coarseSteps)
        self.fineSteps = max(0, fineSteps)
        self.fineHalfWidth = max(0, fineHalfWidth)
        self.framesPerStep = max(1, framesPerStep)
        self.settleFramesPerStep = max(0, settleFramesPerStep)
        self.minPeakContrast = max(1, minPeakContrast)
        self.minProbeStars = max(0, minProbeStars)
    }

    /// Positions the sweep tries at most (coarse + fine); UI progress totals.
    public var plannedPositions: Int { coarseSteps + fineSteps }

    /// Coarse ladder: `coarseSteps` positions, evenly spaced, descending from
    /// `upperBound` (infinity) to `lowerBound` inclusive.
    public var coarsePositions: [Double] {
        ladder(from: upperBound, to: lowerBound, count: coarseSteps)
    }

    /// Fine ladder: `fineSteps` positions spanning ±`fineHalfWidth` around
    /// `center`, clamped to the sweep bounds, descending.
    public func finePositions(around center: Double) -> [Double] {
        guard fineSteps > 0 else { return [] }
        let hi = min(upperBound, center + fineHalfWidth)
        let lo = max(lowerBound, center - fineHalfWidth)
        return ladder(from: hi, to: lo, count: fineSteps)
    }

    private func ladder(from hi: Double, to lo: Double, count: Int) -> [Double] {
        guard count > 1, hi > lo else { return [hi] }
        let step = (hi - lo) / Double(count - 1)
        return (0..<count).map { hi - Double($0) * step }
    }

    // MARK: Peak pick

    public struct Pick: Equatable, Sendable {
        /// Lens position to lock.
        public var position: Double
        /// False when the curve was flat/degenerate and `position` is just the
        /// infinity default — the honest "no clear peak" outcome.
        public var decisive: Bool
        public init(position: Double, decisive: Bool) {
            self.position = position
            self.decisive = decisive
        }
    }

    /// Best-position math: the highest-scoring position, IF the curve has a
    /// real peak. Flat curves (max/min contrast under `minPeakContrast`),
    /// all-zero scores, and degenerate input all fall back to `upperBound`
    /// (the 1.0 infinity default) with `decisive == false`.
    public func bestPosition(positions: [Double], scores: [Double]) -> Pick {
        guard !positions.isEmpty,
              positions.count == scores.count,
              scores.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let maxScore = scores.max(), maxScore > 0,
              let maxIndex = scores.firstIndex(of: maxScore)
        else { return Pick(position: upperBound, decisive: false) }
        // Contrast gate: a real focus peak towers over the sweep's worst
        // position; noise on a flat curve does not. Rungs that scored 0 carry
        // no information (every frame there was unusable), so the gate compares
        // against the weakest MEASURED rung — a dead rung must never let an
        // otherwise-flat curve pass as decisive.
        if let weakest = scores.filter({ $0 > 0 }).min(),
           maxScore / weakest < minPeakContrast {
            return Pick(position: upperBound, decisive: false)
        }
        return Pick(position: positions[maxIndex], decisive: true)
    }
}

// MARK: - FocusSweepStatus (session-visible state)

/// What the session's focus sweep is doing right now; published by
/// `SessionEngine` so the UI can show progress and the final verdict.
public enum FocusSweepStatus: Equatable, Sendable {
    case inactive
    case running(step: Int, planned: Int)
    /// `decisive == false` means the sweep found no clear peak and kept the
    /// infinity default — worth saying honestly, never worth hiding.
    case locked(position: Double, decisive: Bool)
    case skipped(reason: String)
}

// MARK: - FocusSweep (the sweep driver)

/// Coarse→fine sweep driver. Steps the lens through `FocusSweepPlan`'s ladders,
/// discards `settleFramesPerStep` in-flight frames after each move, scores
/// `framesPerStep` frames per position, and locks the best position —
/// or restores the infinity lock when the curve has no real peak.
/// (`run` is @MainActor; the nested value types stay nonisolated so their
/// Equatable/Sendable conformances are ordinary.)
public enum FocusSweep {

    /// The driver's only view of the world. Device builds wire these to the
    /// real camera; the simulator wires them to `FocusSweepSimulator`; tests
    /// wire them to scripted models.
    public struct IO {
        /// Move the lens (0…1; 1.0 = infinity end) and await the physical move.
        public var setLens: @MainActor (Double) async -> Void
        /// Capture one live frame at the current lens position.
        public var captureFrame: @MainActor () async throws -> SubFrame
        /// Score one frame's star sharpness (higher = sharper); nil = unusable.
        public var score: @MainActor (SubFrame) -> Double?
        /// Progress callback: (1-based step, planned total).
        public var onStep: @MainActor (Int, Int) -> Void

        public init(setLens: @escaping @MainActor (Double) async -> Void,
                    captureFrame: @escaping @MainActor () async throws -> SubFrame,
                    score: @escaping @MainActor (SubFrame) -> Double?,
                    onStep: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) {
            self.setLens = setLens
            self.captureFrame = captureFrame
            self.score = score
            self.onStep = onStep
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// The lens position the sweep left locked.
        public var position: Double
        /// False when no clear peak existed and the infinity default was kept.
        public var decisive: Bool
        /// Positions actually measured (coarse only when the coarse pass was flat).
        public var positionsTried: Int
        /// Best averaged score seen across the sweep.
        public var bestScore: Double
        public init(position: Double, decisive: Bool, positionsTried: Int, bestScore: Double) {
            self.position = position
            self.decisive = decisive
            self.positionsTried = positionsTried
            self.bestScore = bestScore
        }
    }

    /// Run the sweep. Throws only what `io.captureFrame` throws (plus task
    /// cancellation); on every return path the lens has been left at the
    /// outcome position — infinity when nothing decisive was found.
    @MainActor
    public static func run(plan: FocusSweepPlan, io: IO) async throws -> Outcome {
        let planned = plan.plannedPositions

        // Measure one ladder: `framesPerStep` frames per rung, scores averaged
        // (unusable frames simply don't count; an all-unusable rung scores 0).
        func sample(_ ladder: [Double], startingStep: Int) async throws
            -> (positions: [Double], scores: [Double]) {
            var positions: [Double] = []
            var scores: [Double] = []
            for (offset, position) in ladder.enumerated() {
                try Task.checkCancellation()
                io.onStep(startingStep + offset, planned)
                await io.setLens(position)
                // Settle discard: the sequential capture loop keeps exposing
                // while the lens moves, so the first frame(s) delivered after a
                // move saw the PREVIOUS rung (or a lens in flight). Burn them —
                // every scored frame must genuinely have been exposed here.
                for _ in 0..<plan.settleFramesPerStep {
                    _ = try await io.captureFrame()
                }
                var total = 0.0
                var counted = 0
                for _ in 0..<plan.framesPerStep {
                    let frame = try await io.captureFrame()
                    if let s = io.score(frame), s.isFinite, s >= 0 {
                        total += s
                        counted += 1
                    }
                }
                positions.append(position)
                scores.append(counted > 0 ? total / Double(counted) : 0)
            }
            return (positions, scores)
        }

        let coarse = try await sample(plan.coarsePositions, startingStep: 1)
        let coarsePick = plan.bestPosition(positions: coarse.positions, scores: coarse.scores)
        guard coarsePick.decisive else {
            // Flat or unusable curve: restore the infinity lock and say so.
            await io.setLens(plan.upperBound)
            return Outcome(position: plan.upperBound, decisive: false,
                           positionsTried: coarse.positions.count,
                           bestScore: coarse.scores.max() ?? 0)
        }
        let fine = try await sample(plan.finePositions(around: coarsePick.position),
                                    startingStep: coarse.positions.count + 1)
        let positions = coarse.positions + fine.positions
        let scores = coarse.scores + fine.scores
        let pick = plan.bestPosition(positions: positions, scores: scores)
        await io.setLens(pick.position)
        return Outcome(position: pick.position, decisive: pick.decisive,
                       positionsTried: positions.count, bestScore: scores.max() ?? 0)
    }
}

// MARK: - FocusSweepSimulator (simulator / dev focus model)

/// Simulated lens + sharpness model: a smooth variance-of-Laplacian-like peak
/// slightly inside the infinity stop, with mild deterministic noise. Simulator
/// builds route the session's focus hooks here because synthetic starfield
/// frames never defocus — without a model there would be no peak to find and
/// the sweep flow could never be demonstrated off-device.
///
/// The same instance also serves the live focus chip: `tick()` records one
/// sample per captured frame into a `RollingSharpness` window, so the meter
/// and the drift alarm use exactly the shipped telemetry code path.
public final class FocusSweepSimulator {

    public private(set) var lensPosition: Double
    /// Where the model's sharpness peak sits (a hair inside infinity).
    public let peakPosition: Double

    private let baseScore: Double
    private let peakGain: Double
    private let sigma: Double
    private let noiseFraction: Double
    private var noiseState: UInt64
    private var window = RollingSharpness(window: 10)

    public init(peakPosition: Double = 0.94,
                startPosition: Double = 1.0,
                baseScore: Double = 60,
                peakGain: Double = 420,
                sigma: Double = 0.035,
                noiseFraction: Double = 0.03,
                seed: UInt64 = 0x0F0C_0505_F0CA_15ED) {
        self.peakPosition = min(1, max(0, peakPosition))
        self.lensPosition = min(1, max(0, startPosition))
        self.baseScore = max(0, baseScore)
        self.peakGain = max(0, peakGain)
        self.sigma = max(1e-6, sigma)
        self.noiseFraction = max(0, noiseFraction)
        self.noiseState = seed
    }

    public func setLens(_ position: Double) {
        lensPosition = min(1, max(0, position))
    }

    /// Sharpness the model reports at the current lens position (noise included).
    @discardableResult
    public func score() -> Double {
        let d = lensPosition - peakPosition
        let clean = baseScore + peakGain * exp(-(d * d) / (2 * sigma * sigma))
        let sample = max(0, clean * (1 + noiseFraction * nextUniform()))
        window.record(sample)
        return sample
    }

    /// One capture tick for the live focus chip: record a sample at the current
    /// lens position and report the rolling telemetry.
    public func tick() -> (sharpness: Double?, mean: Double?, drifting: Bool) {
        score()
        return (window.latest, window.mean, window.isDegraded())
    }

    /// Deterministic uniform noise in -1…1 (SplitMix64).
    private func nextUniform() -> Double {
        noiseState &+= 0x9E37_79B9_7F4A_7C15
        var z = noiseState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) * (2.0 / 9_007_199_254_740_992.0) - 1.0
    }
}
