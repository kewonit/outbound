import Foundation

/// One stretch of the flight over a single place. World y grows northwards, in metres.
public struct Leg: Sendable {
    /// Counts up for the life of the journey, so every leg paints a different stretch of land.
    public let index: Int
    public let place: Place
    public let season: Season
    /// World y where the leg begins.
    public let start: Double
    /// Set when the leg was entered with Fly To: the land already on screen repaints over time
    /// instead of the change scrolling in from the top.
    public let sweepStart: TimeInterval?
}

/// Where the camera is and which places lie ahead.
public final class Journey {
    /// How long a Fly To repaint takes.
    public static let sweepDuration: TimeInterval = 1.6
    /// The caption's coordinates run faster than the painted ground so the digits visibly tick.
    public static let geoScale = 30.0

    public private(set) var legs: [Leg]
    /// Metres per second.
    public private(set) var speed: Double
    /// Metres flown over one place before moving on to the next.
    public var legLength: Double
    public var followsCalendar: Bool
    /// Stays over the place in view rather than moving on to the next one. A Fly To still goes somewhere new.
    public var staysPut = false
    /// How many times Fly To has gone somewhere new, so a display that drew nothing while one swept in can tell that
    /// the ground it keeps is of the place before.
    public private(set) var flights = 0
    /// Places left out of the round the flight moves on through, by id. Fly To still goes to any of them.
    public var skipped: Set<String> = []
    /// Moves on to a place picked at random from the round rather than the next one in it.
    public var shuffles = false

    /// How long the sideways drift takes to slow to a stop, or to gather pace again.
    public static let driftEase: TimeInterval = 8

    /// The latest change to the drift's pace: from `since`, when its clock read `at`, it eased from `from` to `to`, 1
    /// being its usual pace and 0 at a stop.
    public struct Drift: Codable, Equatable, Sendable {
        var since: TimeInterval
        var at: Double
        var from: Double
        var to: Double
    }

    private var drift: Drift?

    /// Whether the land comes straight down the screen, the sideways drift stopped, or stopping, where it was.
    public var fliesStraight: Bool { drift?.to == 0 }

    /// A Fly To: the leg it began, the legs as they were just before, and how far above the camera, in metres, its
    /// sweep reaches, when that was given.
    public struct Flight: Sendable {
        public let leg: Int
        public let replaced: [Leg]
        public let reach: Double?
    }

    /// The latest Fly To, kept only for this run: a journey picked up again never opens mid-sweep.
    public private(set) var lastFlight: Flight?

    private var anchorTime: TimeInterval
    private var anchorY: Double
    /// When the sideways drift started; unlike the anchor, a change of pace leaves it alone.
    private let driftStart: TimeInterval
    private var nextIndex = 1

    public init(start place: Place, time: TimeInterval, date: Date = .now, speed: Double = 11,
                legLength: Double = 11 * 60 * 12, followsCalendar: Bool = true) {
        self.speed = speed
        self.legLength = legLength
        self.followsCalendar = followsCalendar
        anchorTime = time
        anchorY = 0
        driftStart = time
        let season = followsCalendar ? place.season(on: date) : place.signatureSeason
        // The first leg starts a little behind the camera, so the land on screen at launch belongs to it. Not by a share of
        // the stay, which at this point is only a guess: the settings come after.
        legs = [Leg(index: 0, place: place, season: season, start: -300, sweepStart: nil)]
    }

    /// What it takes to pick the journey up again just where it was, after Outbound quits and opens again.
    public struct Snapshot: Codable, Equatable, Sendable {
        /// A leg, with its place by name.
        public struct Stretch: Codable, Equatable, Sendable {
            var index: Int
            var place: String
            var start: Double
            var sweepStart: TimeInterval?
        }

        var legs: [Stretch]
        var nextIndex: Int
        var speed: Double
        var legLength: Double
        var anchorTime: TimeInterval
        var anchorY: Double
        var driftStart: TimeInterval
        /// Nil from versions before the flight could go straight, which always drifted.
        var drift: Drift?
    }

    public var snapshot: Snapshot {
        Snapshot(legs: legs.map { Snapshot.Stretch(index: $0.index, place: $0.place.id, start: $0.start,
                                                   sweepStart: $0.sweepStart) },
                 nextIndex: nextIndex, speed: speed, legLength: legLength, anchorTime: anchorTime, anchorY: anchorY,
                 driftStart: driftStart, drift: drift)
    }

    /// Picks the journey up where `snapshot` left it, over the same land and at the same pace, with the seasons as they
    /// are on `date`. Nil when it can't be, say as a place it was over has gone in an update.
    public init?(_ snapshot: Snapshot, date: Date = .now, followsCalendar: Bool = true) {
        let places = snapshot.legs.compactMap { Place.named($0.place) }
        let starts = snapshot.legs.map(\.start)
        guard !places.isEmpty, places.count == snapshot.legs.count, snapshot.speed > 0, snapshot.legLength > 0,
              (starts + [snapshot.anchorTime, snapshot.anchorY, snapshot.driftStart]).allSatisfy(\.isFinite),
              zip(starts, starts.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        speed = snapshot.speed
        legLength = snapshot.legLength
        self.followsCalendar = followsCalendar
        anchorTime = snapshot.anchorTime
        anchorY = snapshot.anchorY
        driftStart = snapshot.driftStart
        drift = snapshot.drift.flatMap { [$0.since, $0.at, $0.from, $0.to].allSatisfy(\.isFinite) ? $0 : nil }
        legs = zip(snapshot.legs, places).map { saved, place in
            Leg(index: saved.index, place: place,
                season: followsCalendar ? place.season(on: date) : place.signatureSeason,
                start: saved.start, sweepStart: saved.sweepStart)
        }
        nextIndex = max(snapshot.nextIndex, (legs.map(\.index).max() ?? 0) + 1)
    }

    public func cameraY(at time: TimeInterval) -> Double {
        anchorY + speed * (time - anchorTime)
    }

    /// A slow sideways drift so the flight never feels like a conveyor belt, unless it flies straight.
    public func cameraX(at time: TimeInterval) -> Double {
        let t = driftTime(at: time)
        return 70 * sin(t * 2 * .pi / 430) + 24 * sin(t * 2 * .pi / 163 + 1.3)
    }

    /// The drift's own clock, which runs with the flight's until it goes straight, then slows to a stop over
    /// `driftEase`, so the land stops swaying where it is rather than sliding back to the middle. Gathering pace again
    /// is the same played the other way. It depends on the time alone, so every display, and a rewind, agree on it.
    private func driftTime(at time: TimeInterval) -> Double {
        guard let drift else { return time - driftStart }
        let elapsed = time - drift.since
        // Before the change, as a display a frame behind or a rewind asks, it ran at the pace it had then.
        guard elapsed > 0 else { return drift.at + drift.from * elapsed }
        // The pace eases from one to the other along a smoothstep; what it has gained by then is all but the lag.
        let gained = elapsed - Easing.rampLag(elapsed: elapsed, length: Self.driftEase)
        return drift.at + drift.from * elapsed + (drift.to - drift.from) * gained
    }

    /// The drift's pace at `time`, 1 as usual and 0 stopped.
    private func driftPace(at time: TimeInterval) -> Double {
        guard let drift else { return 1 }
        let p = min(max((time - drift.since) / Self.driftEase, 0), 1)
        return drift.from + (drift.to - drift.from) * p * p * (3 - 2 * p)
    }

    /// Stops the sideways drift, or starts it again, easing into it from `time`, or with `atOnce` there already.
    public func fliesStraight(_ on: Bool, at time: TimeInterval, atOnce: Bool = false) {
        guard on != fliesStraight else { return }
        let to: Double = on ? 0 : 1
        drift = Drift(since: time, at: driftTime(at: time), from: atOnce ? to : driftPace(at: time), to: to)
    }

    public func setSpeed(_ newSpeed: Double, at time: TimeInterval) {
        anchorY = cameraY(at: time)
        anchorTime = time
        speed = newSpeed
    }

    /// World y of each line where one place stops and the next begins, with a bank of cloud lying over it.
    public var joins: [Double] {
        legs.dropFirst().filter { $0.sweepStart == nil }.map(\.start)
    }

    /// The leg painted at world y.
    public func leg(at y: Double) -> Leg {
        legs.last { $0.start <= y } ?? legs[0]
    }

    /// The place painted at world y as far as anyone looking can tell. A Fly To's new place starts below the view
    /// and sweeps over it, so until it is halfway across, the place on screen is still the one it is replacing.
    public func placeShown(at y: Double, time: TimeInterval) -> Place {
        let leg = leg(at: y)
        if let start = leg.sweepStart, time - start < Self.sweepDuration * 0.5,
           let previous = self.leg(replacedBy: leg, at: y) ?? self.leg(before: leg) {
            return previous.place
        }
        return leg.place
    }

    /// The leg before the given one, which it is still turning out of.
    public func leg(before leg: Leg) -> Leg? {
        guard let i = legs.firstIndex(where: { $0.index == leg.index }), i > 0 else { return nil }
        return legs[i - 1]
    }

    /// The leg painted at world y before `leg` was flown to, while it is the latest Fly To's. The land there turns out
    /// of that one, which may be a place the Fly To took away from beyond a join, and no longer one of `legs`.
    public func leg(replacedBy leg: Leg, at y: Double) -> Leg? {
        guard let lastFlight, lastFlight.leg == leg.index else { return nil }
        return lastFlight.replaced.last { $0.start <= y } ?? lastFlight.replaced.first
    }

    /// Appends legs so the land up to world y is decided, and forgets legs far behind. A new place begins no
    /// earlier than `notBefore`: a leg that ran long, while the journey stayed put or the stay was shortened, then
    /// ends beyond the view, and the next place still drifts in from the top rather than appearing under it.
    public func extend(through y: Double, behind: Double, notBefore: Double = -.infinity, date: Date = .now) {
        while !staysPut, let last = legs.last, last.start + legLength < y {
            let start = max(last.start + legLength, notBefore)
            append(nextPlace(), start: start, sweep: nil, date: date)
        }
        while legs.count > 2, legs[1].start < behind {
            legs.removeFirst()
        }
    }

    /// Forgets the legs that begin beyond world y, which nobody has seen yet, so the next `extend` chooses them again,
    /// as after the round changed. The first leg always stays.
    public func forgetLegs(beyond y: Double) {
        while legs.count > 1, let last = legs.last, last.start > y, last.sweepStart == nil {
            legs.removeLast()
        }
    }

    /// The place to move on to after the last leg: the next one in the round, or with `shuffles` any but the one
    /// before, and the one before that where the round has room, so it never goes straight back. A round with
    /// everything left out is taken as all of them.
    func nextPlace() -> Place {
        let round = Place.all.filter { !skipped.contains($0.id) }.nonEmpty ?? Place.all
        let last = legs.last?.place
        if shuffles {
            let recent = legs.suffix(2).map(\.place.id)
            var choices = round.filter { $0.id != last?.id }
            if choices.count > 1, recent.count == 2 { choices.removeAll { $0.id == recent[0] } }
            if choices.isEmpty { return last ?? round[0] }
            return choices[Int(Self.scramble(UInt64(nextIndex)) % UInt64(choices.count))]
        }
        let i = last.flatMap { last in Place.all.firstIndex { $0.id == last.id } } ?? 0
        return (1...Place.all.count).lazy.map { Place.all[(i + $0) % Place.all.count] }
            .first { !self.skipped.contains($0.id) } ?? Place.all[(i + 1) % Place.all.count]
    }

    /// SplitMix64's finaliser: a leg's number, scrambled, so a shuffled round is the same each time it is worked out.
    private static func scramble(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Changes the land under the camera to another place, repainting what is on screen. It sweeps in over
    /// `sweepDuration`, or with `atOnce` is there already, as it must be while the flight is held still and no time
    /// passes for it to sweep in. The sweep's front reaches `reach` metres above the camera, past the top of the view.
    public func fly(to place: Place, from y: Double, time: TimeInterval, atOnce: Bool = false, reach: Double? = nil,
                    date: Date = .now) {
        let replaced = legs
        legs.removeAll { $0.start >= y }
        flights += 1
        // A sweep long over, not one just ending, which rounding could leave a hair short of over.
        append(place, start: y, sweep: atOnce ? time - Self.sweepDuration * 2 : time, date: date)
        lastFlight = Flight(leg: nextIndex - 1, replaced: replaced, reach: reach)
    }

    /// Re-reads the season for every leg, after the date or the calendar setting changed.
    public func refreshSeasons(date: Date = .now) {
        legs = legs.map { Leg(index: $0.index, place: $0.place, season: season(for: $0.place, date: date),
                              start: $0.start, sweepStart: $0.sweepStart) }
    }

    /// The caption's coordinate for a point on the ground.
    public func coordinate(x: Double, y: Double) -> Coordinate {
        let leg = leg(at: y)
        return Geo.offset(leg.place.anchor, east: x * Self.geoScale, north: (y - leg.start) * Self.geoScale)
    }

    private func append(_ place: Place, start: Double, sweep: TimeInterval?, date: Date) {
        legs.append(Leg(index: nextIndex, place: place, season: season(for: place, date: date), start: start,
                        sweepStart: sweep))
        nextIndex += 1
    }

    private func season(for place: Place, date: Date) -> Season {
        followsCalendar ? place.season(on: date) : place.signatureSeason
    }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
