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

/// One place giving way to the next under cloud. A bank rolls in, closes over everything, and parts again over the new
/// land, so the two places never meet on screen. Everything about it is a matter of the time, so each display can draw
/// its own moment and a rewind needs nothing put back.
public struct Crossing: Equatable, Sendable {
    /// How long the cloud takes to close, stays closed, and takes to clear, whatever the pace.
    public static let closing: TimeInterval = 25
    public static let closed: TimeInterval = 10
    public static let opening: TimeInterval = 25

    /// When the first wisps come in.
    public let start: TimeInterval
    /// When it was called off while still closing, and the bank began to draw back the way it came.
    public private(set) var calledOff: TimeInterval?

    public init(start: TimeInterval) {
        self.start = start
    }

    /// When everything is under cloud.
    public var closes: TimeInterval { start + Self.closing }
    /// When the cloud starts to part.
    public var opens: TimeInterval { closes + Self.closed }
    /// When the land starts to change: its sweep sits in the middle of the time the cloud is closed.
    public var turn: TimeInterval { closes + (Self.closed - Journey.sweepDuration) / 2 }

    /// When the last of it has gone.
    public var end: TimeInterval {
        guard let calledOff else { return opens + Self.opening }
        return calledOff + (calledOff - start)
    }

    /// How far the cloud has closed at `t`, 0 clear sky to 1 closed.
    public func closure(at t: TimeInterval) -> Double {
        // Called off, it draws back at the rate it came in.
        let reached = calledOff.map { $0 - max(t - $0, 0) } ?? .infinity
        return max(0, min(1, (min(t, reached) - start) / Self.closing))
    }

    /// How far the cloud has cleared at `t`, 0 not at all to 1 gone.
    public func clearing(at t: TimeInterval) -> Double {
        calledOff == nil ? max(0, min(1, (t - opens) / Self.opening)) : 0
    }

    /// Whether any of it is in the sky at `t`.
    public func isUnderWay(at t: TimeInterval) -> Bool {
        t >= start && t < end
    }

    /// The land won't be changing after all. While the cloud is still closing it draws back again; once it is closed it
    /// simply clears over the same land.
    public mutating func callOff(at t: TimeInterval) {
        if t < closes { calledOff = t }
    }
}

/// Where the camera is and which places lie ahead.
public final class Journey {
    /// Distance over which one place turns into the next while flying.
    public static let morphLength = 700.0
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
    /// The crossing into the next place, while one is on its way.
    public private(set) var crossing: Crossing?
    /// The crossing under way has still to change the land.
    private var landToChange = false
    /// The time `carryOn` last looked. Nil on a journey picked up from a snapshot, which has no step to measure.
    private var carriedOn: TimeInterval?

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
        carriedOn = time
        let season = followsCalendar ? place.season(on: date) : place.signatureSeason
        // The first leg starts a little behind the camera, so the land on screen at launch belongs to it.
        legs = [Leg(index: 0, place: place, season: season, start: -legLength * 0.15, sweepStart: nil)]
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
    }

    public var snapshot: Snapshot {
        Snapshot(legs: legs.map { Snapshot.Stretch(index: $0.index, place: $0.place.id, start: $0.start,
                                                   sweepStart: $0.sweepStart) },
                 nextIndex: nextIndex, speed: speed, legLength: legLength, anchorTime: anchorTime, anchorY: anchorY,
                 driftStart: driftStart)
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
        legs = zip(snapshot.legs, places).map { saved, place in
            Leg(index: saved.index, place: place,
                season: followsCalendar ? place.season(on: date) : place.signatureSeason,
                start: saved.start, sweepStart: saved.sweepStart)
        }
        nextIndex = max(snapshot.nextIndex, (legs.map(\.index).max() ?? 0) + 1)
    }

    /// Takes up a journey saved by a version that laid each place out ahead of the camera and blended one into the next.
    /// Places change under cloud now, so what is under the camera at `y` has the land to itself, rather than meeting
    /// another place along a line.
    public func settle(at y: Double) {
        let here = leg(at: y)
        if legs.last?.index != here.index || (here.sweepStart == nil && legs.count > 1) { legs = [here] }
    }

    public func cameraY(at time: TimeInterval) -> Double {
        anchorY + speed * (time - anchorTime)
    }

    /// A slow sideways drift so the flight never feels like a conveyor belt.
    public func cameraX(at time: TimeInterval) -> Double {
        let t = time - driftStart
        return 70 * sin(t * 2 * .pi / 430) + 24 * sin(t * 2 * .pi / 163 + 1.3)
    }

    public func setSpeed(_ newSpeed: Double, at time: TimeInterval) {
        anchorY = cameraY(at: time)
        anchorTime = time
        speed = newSpeed
    }

    /// The leg painted at world y.
    public func leg(at y: Double) -> Leg {
        legs.last { $0.start <= y } ?? legs[0]
    }

    /// The place painted at world y as far as anyone looking can tell. A Fly To's new place starts below the view
    /// and sweeps over it, so until it is halfway across, the place on screen is still the one it is replacing.
    public func placeShown(at y: Double, time: TimeInterval) -> Place {
        let leg = leg(at: y)
        if let start = leg.sweepStart, time - start < Self.sweepDuration * 0.5, let previous = self.leg(before: leg) {
            return previous.place
        }
        return leg.place
    }

    /// The leg before the given one, which it is still turning out of.
    public func leg(before leg: Leg) -> Leg? {
        guard let i = legs.firstIndex(where: { $0.index == leg.index }), i > 0 else { return nil }
        return legs[i - 1]
    }

    /// What `carryOn` did to the land.
    public enum Change: Equatable, Sendable {
        case none
        /// A new place is sweeping in, under cloud.
        case sweeping
        /// A new place is simply there, and what is painted of the old one has to go.
        case atOnce
    }

    /// Moves the journey on to `time`: starts a crossing when the stay over this place is up, changes the land once the
    /// cloud has closed, and forgets legs far behind. `bottom` is the world y just below everything on view, where a new
    /// place begins.
    @discardableResult
    public func carryOn(at time: TimeInterval, bottom: Double, behind: Double, date: Date = .now) -> Change {
        defer {
            carriedOn = time
            while legs.count > 2, legs[1].start + Self.morphLength < behind { legs.removeFirst() }
        }
        let y = cameraY(at: time)
        var change = Change.none
        // A step past a whole crossing, as when an export starts well into the flight, has no cloud to show: the journey
        // is simply over the place it would have reached by now.
        if crossing == nil, !staysPut, let carriedOn, time - carriedOn >= Self.crossingLength {
            while let last = legs.last, y >= last.start + legLength + Self.crossingLength * speed {
                // Below the view, whichever display is lowest, and never back over the leg before.
                let start = min(last.start + legLength, bottom)
                guard start > last.start else { break }
                append(place(after: last), start: start, sweep: time - Self.sweepDuration * 2, date: date)
                change = .atOnce
            }
        }
        if crossing == nil, !staysPut, let last = legs.last, y >= last.start + legLength {
            crossing = Crossing(start: time)
            landToChange = true
        }
        guard var underWay = crossing else { return change }
        if landToChange, staysPut {
            underWay.callOff(at: time)
            crossing = underWay
            landToChange = false
        }
        if landToChange, time >= underWay.turn, let last = legs.last {
            // Too late for a sweep to finish under the cloud, it is there at once. Only a long step comes to this.
            let late = time > underWay.opens - Self.sweepDuration
            arrive(at: place(after: last), from: bottom, time: time, atOnce: late, date: date)
            landToChange = false
            change = late ? .atOnce : .sweeping
        }
        if time >= underWay.end { crossing = nil }
        return change
    }

    /// Changes the land under the camera to another place, repainting what is on screen. It sweeps in over
    /// `sweepDuration`, or with `atOnce` is there already, as it must be while the flight is held still and no time
    /// passes for it to sweep in. This place takes the place of any the journey was on its way to.
    public func fly(to place: Place, from y: Double, time: TimeInterval, atOnce: Bool = false, date: Date = .now) {
        if landToChange {
            crossing?.callOff(at: time)
            landToChange = false
        }
        arrive(at: place, from: y, time: time, atOnce: atOnce, date: date)
    }

    private func arrive(at place: Place, from y: Double, time: TimeInterval, atOnce: Bool, date: Date) {
        legs.removeAll { $0.start >= y }
        // A sweep long over, not one just ending, which rounding could leave a hair short of over.
        append(place, start: y, sweep: atOnce ? time - Self.sweepDuration * 2 : time, date: date)
    }

    /// The whole of a crossing, from the first wisps to the last.
    private static var crossingLength: TimeInterval { Crossing.closing + Crossing.closed + Crossing.opening }

    /// The place the journey goes to after `leg`.
    private func place(after leg: Leg) -> Place {
        let i = Place.all.firstIndex { $0.id == leg.place.id } ?? 0
        return Place.all[(i + 1) % Place.all.count]
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
