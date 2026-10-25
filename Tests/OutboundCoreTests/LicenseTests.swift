import Foundation
import Testing
@testable import OutboundCore

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

    @Test func clockInTheFutureIsChecked() {
        #expect(LicenseStatus(record(daysAgo: -5), now: now) == .needsCheck)
    }

    @Test func cleansPastedKeys() {
        #expect(LicenseStatus.clean("  ABCD-1234 \n") == "ABCD-1234")
    }
}
