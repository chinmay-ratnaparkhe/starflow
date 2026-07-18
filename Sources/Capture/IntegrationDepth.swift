import Foundation

// MARK: - IntegrationDepth
//
// Pure, deterministic "how deep is this stack?" readout for the session screen.
// Integration time is the honest currency of phone astrophotography: stacking N
// one-second subs cuts noise like one N-second exposure, so minutes integrated —
// not frame counts — is what decides whether faint structure survives.
//
// The tiers are qualitative by design (5 / 15 / 30 minute thresholds, matched to
// what a 1 s / ISO 3200 Milky Way stack actually shows at each depth), and the
// copy stays honest about the measured sky: haze mutes the payoff, an
// overexposed sky caps it, and clouds pause it. Unit-tested in
// Tests/MilkyWaySessionPolishTests.swift.

public enum IntegrationDepth {

    /// Qualitative depth of the current stack.
    public enum Tier: String, Equatable, Sendable, CaseIterable {
        case starting   // < 5 min — signal only beginning to build
        case building   // 5–15 min — bright stars solid, noise still falling
        case good       // 15–30 min — faint arms emerging
        case deep       // ≥ 30 min — extra time buys subtle gains
    }

    /// Tier thresholds in integrated minutes.
    public static let buildingMinutes: Double = 5
    public static let goodMinutes: Double = 15
    public static let deepMinutes: Double = 30

    /// Pure tier lookup from integrated seconds.
    public static func tier(integratedSeconds: Double) -> Tier {
        let minutes = max(0, integratedSeconds) / 60
        if minutes >= deepMinutes { return .deep }
        if minutes >= goodMinutes { return .good }
        if minutes >= buildingMinutes { return .building }
        return .starting
    }

    /// One-line depth readout for the capture phase, honest per the MEASURED
    /// sky condition — the meter must never promise "faint arms" a hazy or
    /// overexposed sky cannot deliver.
    public static func line(integratedSeconds: Double, condition: SkyCondition) -> String {
        if condition == .overexposed {
            return "Depth: limited — the sky background is too bright for faint detail."
        }
        if condition == .cloudy {
            let minutes = Int(max(0, integratedSeconds) / 60)
            return "Depth: \(minutes) min banked — clouds are pausing new signal."
        }
        let base: String
        switch tier(integratedSeconds: integratedSeconds) {
        case .starting: base = "Depth: starting — signal is just beginning to build."
        case .building: base = "Depth: building — bright stars are in, noise still falling."
        case .good:     base = "Depth: good — faint arms emerging."
        case .deep:     base = "Depth: deep — extra time now buys subtle gains."
        }
        if condition == .hazy {
            return base + " Haze is muting the faintest detail."
        }
        return base
    }
}
