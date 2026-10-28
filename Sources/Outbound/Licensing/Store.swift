import Foundation
import OutboundCore
import Security

/// Where Outbound is sold. None of this is secret: Polar's license endpoints for apps need no token, and the
/// site's API holds the only one.
enum Store {
    static let organizationID = "687b5988-7a78-4642-968c-19a2d2ab3da7"
    /// Polar's checkout for Outbound. The app normally asks the site for a checkout of its own, so it can watch
    /// for the purchase; this link is the fallback when the site can't be reached.
    static let checkoutURL = URL(string: "https://buy.polar.sh/polar_cl_2WXlRKhLcEPJSQ0KnyuM3gQNFurhMbUrD99Gl4EQHLA")!
    /// Where buyers find their key again and free up a Mac, signing in with a code sent to their email.
    static let portalURL = URL(string: "https://polar.sh/edbnme/portal")!
    static let price = "$4.99"

    static var api: URL {
        #if DEBUG
        // Test against Polar's sandbox with OUTBOUND_POLAR_SANDBOX=1, or a stand-in with OUTBOUND_POLAR_API.
        if let url = ProcessInfo.processInfo.environment["OUTBOUND_POLAR_API"].flatMap(URL.init(string:)) { return url }
        if ProcessInfo.processInfo.environment["OUTBOUND_POLAR_SANDBOX"] != nil {
            return URL(string: "https://sandbox-api.polar.sh")!
        }
        #endif
        return URL(string: "https://api.polar.sh")!
    }

    static var organization: String {
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["OUTBOUND_POLAR_ORGANIZATION"] { return id }
        #endif
        return organizationID
    }

    /// The site's API, which starts checkouts and turns a paid one into its license key.
    static var shop: URL {
        #if DEBUG
        // Point at `npx wrangler dev` with OUTBOUND_SHOP=http://localhost:8787/api.
        if let url = ProcessInfo.processInfo.environment["OUTBOUND_SHOP"].flatMap(URL.init(string:)) { return url }
        #endif
        return URL(string: "https://outbound.edbn.me/api")!
    }

    /// Polar sends dates with and without fractional seconds.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: text)
        }
        return decoder
    }
}

/// Talks to Polar's public license key endpoints. No API version is pinned: a shipped copy must keep working
/// after Polar retires a version, and it only reads a few fields that every version has.
struct Polar {
    enum Failure: LocalizedError {
        case unknownKey
        case noLongerActive
        case tooManyMacs
        case malformed
        case busy
        case offline
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .unknownKey: String(localized: "That key wasn't recognised. Check it against the one on your thank-you page or in your customer portal.")
            case .noLongerActive: String(localized: "That key is no longer active, perhaps because the purchase was refunded.")
            case .tooManyMacs: String(localized: "This key is already in use on three Macs. Free one up in Outbound's settings on that Mac, or in your customer portal, then try again.")
            case .malformed: String(localized: "That doesn't look like an Outbound license key.")
            case .busy: String(localized: "Too many tries in a row. Wait a moment, then try again.")
            case .offline: String(localized: "Outbound couldn't reach the store. Check your connection and try again.")
            case .server(let code): String(localized: "The store had a problem (\(code)). Please try again in a moment.")
            }
        }
    }

    var session = URLSession.shared

    func activate(key: String, label: String) async throws -> LicenseRecord {
        struct Body: Encodable { let key: String; let organization_id: String; let label: String }
        struct Reply: Decodable {
            let id: String
            let license_key: Key
            struct Key: Decodable { let expires_at: Date? }
        }
        let reply: Reply = try await post("/v1/customer-portal/license-keys/activate",
                                          Body(key: key, organization_id: Store.organization, label: label))
        return LicenseRecord(key: key, activationID: reply.id, validatedAt: .now, expiresAt: reply.license_key.expires_at)
    }

    func validate(_ record: LicenseRecord) async throws -> LicenseRecord {
        struct Body: Encodable { let key: String; let organization_id: String; let activation_id: String }
        struct Reply: Decodable { let status: String; let expires_at: Date? }
        let reply: Reply = try await post("/v1/customer-portal/license-keys/validate",
                                          Body(key: record.key, organization_id: Store.organization,
                                               activation_id: record.activationID))
        guard reply.status == "granted" else { throw Failure.noLongerActive }
        var updated = record
        updated.validatedAt = .now
        updated.expiresAt = reply.expires_at
        updated.revokedAt = nil
        return updated
    }

    func deactivate(_ record: LicenseRecord) async throws {
        struct Body: Encodable { let key: String; let organization_id: String; let activation_id: String }
        let _: Empty = try await post("/v1/customer-portal/license-keys/deactivate",
                                      Body(key: record.key, organization_id: Store.organization,
                                           activation_id: record.activationID))
    }

    private struct Empty: Decodable {}

    private func post<Body: Encodable, Reply: Decodable>(_ path: String, _ body: Body) async throws -> Reply {
        var request = URLRequest(url: Store.api.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.offline
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200...299:
            if Reply.self == Empty.self { return Empty() as! Reply }
            return try Store.decoder().decode(Reply.self, from: data)
        case 403:
            // Activation is refused both for a key on too many Macs and for one that has been revoked or has
            // expired; Polar's message says which.
            let detail = Self.detail(in: data).lowercased()
            throw detail.contains("limit") ? Failure.tooManyMacs : Failure.noLongerActive
        case 404:
            let detail = Self.detail(in: data).lowercased()
            throw detail.contains("no longer active") || detail.contains("expired") ? Failure.noLongerActive
                : Failure.unknownKey
        case 422: throw Failure.malformed
        case 429: throw Failure.busy
        default: throw Failure.server(code)
        }
    }

    /// The `detail` of an error reply, which Polar sends as text or, for validation errors, as a list.
    private static func detail(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let text = object["detail"] as? String { return text }
        return String(describing: object["detail"] ?? "")
    }
}

/// Talks to the site's API, which starts a checkout the app can watch and hands back the key once it is paid.
struct Shop {
    struct Checkout: Decodable {
        let id: UUID
        let url: URL
    }

    enum Answer: Equatable {
        case ready(key: String, email: String?)
        /// Not paid yet, or paid a moment ago and the key not made yet.
        case waiting
        /// Expired, failed, refunded or unknown: no key will come from this checkout.
        case closed
    }

    var session = URLSession.shared

    func startCheckout() async throws -> Checkout {
        let (data, response) = try await session.data(for: request("checkout", body: [:]))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Polar.Failure.offline }
        return try Store.decoder().decode(Checkout.self, from: data)
    }

    func license(for checkout: UUID) async throws -> Answer {
        struct Reply: Decodable { let status: String?; let key: String?; let email: String? }
        let (data, response) = try await session.data(for: request("license", body: ["checkout": checkout.uuidString.lowercased()]))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 || code >= 500 { return .waiting }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        switch reply?.status {
        case "ready":
            guard let key = reply?.key else { return .waiting }
            return .ready(key: key, email: reply?.email)
        case "pending", "open", "confirmed": return .waiting
        default: return .closed
        }
    }

    private func request(_ path: String, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: Store.shop.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

/// Keeps the activated license in the login keychain.
enum LicenseKeychain {
    private static let service = "app.outbound.Outbound.license"

    static func load() -> LicenseRecord? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(LicenseRecord.self, from: data)
    }

    /// Whether the record is safely in the keychain.
    static func save(_ record: LicenseRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
