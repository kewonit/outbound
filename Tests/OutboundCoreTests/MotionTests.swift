import CoreGraphics
import Foundation
import Testing
@testable import OutboundCore

struct SpringTests {
    @Test func settlesTheSameAtAnyFrameRate() {
        var results: [Double] = []
        for fps in [15.0, 25.0, 30.0, 120.0] {
            var spring = Spring(SIMD2<Double>(0, 0), halflife: 0.3)
            for _ in 0..<Int(fps) { spring.step(towards: SIMD2(100, 0), dt: 1 / fps) }
            results.append(spring.value.x)
        }
        for r in results { #expect(abs(r - results[0]) < 0.01) }
        #expect(results[0] > 90 && results[0] <= 100)
    }

    @Test func halflifeHalvesTheGap() {
        var spring = Spring(SIMD2<Double>(0, 0), halflife: 0.5)
        for _ in 0..<500 { spring.step(towards: SIMD2(100, 0), dt: 0.001) }
        #expect(abs(spring.value.x - 50) < 12)
    }
}

struct BirdTests {
    @Test func neverStallsInTheAir() {
        var bird = Bird(at: SIMD2(500, 500))
        for _ in 0..<600 {
            bird.step(dt: 1 / 30, towards: SIMD2(500, 500))
            let speed = (bird.velocity.x * bird.velocity.x + bird.velocity.y * bird.velocity.y).squareRoot()
            #expect(speed >= Bird.slowest - 1e-6)
        }
    }

    @Test func circlesAStillCursor() {
        var bird = Bird(at: SIMD2(0, 0))
        let target = SIMD2<Double>(600, 300)
        for _ in 0..<(30 * 20) { bird.step(dt: 1 / 30, towards: target) }
        var furthest = 0.0
        for _ in 0..<(30 * 6) {
            bird.step(dt: 1 / 30, towards: target)
            let d = bird.position - target
            furthest = max(furthest, (d.x * d.x + d.y * d.y).squareRoot())
        }
        #expect(furthest < Bird.orbit * 2.5)
    }

    @Test func survivesLongPauses() {
        var bird = Bird(at: SIMD2(0, 0))
        bird.step(dt: 3600, towards: SIMD2(100, 100))
        #expect(bird.position.x.isFinite && abs(bird.position.x) < 1000)
    }

    @Test func wandersInsideTheArea() {
        let area = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for t in stride(from: 0.0, to: 3600, by: 7) {
            let p = Bird.wander(in: area, time: t)
            #expect(area.insetBy(dx: -1, dy: -1).contains(CGPoint(x: p.x, y: p.y)))
        }
    }
}

struct SunTests {
    @Test func noonIsHighAtTheEquinox() {
        let sun = Sun(latitude: 0, dayOfYear: 80, solarHour: 12)
        #expect(sun.elevation > 1.5)
        #expect(sun.night == 0)
    }

    @Test func midnightIsNight() {
        let sun = Sun(latitude: 40, dayOfYear: 172, solarHour: 0)
        #expect(sun.elevation < 0)
        #expect(sun.night > 0.9)
    }

    @Test func morningSunIsInTheEast() {
        let sun = Sun(latitude: 40, dayOfYear: 172, solarHour: 8)
        #expect(sun.direction.x > 0.5)
    }

    @Test func midsummerNightInLaplandStaysLight() {
        let sun = Sun(latitude: 67.1, dayOfYear: 172, solarHour: 0)
        #expect(sun.elevation > 0)
    }
}

struct AmbientTests {
    @Test func trainsPassWhileTheLineIsOnScreen() {
        let place = Place.named("lisse")!
        let railway = place.railway!
        let line = RailLine(origin: SIMD2(400, 2000), angle: 0.6, amplitude: 0, wavelength: 1000, phase: 0)
        // The screen's middle drifts sideways as it flies north, and crosses the line once.
        let path = { (t: TimeInterval) in SIMD2(450 + 60 * sin(t / 70), 6.5 * t) }
        let crossing = line.crossing(near: 100, path: path)!
        #expect(abs(line.across(path(crossing.time))) < 0.1)
        var seen = 0
        for t in stride(from: 0.0, to: 700, by: 5) {
            if let run = line.train(at: t, crossing: crossing.time, middle: crossing.along, railway: railway, seed: 3) {
                seen += 1
                #expect(abs(run.head - crossing.along) < 2000)
            }
        }
        #expect(seen > 0 && seen < 140)
        // At the crossing the nose is exactly where the middle of the screen meets the line.
        if let run = line.train(at: crossing.time, crossing: crossing.time, middle: crossing.along, railway: railway, seed: 3) {
            #expect(abs(run.head - crossing.along) < 1e-9)
        }
    }

    @Test func flocksCrossAndLeave() {
        let area = CGRect(x: 0, y: 0, width: 1512, height: 982)
        var appearances = 0
        var wasVisible = false
        for t in stride(from: 0.0, to: 7200, by: 2) {
            let visible = Flock.geese.sighting(at: t, area: area, seed: 1) != nil
            if visible && !wasVisible { appearances += 1 }
            wasVisible = visible
        }
        // About one flight every nine minutes over two hours.
        #expect(appearances >= 5 && appearances <= 20)
    }

    @Test func flocksDependOnPlaceAndMonth() {
        #expect(Flock.of(Place.named("niigata")!, month: 1)?.color == Flock.swans.color)
        #expect(Flock.of(Place.named("pampa")!, month: 6)?.formation == .skein)
        #expect(Flock.of(Place.named("kansas")!, month: 7) == nil)
    }

    @Test func railLinesAreDeterministic() {
        let journey = Journey(start: Place.named("lisse")!, time: 0)
        let leg = journey.legs[0]
        #expect(RailLine.line(for: leg, riverX: 400, legLength: 4000) == RailLine.line(for: leg, riverX: 400, legLength: 4000))
    }
}
