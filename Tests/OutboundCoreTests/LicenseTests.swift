import Foundation
import Testing
@testable import OutboundCore

struct PurchaseTests {
    private let id = "6f1c2c8e-3b7a-4c55-9d2e-0a1b2c3d4e5f"

    @Test func acceptsTheThankYouLink() {
        let link = ActivationLink(URL(string: "outbound://activate?checkout=\(id)")!)
        #expect(link?.checkout == UUID(uuidString: id))
        #expect(ActivationLink(URL(string: "OUTBOUND://Activate/?checkout=\(id.uppercased())")!) != nil)
        #expect(ActivationLink(URL(string: "outbound-dev://activate?checkout=\(id)")!) != nil)
    }

    @Test func ignoresAnythingElse() {
        for link in [
            "https://activate?checkout=\(id)",
            "outbound://unlock?checkout=\(id)",
            "outbound://activate/now?checkout=\(id)",
            "outbound://activate?key=OUTBOUND-123",
            "outbound://activate?checkout=\(id)&key=OUTBOUND-123",
            "outbound://activate?checkout=\(id)&checkout=\(id)",
            "outbound://activate?checkout=not-a-uuid",
            "outbound://activate?checkout=\(id)#more",
            "outbound://activate"
        ] {
            #expect(ActivationLink(URL(string: link)!) == nil, "\(link)")
        }
    }

    @Test func watchesQuicklyThenLessThenStops() {
        #expect(PurchaseWatch.delay(after: 0) == 3)
        #expect(PurchaseWatch.delay(after: 300) == 6)
        #expect(PurchaseWatch.delay(after: 1200) == 15)
        #expect(PurchaseWatch.delay(after: PurchaseWatch.giveUpAfter) == nil)
    }
}

struct LicenseTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(daysAgo: Double, expires: Date? = nil) -> LicenseRecord {
        LicenseRecord(key: "K", activationID: "A", validatedAt: now.addingTimeInterval(-daysAgo * 24 * 3600),
                      expiresAt: expires)
    }

    @Test func noRecordIsUnlicensed() {
        #expect(LicenseStatus(nil, now: now) == .unlicensed)
        #expect(!LicenseStatus(nil, now: now).unlocksWallpaper)
    }

    @Test func recentCheckIsValid() {
        #expect(LicenseStatus(record(daysAgo: 3), now: now) == .valid)
    }

    @Test func olderCheckStillFliesButAsksAgain() {
        let status = LicenseStatus(record(daysAgo: 20), now: now)
        #expect(status == .needsCheck)
        #expect(status.unlocksWallpaper)
    }

    @Test func monthOfflineLapses() {
        #expect(LicenseStatus(record(daysAgo: 31), now: now) == .lapsed)
    }

    @Test func expiredKeyLapses() {
        #expect(LicenseStatus(record(daysAgo: 1, expires: now.addingTimeInterval(-60)), now: now) == .lapsed)
    }

    @Test func clockSetBackHasToBeConfirmed() {
        #expect(LicenseStatus(record(daysAgo: -5), now: now) == .lapsed)
        #expect(LicenseStatus(record(daysAgo: -0.5), now: now) == .valid)
    }

    @Test func revokedKeyLapsesUntilConfirmedAgain() {
        var revoked = record(daysAgo: 1)
        revoked.revokedAt = now
        #expect(LicenseStatus(revoked, now: now) == .lapsed)
        // Records saved before revocation existed still decode.
        let old = #"{"key":"K","activationID":"A","validatedAt":0}"#
        let decoded = try? JSONDecoder().decode(LicenseRecord.self, from: Data(old.utf8))
        #expect(decoded?.revokedAt == nil)
    }

    @Test func cleansPastedKeys() {
        #expect(LicenseStatus.clean("  ABCD-1234 \n") == "ABCD-1234")
    }
}
