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

    /// Appends legs so the land up to world y is decided, and forgets legs far behind. A new place begins no
    /// earlier than `notBefore`: a leg that ran long, while the journey stayed put or the stay was shortened, then
    /// ends beyond the view, and the next place still drifts in from the top rather than appearing under it.
    public func extend(through y: Double, behind: Double, notBefore: Double = -.infinity, date: Date = .now) {
        while !staysPut, let last = legs.last, last.start + legLength < y {
            let i = Place.all.firstIndex { $0.id == last.place.id } ?? 0
            let start = max(last.start + legLength, notBefore)
            append(Place.all[(i + 1) % Place.all.count], start: start, sweep: nil, date: date)
        }
        while legs.count > 2, legs[1].start + Self.morphLength < behind {
            legs.removeFirst()
        }
    }

    /// Changes the land under the camera to another place, repainting what is on screen.
    public func fly(to place: Place, from y: Double, time: TimeInterval, date: Date = .now) {
        legs.removeAll { $0.start >= y }
        append(place, start: y, sweep: time, date: date)
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
