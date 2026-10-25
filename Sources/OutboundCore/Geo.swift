import Foundation

public struct Coordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Geo {
    /// Length of one degree of latitude, in metres.
    public static let metresPerDegree = 111_320.0

    /// The coordinate reached by travelling the given metres east and north.
    public static func offset(_ start: Coordinate, east: Double, north: Double) -> Coordinate {
        var latitude = start.latitude + north / metresPerDegree
        latitude = min(max(latitude, -89.999), 89.999)
        let metresPerLongitude = metresPerDegree * max(cos(latitude * .pi / 180), 0.01)
        var longitude = start.longitude + east / metresPerLongitude
        longitude = (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// "30.838° N  76.189° E", always three decimals so the digits tick in place.
    public static func caption(_ coordinate: Coordinate) -> String {
        let lat = String(format: "%.3f", abs(coordinate.latitude))
        let lon = String(format: "%.3f", abs(coordinate.longitude))
        return "\(lat)° \(coordinate.latitude < 0 ? "S" : "N")  \(lon)° \(coordinate.longitude < 0 ? "W" : "E")"
    }
}
