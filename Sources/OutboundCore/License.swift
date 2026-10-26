import Foundation

/// A license key activated on this Mac.
public struct LicenseRecord: Codable, Equatable, Sendable {
    public var key: String
    public var activationID: String
    /// When the store last confirmed the key.
    public var validatedAt: Date
    public var expiresAt: Date?
    /// When the store last said the key is no longer active, say after a refund. The record is kept rather
    /// than deleted, so a mistaken answer is undone by the next good check.
    public var revokedAt: Date?

    public init(key: String, activationID: String, validatedAt: Date, expiresAt: Date? = nil, revokedAt: Date? = nil) {
        self.key = key
        self.activationID = activationID
        self.validatedAt = validatedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }
}

public enum LicenseStatus: Equatable, Sendable {
    case unlicensed
    /// Confirmed recently.
    case valid
    /// Still fine, but worth confirming again in the background.
    case needsCheck
    /// Expired, or not confirmed for so long that it has to be checked before flying again.
    case lapsed

    public static let recheckAfter: TimeInterval = 14 * 24 * 3600
    public static let offlineGrace: TimeInterval = 30 * 24 * 3600

    public init(_ record: LicenseRecord?, now: Date = .now) {
        guard let record else {
            self = .unlicensed
            return
        }
        if record.revokedAt != nil {
            self = .lapsed
            return
        }
        if let expiry = record.expiresAt, expiry < now {
            self = .lapsed
            return
        }
        let age = now.timeIntervalSince(record.validatedAt)
        // A clock set back by more than a day can't be trusted to measure the grace period, so confirm first.
        if age < -24 * 3600 { self = .lapsed; return }
        self = age < Self.recheckAfter ? .valid : age < Self.offlineGrace ? .needsCheck : .lapsed
    }

    public var unlocksWallpaper: Bool {
        self == .valid || self == .needsCheck
    }

    /// Keys are pasted from an email or a web page, and come with stray spaces, line breaks, invisible characters
    /// or the words around them. Polar makes every key a prefix and a UUID in capitals, and only takes it exactly.
    public static func clean(_ key: String) -> String {
        let visible = key.unicodeScalars.filter { $0.properties.generalCategory != .format }
        // Rich text sometimes swaps hyphens for dashes that look the same.
        let words = String(String.UnicodeScalarView(visible)).uppercased().replacing(/\p{Pd}/, with: "-")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        // A key on its own among other words, or one broken across lines.
        let shape = /(?:[A-Z0-9]+-)?[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/
        for text in words + [words.joined()] {
            if let match = text.firstMatch(of: shape) { return String(match.output) }
        }
        return words.joined()
    }
}
