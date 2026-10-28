import Testing
@testable import OutboundCore

/// The landscape's rate: even on the panel, never well over its target, never under 24.
@Suite
struct FramePacingTests {
    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    @Test func theLandscapeTakesTheRateBelowWhenTheOneAboveIsWellOver() {
        let cases: [(target: Double, refresh: Double, expected: Double)] = [
            // 37.5 is a quarter over 30; 25 is still smooth.
            (30, 75, 25), (30, 74.97, 24.99),
            // Within a fifth over, or already even: as before.
            (30, 60, 30), (30, 120, 30), (30, 144, 36), (30, 165, 33), (30, 100, 100.0 / 3), (30, 50, 25),
            // 20 would be too few, so 60 Hz keeps 30 for a target of 24.
            (24, 60, 30), (24, 75, 25), (24, 165, 27.5), (24, 144, 24),
        ]
        for c in cases {
            let rate = FramePacing.rate(target: c.target, fastest: c.refresh, lowest: 24)
            #expect(near(rate, c.expected), "\(c.target) on \(c.refresh) Hz gave \(rate)")
        }
        // Without a floor, as the bird's layer asks, nothing changes.
        #expect(near(FramePacing.rate(target: 30, fastest: 75), 37.5))
        #expect(near(FramePacing.rate(target: 60, fastest: 75), 75))
        // ProMotion shows the target itself.
        #expect(FramePacing.rate(target: 30, fastest: 120, slowest: 24, lowest: 24) == 30)
    }
}
