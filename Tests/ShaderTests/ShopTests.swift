import Foundation
import Testing
@testable import Outbound

/// What the app asks the site for when someone buys, and how it tells a key on all its Macs from one that is no longer
/// active, from what Polar answers. The answers are Polar's own words (server/polar/license_key/service.py).
@Suite(.serialized)
struct ShopTests {
    /// Answers every request with `reply`, and keeps what was asked.
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var reply: (status: Int, body: String) = (200, "{}")
        nonisolated(unsafe) static var asked: [(url: URL?, method: String?, body: Data)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // A session hands the body over as a stream.
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                stream.close()
            }
            Self.asked.append((request.url, request.httpMethod, body))
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static var session: URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Stub.self]
            return URLSession(configuration: configuration)
        }
    }

    @Test func buyingAsksTheSiteForOneMac() async throws {
        Stub.asked = []
        Stub.reply = (200, #"{"id":"aaaaaaaa-0000-4000-8000-000000000001","url":"https://polar.sh/checkout/x","expires_at":"2026-11-13T00:00:00Z"}"#)
        var shop = Shop()
        shop.session = Stub.session
        let checkout = try await shop.startCheckout()
        #expect(checkout.url.absoluteString == "https://polar.sh/checkout/x")
        let asked = try #require(Stub.asked.last)
        #expect(asked.url?.absoluteString == "https://outbound.edbn.me/api/checkout")
        #expect(asked.method == "POST")
        // The site sells 1 Mac only to an app that asks for it, as this one's buy window offers; older ones get 3.
        let body = try JSONSerialization.jsonObject(with: asked.body) as? [String: String]
        #expect(body == ["macs": "1"])
    }

    private func activating(answer: (Int, String)) async -> Error? {
        Stub.reply = answer
        var polar = Polar()
        polar.session = Stub.session
        do {
            _ = try await polar.activate(key: "OUTBOUND-TEST", label: "Test Mac")
            return nil
        } catch {
            return error
        }
    }

    @Test func aKeyOnAllItsMacsSaysSoWithoutANumber() async throws {
        let error = await activating(answer: (403, #"{"detail":"License key activation limit already reached"}"#))
        guard case .tooManyMacs = error as? Polar.Failure else {
            Issue.record("Expected tooManyMacs, got \(String(describing: error))")
            return
        }
        // Keys allow 1 Mac or, bought before 13 November 2026, 3: the message names neither.
        let message = try #require((error as? LocalizedError)?.errorDescription)
        #expect(!message.contains("three") && !message.contains("3"))
        #expect(message.contains("as many Macs as it allows"))
    }

    @Test func aKeyNoLongerActiveIsNotTakenForOneOnTooManyMacs() async throws {
        for detail in ["License key is no longer active. This license key can not be activated.", "License key has expired."] {
            let error = await activating(answer: (403, "{\"detail\":\"\(detail)\"}"))
            guard case .noLongerActive = error as? Polar.Failure else {
                Issue.record("\(detail): expected noLongerActive, got \(String(describing: error))")
                continue
            }
        }
    }

    @Test func aGoodKeyActivates() async throws {
        Stub.reply = (200, #"{"id":"act_1","license_key":{"expires_at":null}}"#)
        var polar = Polar()
        polar.session = Stub.session
        let record = try await polar.activate(key: "OUTBOUND-TEST", label: "Test Mac")
        #expect(record.activationID == "act_1")
        let asked = try #require(Stub.asked.last)
        #expect(asked.url?.path() == "/v1/customer-portal/license-keys/activate")
    }
}

/// The menu's names for each choice, and what each saves: the names changed in the menu's rewrite, the saved values
/// didn't, so everyone's choices come through.
@MainActor
@Suite
struct MenuChoiceTests {
    @Test func theNamesAreTheMenus() {
        #expect(Preferences.Pace.allCases.map(\.title) == ["Slow", "Medium", "Fast"])
        #expect(Preferences.Stay.allCases.map(\.title) == ["After 20 Minutes", "After 30 Minutes", "After an Hour", "Never"])
        #expect([World.Light.alwaysDay, .yourTime, .placeTime].map(\.title) == ["Always Daytime", "Follow My Clock", "Local Time There"])
    }

    @Test func theSavedValuesAreAsBefore() throws {
        let name = "MenuChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.pace = .gentle
        preferences.stay = .hour
        preferences.light = .placeTime
        #expect(defaults.string(forKey: "flightPace") == "gentle")
        #expect(defaults.integer(forKey: "stay") == 60)
        #expect(defaults.string(forKey: "light") == "placeTime")
        // Read back by a later launch, the same choices.
        let later = Preferences(defaults: defaults)
        #expect(later.pace == .gentle && later.stay == .hour && later.light == .placeTime)
    }
}
