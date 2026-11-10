import Foundation
import OutboundCore
import Testing

/// The gull flies along its heading, so it curves where it used to spin, and takes its time unless it has reason not to.
@Suite
struct BirdTests {
    private let frame = 1.0 / 30

    private func speed(_ bird: Bird) -> Double {
        (bird.velocity.x * bird.velocity.x + bird.velocity.y * bird.velocity.y).squareRoot()
    }

    private func turn(from a: Double, to b: Double) -> Double {
        abs(atan2(sin(b - a), cos(b - a)))
    }

    /// As when the cursor passes behind it, which used to flip it round on the spot.
    @Test func comesRoundInAnArcWhenWhatItWantsIsBehindIt() {
        var bird = Bird(at: SIMD2(0, 0))
        var path = 0.0
        for _ in 0..<(30 * 8) {
            let before = bird.heading
            bird.step(dt: frame, towards: SIMD2(-800, 1))
            #expect(turn(from: before, to: bird.heading) <= Bird.sharpestTurn * frame + 1e-9)
            path += speed(bird) * frame
        }
        #expect(path > 100)
        #expect(cos(bird.heading) < -0.5, "it has come round to the west")
    }

    @Test func banksIntoTheTurnAndLevelsOut() {
        var bird = Bird(at: SIMD2(0, 0))
        // North of it, to its left.
        for _ in 0..<30 { bird.step(dt: frame, towards: SIMD2(40, 900)) }
        #expect(bird.bank < -0.1)
        for _ in 0..<(30 * 6) { bird.step(dt: frame, towards: SIMD2(40, 5000)) }
        #expect(abs(bird.bank) < 0.1)
    }

    @Test func settlesIntoAWideCircleRoundAStillCursor() {
        var bird = Bird(at: SIMD2(0, 0))
        let target = SIMD2<Double>(600, 300)
        for _ in 0..<(30 * 40) { bird.step(dt: frame, towards: target) }
        for _ in 0..<(30 * 30) {
            bird.step(dt: frame, towards: target)
            let d = bird.position - target
            let distance = (d.x * d.x + d.y * d.y).squareRoot()
            #expect(abs(distance - Bird.orbit) < Bird.orbit * 0.25)
            #expect(speed(bird) <= Bird.cruise + 1)
        }
    }

    @Test func hurriesOnlyWhenChasing() {
        var chasing = Bird(at: SIMD2(0, 0)), wandering = chasing
        var fastest = 0.0
        for _ in 0..<(30 * 20) {
            chasing.step(dt: frame, towards: SIMD2(50000, 0))
            wandering.step(dt: frame, towards: SIMD2(50000, 0), hurrying: false)
            #expect(speed(wandering) <= Bird.cruise + 1e-9)
            fastest = max(fastest, speed(chasing))
        }
        #expect(fastest > Bird.cruise * 2 && fastest <= Bird.topSpeed + 1e-9)
    }

    @Test func fliesMuchTheSameAtAnyFrameRate() {
        func flown(_ rate: Double) -> SIMD2<Double> {
            var bird = Bird(at: SIMD2(0, 0))
            for step in 0..<Int(10 * rate) {
                let t = Double(step) / rate
                bird.step(dt: 1 / rate, towards: SIMD2(300 * cos(t * 0.4), 300 * sin(t * 0.4) + 200))
            }
            return bird.position
        }
        let gap = flown(30) - flown(120)
        #expect((gap.x * gap.x + gap.y * gap.y).squareRoot() < 6)
    }

    @Test func finishesItsWingbeatsWithItsWingsOpen() {
        var bird = Bird(at: SIMD2(0, 0))
        var beating = false, sawOpenAgain = false
        for _ in 0..<(30 * 30) {
            let before = bird.wings
            bird.step(dt: frame, towards: SIMD2(50000, 0))
            #expect(abs(bird.wings - before) < 0.2, "the wings never jump")
            if bird.wings < 0.9 { beating = true } else if beating { sawOpenAgain = true }
        }
        #expect(sawOpenAgain)
    }

    /// A bird 1.6 saved part way through a flap opens its wings smoothly as it carries on, rather than holding them half
    /// closed for a while and then snapping them open.
    @Test func aBirdSavedMidBeatByAnEarlierVersionFinishesTheBeat() throws {
        let saved: [String: Any] = [
            "position": [1325.98, 473.9], "velocity": [70, 0], "heading": 0, "bank": 0, "wings": 0.2,
            "steer": ["value": [70, 0], "halflife": 0.45, "velocity": [0, 0]],
            "banking": ["value": [0, 0], "halflife": 0.35, "velocity": [0, 0]],
            "gliding": 0, "orbitDirection": 1, "flapPhase": 9.7, "flapping": 0.6,
        ]
        var bird = try JSONDecoder().decode(Bird.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(abs(bird.wings - 0.2) < 1e-9)
        var last = bird.wings
        for _ in 0..<30 {
            bird.step(dt: frame, towards: SIMD2(1400, 500), hurrying: false)
            #expect(abs(bird.wings - last) <= 0.2)
            last = bird.wings
        }
        #expect(bird.wings == 1)
    }

    /// The loop it wanders when nobody is pointing never goes faster than it can follow at its easy pace, and over a
    /// laptop's display it is just as it was.
    @Test(arguments: [[1512.0, 982], [2560, 1440], [3008, 1692], [1440, 2560], [6016, 3384]])
    func theWanderLoopNeverOutrunsTheBird(size: [Double]) {
        let area = CGRect(x: 0, y: 0, width: size[0], height: size[1])
        var fastest = 0.0
        var last = Bird.wander(in: area, time: 0)
        for t in stride(from: 0.1, to: 3000, by: 0.1) {
            let here = Bird.wander(in: area, time: t)
            let moved = here - last
            fastest = max(fastest, (moved.x * moved.x + moved.y * moved.y).squareRoot() / 0.1)
            last = here
        }
        #expect(fastest <= Bird.wanderPace + 0.5)
        #expect(Bird.wanderPace < Bird.cruise)
        if size[0] == 1512 {
            let t = 123.4, w = 1512.0, h = 982.0
            let before = SIMD2(w / 2 + w * 0.3 * sin(t * 0.036) + w * 0.08 * sin(t * 0.11),
                               h / 2 + h * 0.26 * sin(t * 0.027 + 1.1) + h * 0.07 * cos(t * 0.095))
            let now = Bird.wander(in: area, time: t)
            #expect(abs(now.x - before.x) < 1e-9 && abs(now.y - before.y) < 1e-9)
        }
    }

    /// Saved moments are kept across an update, so the bird in one from before must still load.
    @Test func aBirdSavedByAnEarlierVersionStillLoads() throws {
        var bird = Bird(at: SIMD2(120, 80))
        for _ in 0..<60 { bird.step(dt: frame, towards: SIMD2(400, 400)) }
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bird)) as? [String: Any])
        saved["turning"] = nil
        saved["beats"] = nil
        saved["steer"] = ["value": [1, 2], "velocity": [0, 0], "halflife": 0.45]
        saved["flapping"] = 0.0
        let loaded = try JSONDecoder().decode(Bird.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(loaded.pose == bird.pose)
    }
}
