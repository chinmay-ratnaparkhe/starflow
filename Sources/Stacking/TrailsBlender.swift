import Foundation
import CoreGraphics
import Accelerate

/// Star-trails accumulator (see docs/DESIGN.md — Modes: StarTrails).
///
/// Lighten (per-pixel max) blend: every accepted frame contributes its brightest
/// pixels, so stars drag arcs across the canvas as the sky rotates while the
/// static foreground stays put. There is deliberately no registration step —
/// for trails the motion IS the shot; the gimbal's only job is to hold still.
///
/// Reuses CPUStacker's public buffer utilities (grayscale ingest, clipped
/// background statistics, gray CGImage output), so both stackers rescale input
/// frames into the same `reset` grid and a reduced-resolution live blend of
/// full-size photos is supported.
///
/// Rejection is intentionally lenient: registration failures cannot exist here,
/// so a frame only bounces when it cannot be decoded or when its sigma-clipped
/// background jumps far above the first accepted frame's (headlights sweeping
/// the lens, a hand in front of the phone) — one such frame would permanently
/// wash the max buffer.
public final class TrailsBlender: Stacking {

    // MARK: - Tunables (fixed for v1)

    /// Background rise (0…1 gray units) above the reference frame that rejects a frame.
    private let maxBackgroundJump: Float = 0.2

    // MARK: - State

    private let lock = NSLock()
    private var width = 0
    private var height = 0
    private var maxBuf: [Float] = []
    private var referenceBackground: Float?
    private var backgroundJumpStreak = 0
    private var acceptedCount = 0
    private var rejectedCount = 0
    private var integration: Double = 0

    public init() {}

    // MARK: - Stacking conformance

    public func reset(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        self.width = max(0, width)
        self.height = max(0, height)
        maxBuf = [Float](repeating: 0, count: self.width * self.height)
        referenceBackground = nil
        acceptedCount = 0
        rejectedCount = 0
        integration = 0
    }

    /// Returns false when the frame is rejected (undecodable, or washed out far
    /// above the reference background). Input frames of any resolution are
    /// rescaled into the `reset` grid.
    public func add(frame: SubFrame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard width > 0, height > 0,
              let image = frame.pixelData,
              let gray = CPUStacker.grayscaleFloats(from: image, width: width, height: height) else {
            rejectedCount += 1
            return false
        }

        let background = Float(CPUStacker.clippedStats(gray).mean)
        if let reference = referenceBackground, background - reference > maxBackgroundJump {
            // Exposure settling (first frames) or a genuine scene change must not
            // poison the whole session: tolerate the guard early, and re-seed the
            // reference after 3 consecutive jumps instead of rejecting forever.
            backgroundJumpStreak += 1
            if acceptedCount > 10 && backgroundJumpStreak < 3 {
                rejectedCount += 1
                return false
            }
            referenceBackground = background
            backgroundJumpStreak = 0
        } else {
            backgroundJumpStreak = 0
        }
        if referenceBackground == nil { referenceBackground = background }

        // Lighten accumulate: maxBuf = max(maxBuf, gray), element-wise.
        let count = vDSP_Length(maxBuf.count)
        gray.withUnsafeBufferPointer { g in
            maxBuf.withUnsafeMutableBufferPointer { m in
                guard let gBase = g.baseAddress, let mBase = m.baseAddress else { return }
                vDSP_vmax(gBase, 1, mBase, 1, mBase, 1, count)
            }
        }
        acceptedCount += 1
        integration += max(0, frame.exposureSeconds)
        return true
    }

    public func currentResult() -> StackResult {
        lock.lock(); defer { lock.unlock() }
        return StackResult(accepted: acceptedCount,
                           rejected: rejectedCount,
                           integrationSeconds: integration,
                           preview: previewLocked())
    }

    public func finalImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return previewLocked()
    }

    // MARK: - Extra accessors (tests, session telemetry)

    /// Copy of the accumulated lighten-blend buffer (row-major, 0…1).
    public func accumulatedMax() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return maxBuf
    }

    public func dimensions() -> (width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        return (width, height)
    }

    // MARK: - Preview

    /// Trails need no stretch: the max buffer already holds each star's full
    /// single-frame brightness along its whole arc, so it maps to gray directly.
    private func previewLocked() -> CGImage? {
        guard acceptedCount > 0, width > 0, height > 0 else { return nil }
        return CPUStacker.grayImage(from: maxBuf, width: width, height: height)
    }
}
