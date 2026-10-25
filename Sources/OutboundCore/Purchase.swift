import Foundation

/// The link on the thank-you page that hands a purchase to the app: `outbound://activate?checkout=<uuid>`.
/// It carries the checkout, never the key; the app asks the store for the key itself. Any web page can open
/// such a link, so anything but that exact shape is ignored.
public struct ActivationLink: Equatable, Sendable {
    public let checkout: UUID

    public init?(_ url: URL, schemes: Set<String> = ["outbound", "outbound-dev"]) {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              url.host(percentEncoded: false)?.lowercased() == "activate",
              url.path(percentEncoded: false).isEmpty || url.path(percentEncoded: false) == "/",
              url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "checkout",
              let value = items[0].value, value.count == 36,
              let checkout = UUID(uuidString: value) else { return nil }
        self.checkout = checkout
    }
}

/// How often to ask whether a purchase made from the app has gone through: every few seconds while the buyer
/// is likely still paying, then less often, and not at all after 45 minutes, when the checkout has long expired.
public enum PurchaseWatch {
    public static let giveUpAfter: TimeInterval = 45 * 60

    /// Seconds to wait before asking again, or nil to stop.
    public static func delay(after elapsed: TimeInterval) -> TimeInterval? {
        switch elapsed {
        case ..<0: 3
        case ..<180: 3
        case ..<600: 6
        case ..<giveUpAfter: 15
        default: nil
        }
    }
}
