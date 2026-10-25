import Foundation
import Testing
@testable import OutboundCore

struct GeoTests {
    @Test func formatsBothHemispheres() {
        #expect(Geo.caption(Coordinate(latitude: 30.8381, longitude: 76.1894)) == "30.838° N  76.189° E")
        #expect(Geo.caption(Coordinate(latitude: -36.842, longitude: -64.037)) == "36.842° S  64.037° W")
    }

    @Test func movesNorthByMetres() {
        let start = Coordinate(latitude: 10, longitude: 20)
        let moved = Geo.offset(start, east: 0, north: Geo.metresPerDegree)
        #expect(abs(moved.latitude - 11) < 1e-9)
        #expect(moved.longitude == 20)
    }

    @Test func eastIsWiderNearTheEquator() {
        let north = Geo.offset(Coordinate(latitude: 60, longitude: 0), east: 10_000, north: 0)
        let equator = Geo.offset(Coordinate(latitude: 0, longitude: 0), east: 10_000, north: 0)
        #expect(north.longitude > equator.longitude * 1.9)
    }

    @Test func wrapsLongitude() {
        let moved = Geo.offset(Coordinate(latitude: 0, longitude: 179.99), east: 5_000, north: 0)
        #expect(moved.longitude < -179)
    }
}

struct FramePacingTests {
    @Test func dividesFixedRefreshEvenly() {
        #expect(FramePacing.rate(target: 30, refresh: 75) == 25)
        #expect(FramePacing.rate(target: 30, refresh: 60) == 30)
        #expect(FramePacing.rate(target: 60, refresh: 75) == 37.5)
        #expect(FramePacing.rate(target: 20, refresh: 144) == 20)
    }

    @Test func leavesProMotionAlone() {
        #expect(FramePacing.rate(target: 30, refresh: 120) == 30)
        #expect(FramePacing.rate(target: 24, refresh: 120) == 24)
    }

    @Test func tiersFollowPower() {
        var state = PowerState()
        #expect(PowerTier.choose(state).framesPerSecond == 24)
        state.birdEngaged = true
        #expect(PowerTier.choose(state).framesPerSecond == 60)
        state.onBattery = true
        #expect(PowerTier.choose(state).framesPerSecond == 30)
        state.birdEngaged = false
        #expect(PowerTier.choose(state).framesPerSecond == 15)
        #expect(PowerTier.choose(state).halfRateClouds)
        state.lowPower = true
        #expect(PowerTier.choose(state).frozen)
        state.lowPower = false
        state.batteryMode = .still
        #expect(PowerTier.choose(state).frozen)
        state.onBattery = false
        state.thermal = .serious
        #expect(PowerTier.choose(state).frozen)
    }
}

struct PlaceTests {
    private func date(_ month: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: month, day: 15))!
    }

    @Test func everyMonthHasASeason() {
        for place in Place.all {
            for month in 1...12 {
                let covered = place.seasons.filter { $0.months.contains(month) }
                #expect(covered.count == 1, "\(place.id) month \(month)")
            }
        }
    }

    @Test func seasonsFollowTheLocalCalendar() {
        #expect(Place.named("punjab")!.season(on: date(2)).line.contains("mustard"))
        #expect(Place.named("niigata")!.season(on: date(4)).line.contains("sakura"))
        #expect(Place.named("pampa")!.season(on: date(10)).line.hasPrefix("Spring"))
        #expect(Place.named("lapland")!.season(on: date(12)).line.hasPrefix("Winter"))
    }
}

struct JourneyTests {
    @Test func flyingNorthMovesOnToTheNextPlace() {
        let journey = Journey(start: Place.all[0], time: 0, speed: 10, legLength: 1000)
        journey.extend(through: 5000, behind: 0)
        #expect(journey.leg(at: 0).place.id == Place.all[0].id)
        #expect(journey.leg(at: 1100).place.id == Place.all[1].id)
        #expect(journey.leg(at: 2100).place.id == Place.all[2].id)
    }

    @Test func forgetsLegsFarBehind() {
        let journey = Journey(start: Place.all[0], time: 0, speed: 10, legLength: 1000)
        journey.extend(through: 30_000, behind: 25_000)
        #expect(journey.legs.count < 10)
        #expect(journey.leg(at: 26_000).start <= 26_000)
    }

    @Test func flyToReplacesWhatIsAhead() {
        let journey = Journey(start: Place.all[0], time: 0, speed: 10, legLength: 1000)
        journey.extend(through: 3000, behind: 0)
        let lisse = Place.named("lisse")!
        journey.fly(to: lisse, from: 500, time: 12)
        #expect(journey.leg(at: 600).place.id == "lisse")
        #expect(journey.leg(at: 600).sweepStart == 12)
        #expect(journey.leg(at: 400).place.id == Place.all[0].id)
        journey.extend(through: 3000, behind: 0)
        #expect(journey.leg(at: 1600).place.id != "lisse")
    }

    @Test func cameraKeepsFlyingAfterASpeedChange() {
        let journey = Journey(start: Place.all[0], time: 0, speed: 10)
        #expect(journey.cameraY(at: 10) == 100)
        journey.setSpeed(20, at: 10)
        #expect(journey.cameraY(at: 11) == 120)
    }

    @Test func coordinatesTickNorthward() {
        let journey = Journey(start: Place.named("punjab")!, time: 0)
        let a = journey.coordinate(x: 0, y: 0)
        let b = journey.coordinate(x: 0, y: 100)
        #expect(b.latitude > a.latitude)
    }
}
