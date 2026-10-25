import Foundation

/// Where the sun stands, and the light it gives the painting.
public struct Sun: Equatable, Sendable {
    /// Radians above the horizon.
    public var elevation: Double
    /// Radians clockwise from north.
    public var azimuth: Double

    public init(elevation: Double, azimuth: Double) {
        self.elevation = elevation
        self.azimuth = azimuth
    }

    /// A high afternoon sun from the upper left, so shadows fall down and to the right like the reference.
    public static let fair = Sun(elevation: 0.85, azimuth: -0.67)

    /// The sun at a latitude, day of the year and local solar time in hours.
    public init(latitude: Double, dayOfYear: Int, solarHour: Double) {
        let phi = latitude * .pi / 180
        let declination = 23.44 * .pi / 180 * sin(2 * .pi * Double(284 + dayOfYear) / 365)
        let hourAngle = (solarHour - 12) * 15 * .pi / 180
        let sinElevation = sin(phi) * sin(declination) + cos(phi) * cos(declination) * cos(hourAngle)
        elevation = asin(max(-1, min(1, sinElevation)))
        azimuth = atan2(-sin(hourAngle), tan(declination) * cos(phi) - sin(phi) * cos(hourAngle))
    }

    /// Local solar time of sunset. 24 when the sun never sets, 12 when it never rises.
    public static func sunsetHour(latitude: Double, dayOfYear: Int) -> Double {
        let phi = latitude * .pi / 180
        let declination = 23.44 * .pi / 180 * sin(2 * .pi * Double(284 + dayOfYear) / 365)
        let cosine = max(-1, min(1, -tan(phi) * tan(declination)))
        return 12 + acos(cosine) * 12 / .pi
    }

    /// Horizontal unit vector towards the sun, east and north.
    public var direction: SIMD2<Double> {
        SIMD2(sin(azimuth), cos(azimuth))
    }

    /// Shadow length per metre of height, kept within what still reads as painted.
    public var shadowLength: Double {
        let e = max(elevation, 0.05)
        return min(max(1 / tan(e), 0.35), 2.4)
    }

    /// 0 in daylight, 1 deep in the night.
    public var night: Double {
        let degrees = elevation * 180 / .pi
        return min(max((-degrees - 1) / 9, 0), 1)
    }

    /// Light colour and strength: white by day, warm low down, dusky at twilight, moonlit blue at night.
    public var light: SIMD4<Double> {
        let degrees = elevation * 180 / .pi
        let day = SIMD3<Double>(1.0, 0.995, 0.985)
        let golden = SIMD3<Double>(1.04, 0.9, 0.74)
        let dusk = SIMD3<Double>(0.86, 0.72, 0.78)
        let moon = SIMD3<Double>(0.42, 0.5, 0.74)
        func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
            a + (b - a) * min(max(t, 0), 1)
        }
        var color: SIMD3<Double>
        var strength: Double
        if degrees > 18 {
            color = day; strength = 1
        } else if degrees > 4 {
            color = mix(golden, day, (degrees - 4) / 14); strength = 1
        } else if degrees > -4 {
            color = mix(dusk, golden, (degrees + 4) / 8); strength = 0.88 + 0.12 * (degrees + 4) / 8
        } else {
            color = mix(moon, dusk, (degrees + 10) / 6); strength = 0.62 + 0.26 * min(max((degrees + 10) / 6, 0), 1)
        }
        return SIMD4(color.x, color.y, color.z, strength)
    }
}
