import Foundation
import CoreGraphics

// MARK: - SkyCondition

/// Rolling verdict on what the sky actually looks like in the frames we are
/// capturing — measured, never guessed. `.unknown` means the monitor has not
/// yet seen enough starry frames to grade the sky honestly.
public enum SkyCondition: String, Codable, CaseIterable, Equatable, Sendable {
    case unknown
    case clear
    case hazy
    case cloudy
    /// Sustained near-saturation background: city glow / twilight so bright
    /// that faint stars cannot survive, no matter how long we stack.
    case overexposed

    /// Lowercase human word for status lines and the Tonight chip.
    public var displayName: String {
        switch self {
        case .unknown: return "unknown"
        case .clear: return "clear"
        case .hazy: return "hazy"
        case .cloudy: return "cloudy"
        case .overexposed: return "too bright"
        }
    }
}

// MARK: - SkyObservation

/// One frame's worth of measured sky facts: how many stars the detector found
/// and the sigma-clipped background level (0…1), plus when the frame was shot.
/// Produced either by `CPUStacker` as a by-product of stacking, or by
/// `SkyConditionMonitor.measure` for pipelines that do not detect stars.
public struct SkyObservation: Equatable, Sendable {
    public var starCount: Int
    /// Sigma-clipped mean of the frame's luminance (0…1) — the sky background.
    public var backgroundLevel: Double
    public var timestamp: Date

    public init(starCount: Int, backgroundLevel: Double, timestamp: Date) {
        self.starCount = starCount
        self.backgroundLevel = backgroundLevel
        self.timestamp = timestamp
    }
}

// MARK: - SkyConditionMonitor

/// Pure, deterministic sky-condition classifier fed one `SkyObservation` per
/// captured frame. No camera, no clocks, no globals — tests script observation
/// sequences and assert the classification.
///
/// How it decides (heuristics, honestly labelled as such):
///  - A baseline is learned from the best sky seen so far: a high-watermark of
///    the smoothed star count and a low-watermark of the background level.
///  - **overexposed**: background at or above `overexposedBackground` — the
///    sensor is drowning in light regardless of star count.
///  - **cloudy**: star count collapsed to ≤ `cloudyStarFraction` of baseline
///    AND the background rose by ≥ `cloudBackgroundRise` (clouds reflect
///    ground light), or the stars vanished entirely.
///  - **hazy**: star count down to ≤ `hazyStarFraction` of baseline without a
///    full collapse.
///  - **clear**: a healthy fraction of the baseline star count.
///  - Until the baseline has ever held ≥ `minBaselineStars` stars there is no
///    trend to grade against, and the monitor honestly stays `.unknown`
///    (a lunar close-up or an indoor test scene must never read as "cloudy").
///
/// Hysteresis: the published `condition` only changes after `promoteAfter`
/// consecutive frames vote for the same new state, so a single bad frame (a
/// plane, one blurred sub) can never flap the verdict.
public final class SkyConditionMonitor {

    // MARK: Tuning

    public struct Tuning: Sendable {
        /// Background level (0…1) at/above which the sky counts as overexposed.
        public var overexposedBackground: Double = 0.30
        /// Star count ≤ this fraction of baseline counts as a collapse.
        public var cloudyStarFraction: Double = 0.25
        /// Star count ≤ this fraction of baseline (without collapse) is haze.
        public var hazyStarFraction: Double = 0.55
        /// Minimum background rise over baseline for the cloud verdict.
        public var cloudBackgroundRise: Double = 0.015
        /// The baseline must have held at least this many stars before any
        /// grading happens (otherwise `.unknown`).
        public var minBaselineStars: Double = 5
        /// Consecutive identical votes required to change `condition`.
        public var promoteAfter: Int = 3
        /// EMA factor (0…1) for the smoothed star count feeding the baseline.
        public var starSmoothing: Double = 0.3
        public init() {}
    }

    // MARK: State

    public let tuning: Tuning
    public private(set) var condition: SkyCondition = .unknown
    public private(set) var lastObservation: SkyObservation?
    /// Set on every state change; nil until the first transition.
    public private(set) var lastTransition: (from: SkyCondition, to: SkyCondition)?

    /// High-watermark of the smoothed star count (the best sky seen so far).
    public private(set) var baselineStarCount: Double = 0
    /// Low-watermark of the background level (the darkest sky seen so far).
    public private(set) var baselineBackground: Double = 1
    private var smoothedStars: Double = 0
    private var seeded = false
    private var pendingVote: SkyCondition?
    private var pendingCount = 0

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Forget everything — call at session start.
    public func reset() {
        condition = .unknown
        lastObservation = nil
        lastTransition = nil
        baselineStarCount = 0
        baselineBackground = 1
        smoothedStars = 0
        seeded = false
        pendingVote = nil
        pendingCount = 0
    }

    // MARK: Ingest

    /// Feed one frame's observation; returns the (possibly updated) condition.
    @discardableResult
    public func ingest(_ observation: SkyObservation) -> SkyCondition {
        lastObservation = observation
        updateBaseline(with: observation)
        let vote = classify(observation)

        if vote == condition {
            pendingVote = nil
            pendingCount = 0
            return condition
        }
        if vote == pendingVote {
            pendingCount += 1
        } else {
            pendingVote = vote
            pendingCount = 1
        }
        if pendingCount >= tuning.promoteAfter {
            lastTransition = (from: condition, to: vote)
            condition = vote
            pendingVote = nil
            pendingCount = 0
        }
        return condition
    }

    // MARK: Internals

    private func updateBaseline(with obs: SkyObservation) {
        let stars = Double(obs.starCount)
        if !seeded {
            seeded = true
            smoothedStars = stars
        } else {
            smoothedStars += (stars - smoothedStars) * tuning.starSmoothing
        }
        baselineStarCount = max(baselineStarCount, smoothedStars)
        baselineBackground = min(baselineBackground, obs.backgroundLevel)
    }

    /// One frame's raw vote — hysteresis is applied by `ingest`.
    private func classify(_ obs: SkyObservation) -> SkyCondition {
        if obs.backgroundLevel >= tuning.overexposedBackground { return .overexposed }
        guard baselineStarCount >= tuning.minBaselineStars else { return .unknown }
        let ratio = Double(obs.starCount) / baselineStarCount
        let rise = obs.backgroundLevel - baselineBackground
        if ratio <= tuning.cloudyStarFraction,
           rise >= tuning.cloudBackgroundRise || obs.starCount == 0 {
            return .cloudy
        }
        if ratio <= tuning.hazyStarFraction { return .hazy }
        return .clear
    }

    // MARK: Frame measurement (for pipelines without their own star detection)

    /// Measure a frame directly: draw it into a `width`×`height` grayscale grid
    /// and run the same sigma-clipped background estimate and star detector the
    /// stacker uses (`CPUStacker` statics — bit-identical maths). Use the live
    /// stack's grid dimensions so star counts stay comparable with the
    /// stacker's own detection. Returns nil when the frame cannot be decoded
    /// or the grid is too small for the detector.
    public static func measure(image: CGImage, width: Int, height: Int,
                               at time: Date) -> SkyObservation? {
        guard width > 8, height > 8,
              let gray = CPUStacker.grayscaleFloats(from: image, width: width, height: height)
        else { return nil }
        let stats = CPUStacker.clippedStats(gray)
        let stars = CPUStacker.detectStars(in: gray, width: width, height: height)
        return SkyObservation(starCount: stars.count,
                              backgroundLevel: stats.mean,
                              timestamp: time)
    }
}
