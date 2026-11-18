import CoreGraphics
import Foundation
import OutboundCore
import Testing
@testable import Outbound

/// Flying straight stops the sideways drift where it is, gently, and starting it again picks up from there.
@Suite
struct StraightFlightTests {
    /// The drift's two waves at their fastest together, in metres a second sideways.
    static let peak = 70 * 2 * Double.pi / 430 + 24 * 2 * Double.pi / 163
    static let frame = 1.0 / 30

    private func journey() -> Journey {
        Journey(start: .first, time: 0, speed: 1.4, legLength: 1.4 * 60 * 20)
    }

    /// The fastest the camera moves sideways between frames from `start` for `seconds`.
    private func fastest(_ journey: Journey, from start: Double, for seconds: Double) -> Double {
        stride(from: start, to: start + seconds, by: Self.frame).map {
            abs(journey.cameraX(at: $0 + Self.frame) - journey.cameraX(at: $0)) / Self.frame
        }.max() ?? 0
    }

    @Test func itSlowsToAStopWhereItIs() {
        let journey = journey()
        let start = 1000.0
        let before = journey.cameraX(at: start)
        journey.fliesStraight(true, at: start)
        #expect(journey.fliesStraight)
        #expect(abs(journey.cameraX(at: start) - before) < 1e-9)
        #expect(fastest(journey, from: start - 1, for: 12) <= Self.peak)
        // Stopped once the ease is over, a few metres from where it was rather than back in the middle.
        let stopped = journey.cameraX(at: start + Journey.driftEase)
        #expect(abs(stopped - before) < Self.peak * Journey.driftEase / 2 + 1e-9)
        #expect(journey.cameraX(at: start + 600) == stopped)
        #expect(journey.cameraX(at: start + 86400) == stopped)
    }

    @Test func itPicksUpAgainFromWhereItStopped() {
        let journey = journey()
        journey.fliesStraight(true, at: 500)
        let stopped = journey.cameraX(at: 900)
        journey.fliesStraight(false, at: 900)
        #expect(!journey.fliesStraight)
        #expect(abs(journey.cameraX(at: 900) - stopped) < 1e-9)
        #expect(fastest(journey, from: 899, for: 600) <= Self.peak)
        // Up to its usual pace by the end of the ease: the drift's waves again, a little later along them.
        #expect(journey.cameraX(at: 1100) != stopped)
    }

    /// Changing its mind halfway through, the camera never jumps, nor changes speed in one frame.
    @Test func turningBackHalfwayIsSmooth() {
        let journey = journey()
        journey.fliesStraight(true, at: 300)
        let turn = 303.0
        let speedBefore = journey.cameraX(at: turn) - journey.cameraX(at: turn - 0.001)
        let x = journey.cameraX(at: turn)
        journey.fliesStraight(false, at: turn)
        #expect(abs(journey.cameraX(at: turn) - x) < 1e-9)
        let speedAfter = journey.cameraX(at: turn + 0.001) - journey.cameraX(at: turn)
        #expect(abs(speedAfter - speedBefore) < 1e-5)
        #expect(fastest(journey, from: 299, for: 20) <= Self.peak)
    }

    /// At launch it is straight from the very first frame.
    @Test func atOnceItNeverSways() {
        let journey = journey()
        journey.fliesStraight(true, at: 0, atOnce: true)
        #expect(journey.cameraX(at: 0) == journey.cameraX(at: 300))
    }

    /// A frame drawn just before the change, or a rewind to before it, sees the drift as it was.
    @Test func beforeTheChangeItDriftedAsUsual() {
        let plain = journey(), straight = journey()
        straight.fliesStraight(true, at: 400)
        for t in [399.0, 399.97, 380, 300] {
            #expect(abs(straight.cameraX(at: t) - plain.cameraX(at: t)) < 1e-9)
        }
    }

    @Test func itIsKeptAcrossLaunches() throws {
        let journey = journey()
        journey.fliesStraight(true, at: 200)
        let data = try JSONEncoder().encode(journey.snapshot)
        let again = try #require(Journey(try JSONDecoder().decode(Journey.Snapshot.self, from: data)))
        #expect(again.fliesStraight)
        for t in [200.0, 203, 250, 1000] { #expect(again.cameraX(at: t) == journey.cameraX(at: t)) }
    }

    /// A journey saved by a version that always drifted still opens, drifting.
    @Test func anOlderSnapshotStillDrifts() throws {
        let journey = journey()
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(journey.snapshot)) as? [String: Any])
        object.removeValue(forKey: "drift")
        let data = try JSONSerialization.data(withJSONObject: object)
        let again = try #require(Journey(try JSONDecoder().decode(Journey.Snapshot.self, from: data)))
        #expect(!again.fliesStraight)
        #expect(again.cameraX(at: 777) == journey.cameraX(at: 777))
    }
}

/// The places the flight moves on to: the ones ticked, in turn or shuffled, and never an empty round.
@MainActor
@Suite
struct PlaceRoundTests {
    /// The places of the legs a journey lays down over `count` stays from the start.
    private func round(skipping skipped: Set<String> = [], shuffled: Bool = false, count: Int = 40) -> [String] {
        let journey = Journey(start: .first, time: 0, speed: 1, legLength: 100)
        journey.skipped = skipped
        journey.shuffles = shuffled
        journey.extend(through: 100 * Double(count), behind: -1000)
        return journey.legs.map(\.place.id)
    }

    @Test func inTurnItSkipsWhatIsLeftOut() {
        let skipped: Set = ["niigata", "serengeti"]
        let places = round(skipping: skipped)
        let order = Place.all.map(\.id).filter { !skipped.contains($0) }
        #expect(places.first == Place.first.id)
        for (a, b) in zip(places, places.dropFirst()) {
            let i = order.firstIndex(of: a)!
            #expect(b == order[(i + 1) % order.count])
        }
        #expect(Set(places) == Set(order))
    }

    @Test func shuffledItNeverGoesStraightBack() {
        let skipped: Set = ["lapland"]
        let places = round(skipping: skipped, shuffled: true, count: 200)
        #expect(!places.dropFirst().contains("lapland"))
        for (a, b) in zip(places, places.dropFirst()) { #expect(a != b) }
        for (a, c) in zip(places, places.dropFirst(2)) { #expect(a != c) }
        // Every ticked place comes up, and not in the order of the round.
        #expect(Set(places.dropFirst()) == Set(Place.all.map(\.id)).subtracting(skipped))
        #expect(places != round(skipping: skipped, count: 200))
        // The same each time it is worked out.
        #expect(places == round(skipping: skipped, shuffled: true, count: 200))
    }

    @Test(arguments: [false, true])
    func twoPlacesTakeTurns(shuffled: Bool) {
        let ticked = ["normandy", "lisse"]
        let places = round(skipping: Set(Place.all.map(\.id)).subtracting(ticked), shuffled: shuffled).dropFirst()
        for (a, b) in zip(places, places.dropFirst()) { #expect(a != b && ticked.contains(a)) }
    }

    @Test(arguments: [false, true])
    func onePlaceComesAgain(shuffled: Bool) {
        let places = round(skipping: Set(Place.all.map(\.id)).subtracting(["pampa"]), shuffled: shuffled)
        #expect(places.count > 10)
        #expect(places.dropFirst().allSatisfy { $0 == "pampa" })
    }

    @Test func everythingLeftOutIsEverything() {
        #expect(round(skipping: Set(Place.all.map(\.id))) == round())
    }

    /// Changing the round chooses again only what nobody has seen yet: the land in view stays as it is.
    @Test func aNewRoundOnlyChangesWhatIsAhead() {
        let world = World(place: .first, time: 0, light: .alwaysDay)
        world.pointer = { nil }
        world.desktop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        world.home = world.desktop
        let journey = world.journey
        journey.setSpeed(20, at: 0)
        journey.legLength = 1200
        // Fly on until the next place has just been decided, far above the view.
        var t = 0.0
        func flyUntilAPlaceIsDecided() {
            let last = journey.legs.last!.index
            repeat {
                t += 0.1
                world.advance(to: t)
            } while journey.legs.last!.index == last
        }
        // The first is decided as it opens, just above the view; the next as the flight comes to need it.
        flyUntilAPlaceIsDecided()
        flyUntilAPlaceIsDecided()
        let top = world.camera.y + 982 * World.metresPerPoint
        let ahead = journey.legs.last!
        #expect(ahead.start > top + 1000)
        let inView = journey.legs.filter { $0.start <= top }.map(\.index)

        journey.skipped = Set(Place.all.map(\.id)).subtracting(["lisse"])
        world.placesChanged()
        // The place ahead is chosen again; nothing in view was taken away.
        #expect(!journey.legs.contains { $0.index == ahead.index })
        #expect(journey.legs.map(\.index).starts(with: inView))
        let kept = Set(journey.legs.map(\.index))
        for _ in 0..<3 { flyUntilAPlaceIsDecided() }
        let chosen = journey.legs.filter { !kept.contains($0.index) }
        #expect(!chosen.isEmpty)
        #expect(chosen.allSatisfy { $0.place.id == "lisse" })
    }
}

/// What the gull does: chases the pointer or not, and shows or not, fading rather than blinking.
@MainActor
@Suite
struct GullChoiceTests {
    private func world(pointer: @escaping () -> CGPoint?) -> World {
        let world = World(place: .first, time: 0, light: .alwaysDay)
        world.pointer = pointer
        world.isDesktop = { _ in true }
        return world
    }

    /// A pointer going round in circles over the desktop.
    private func circling() -> () -> CGPoint? {
        var angle = 0.0
        return {
            angle += 0.2
            return CGPoint(x: 700 + 200 * cos(angle), y: 500 + 200 * sin(angle))
        }
    }

    @Test func itChasesThePointerOnlyWhenAllowed() {
        let following = world(pointer: circling())
        for t in stride(from: 0.0, to: 5, by: 1.0 / 30) { following.advance(to: t) }
        #expect(following.chasing)

        let ignoring = world(pointer: circling())
        ignoring.followsPointer = false
        var asked = false
        ignoring.isDesktop = { _ in asked = true; return true }
        for t in stride(from: 0.0, to: 5, by: 1.0 / 30) {
            ignoring.advance(to: t)
            #expect(!ignoring.chasing)
        }
        // Nor does it ask the window server what is under the pointer.
        #expect(!asked)
    }

    @Test func hidingTheGullFadesItAndStopsTheChase() {
        let world = world(pointer: circling())
        for t in stride(from: 0.0, to: 2, by: 1.0 / 30) { world.advance(to: t) }
        #expect(world.chasing)
        let start = world.time
        world.showBird(false)
        #expect(!world.chasing)
        #expect(world.birdOpacity(at: start) == 1)
        let halfway = world.birdOpacity(at: start + World.birdFade / 2)
        #expect(halfway > 0.4 && halfway < 0.6)
        #expect(world.birdOpacity(at: start + World.birdFade) == 0)
        for t in stride(from: 2.0, to: 6, by: 1.0 / 30) {
            world.advance(to: t)
            #expect(!world.chasing)
        }
        // Back again, from nothing.
        world.showBird(true)
        #expect(world.birdOpacity(at: world.time) == 0)
        #expect(world.birdOpacity(at: world.time + World.birdFade) == 1)
    }

    /// Held still, no time passes for a fade, so it is gone at once.
    @Test func whileHeldItGoesAtOnce() {
        let world = world(pointer: { nil })
        world.hold(true, at: 0)
        world.showBird(false, atOnce: true)
        #expect(world.birdOpacity(at: world.time) == 0)
    }
}

/// The new choices start as Outbound always was, and each is saved only once chosen.
@MainActor
@Suite
struct NewChoicesPreferencesTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "NewChoicesPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func everythingStartsAsBefore() throws {
        try withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            #expect(!preferences.fliesStraight)
            #expect(preferences.showsBird)
            #expect(preferences.followsPointer)
            #expect(preferences.skippedPlaces.isEmpty)
            #expect(!preferences.shufflesPlaces)
            #expect(preferences.away == .five)
            for key in ["fliesStraight", "showsGull", "followsPointer", "skippedPlaces", "shufflesPlaces", "restAfter",
                        "restsWhenAway"] {
                #expect(defaults.object(forKey: key) == nil)
            }
        }
    }

    @Test func choicesAreSavedAndReadBack() throws {
        try withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.fliesStraight = true
            preferences.showsBird = false
            preferences.followsPointer = false
            preferences.skippedPlaces = ["serengeti", "lapland"]
            preferences.shufflesPlaces = true
            #expect(defaults.stringArray(forKey: "skippedPlaces") == ["lapland", "serengeti"])
            let later = Preferences(defaults: defaults)
            #expect(later.fliesStraight && !later.showsBird && !later.followsPointer && later.shufflesPlaces)
            #expect(later.skippedPlaces == ["serengeti", "lapland"])
        }
    }

    /// How long until it holds still keeps 1.8's on and off where it always was, and the time beside it.
    @Test func awayKeepsTheOldSwitch() throws {
        try withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.away = .two
            #expect(defaults.object(forKey: "restsWhenAway") == nil)
            #expect(defaults.integer(forKey: "restAfter") == 2)
            preferences.away = .never
            #expect(defaults.object(forKey: "restsWhenAway") as? Bool == false)
            #expect(defaults.integer(forKey: "restAfter") == 2)
            #expect(Preferences(defaults: defaults).away == .never)
            preferences.away = .fifteen
            #expect(defaults.object(forKey: "restsWhenAway") as? Bool == true)
            #expect(Preferences(defaults: defaults).away == .fifteen)
            #expect(Preferences.Away.fifteen.seconds == 900 && Preferences.Away.never.seconds == nil)
        }
        try withDefaults { defaults in
            // Turned on in 1.8, with no time saved: five minutes, as it was.
            defaults.set(true, forKey: "restsWhenAway")
            #expect(Preferences(defaults: defaults).away == .five)
            // A time no longer offered.
            defaults.set(7, forKey: "restAfter")
            #expect(Preferences(defaults: defaults).away == .five)
        }
    }
}

/// The order places come in: any order of every place, kept sound whatever was saved, and followed from wherever the
/// flight is.
@MainActor
@Suite
struct PlaceOrderTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "PlaceOrderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func whatIsSavedIsKeptSound() {
        let usual = Preferences.usualOrder
        #expect(Preferences.ordered([]) == usual)
        // Places gone in an update are let go, a place twice is kept once, and a place added since comes at the end.
        let saved = ["kansas", "atlantis", "lisse", "kansas"] + usual.filter { !["kansas", "lisse", "pampa"].contains($0) }
        let ordered = Preferences.ordered(saved)
        #expect(ordered.count == usual.count && Set(ordered) == Set(usual))
        #expect(Array(ordered.prefix(2)) == ["kansas", "lisse"])
        #expect(ordered.last == "pampa")
    }

    @Test func onlyAChosenOrderIsSaved() throws {
        try withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.placeOrder == Preferences.usualOrder)
            #expect(defaults.object(forKey: "placeOrder") == nil)
            preferences.placeOrder.move(fromOffsets: [7], toOffset: 0)
            #expect(defaults.stringArray(forKey: "placeOrder")?.first == "kansas")
            #expect(Preferences(defaults: defaults).placeOrder == preferences.placeOrder)
            // Back in the usual order, nothing is kept, so places added later fall into their own place in it.
            preferences.placeOrder = Preferences.usualOrder
            #expect(defaults.object(forKey: "placeOrder") == nil)
            // Anything set is made sound before it is kept.
            preferences.placeOrder = ["lapland", "lapland", "nowhere"]
            #expect(preferences.placeOrder.first == "lapland" && preferences.placeOrder.count == Place.all.count)
            #expect(defaults.stringArray(forKey: "placeOrder") == preferences.placeOrder)
        }
        try withDefaults { defaults in
            defaults.set("not a list", forKey: "placeOrder")
            #expect(Preferences(defaults: defaults).placeOrder == Preferences.usualOrder)
        }
    }

    private func flown(order: [String], skipping skipped: Set<String> = [], from start: Place = .first) -> [String] {
        let journey = Journey(start: start, time: 0, speed: 1, legLength: 100)
        journey.order = order.compactMap(Place.named)
        journey.skipped = skipped
        journey.extend(through: 100 * 30, behind: -1000)
        return journey.legs.map(\.place.id)
    }

    @Test func inOrderItFollowsTheChosenOrder() {
        let order = Preferences.usualOrder.reversed().map { $0 }
        let places = flown(order: order)
        for (a, b) in zip(places, places.dropFirst()) {
            #expect(b == order[(order.firstIndex(of: a)! + 1) % order.count])
        }
        // Left-out places are passed over in the chosen order too.
        let skipping = flown(order: order, skipping: ["lapland", "lisse"])
        #expect(!skipping.dropFirst().contains { ["lapland", "lisse"].contains($0) })
        #expect(Array(skipping.prefix(3)) == ["kansas", "pampa", "normandy"])
    }

    /// From a place that isn't in the round at all, as one flown to that isn't in it, it starts from the top.
    @Test func fromOutsideTheRoundItStartsAtTheTop() {
        let order = ["lisse", "punjab", "niigata"]
        let places = flown(order: order)
        #expect(Array(places.prefix(4)) == ["kansas", "lisse", "punjab", "niigata"])
    }

    @Test func aNewOrderOnlyChangesWhatIsAhead() {
        let world = World(place: .first, time: 0, light: .alwaysDay)
        world.pointer = { nil }
        let journey = world.journey
        journey.setSpeed(20, at: 0)
        journey.legLength = 1200
        var t = 0.0
        func flyUntilAPlaceIsDecided() {
            let last = journey.legs.last!.index
            repeat {
                t += 0.1
                world.advance(to: t)
            } while journey.legs.last!.index == last
        }
        flyUntilAPlaceIsDecided()
        flyUntilAPlaceIsDecided()
        let top = world.camera.y + 982 * World.metresPerPoint
        let inView = journey.legs.filter { $0.start <= top }
        let ahead = journey.legs.last!
        let order = Preferences.usualOrder.reversed().compactMap(Place.named)
        journey.order = order
        world.placesChanged()
        #expect(!journey.legs.contains { $0.index == ahead.index })
        #expect(journey.legs.map(\.index).starts(with: inView.map(\.index)))
        for _ in 0..<3 { flyUntilAPlaceIsDecided() }
        let places = journey.legs.filter { $0.start > top }.map(\.place.id)
        let all = (inView.map(\.place.id) + places)
        for (a, b) in zip(all.dropFirst(inView.count - 1), all.dropFirst(inView.count)) {
            let i = order.firstIndex { $0.id == a }!
            #expect(b == order[(i + 1) % order.count].id)
        }
    }
}
