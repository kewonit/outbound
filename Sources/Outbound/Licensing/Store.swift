import Foundation
import OutboundCore
import Security

/// Where Outbound is sold. The organization ID is public: Polar's license endpoints for apps need no token.
enum Store {
    /// From the Polar dashboard, under Settings.
    static let organizationID = "POLAR_ORGANIZATION_ID"
    /// The product's checkout link, from the Polar dashboard.
    static let checkoutURL = URL(string: "https://buy.polar.sh/POLAR_CHECKOUT_LINK")!
    static let price = "$7"

    static var api: URL {
        #if DEBUG
        // Test against Polar's sandbox with OUTBOUND_POLAR_SANDBOX=1.
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
}

/// Talks to Polar's public license key endpoints.
struct Polar {
    enum Failure: LocalizedError {
        case unknownKey
        case tooManyMacs
        case malformed
        case offline
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .unknownKey: "That key wasn't recognised, or it is no longer active."
            case .tooManyMacs: "This key is already in use on as many Macs as it allows. Deactivate it on another Mac in Outbound's settings, then try again."
            case .malformed: "That doesn't look like an Outbound license key."
            case .offline: "Outbound couldn't reach the store. Check your connection and try again."
            case .server(let code): "The store had a problem (\(code)). Please try again in a moment."
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
        guard reply.status == "granted" else { throw Failure.unknownKey }
        var updated = record
        updated.validatedAt = .now
        updated.expiresAt = reply.expires_at
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
            return try decoder.decode(Reply.self, from: data)
        case 403: throw Failure.tooManyMacs
        case 404: throw Failure.unknownKey
        case 422: throw Failure.malformed
        default: throw Failure.server(code)
        }
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

    static func save(_ record: LicenseRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
