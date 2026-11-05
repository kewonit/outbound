// Copies from the App Store are paid for there, so they have no license key to check.
#if !APPSTORE
import AppKit
import Combine
import OutboundCore

/// Whether this copy may fly. Release builds need a license key bought from the store; builds made for
/// development run without one and say so in the caption.
///
/// Buying from the app takes no typing: it starts a checkout of its own through the site, opens it in the
/// browser, and watches for the purchase, unlocking itself once the key exists. Buying on the site ends on a
/// thank-you page whose button hands the checkout to the app the same way.
@MainActor
final class LicenseController: ObservableObject {
    @Published private(set) var record: LicenseRecord?
    @Published private(set) var status: LicenseStatus
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    /// A purchase started from the app is being watched for.
    @Published private(set) var waitingForPurchase = false
    var onChange: (Bool) -> Void = { _ in }

    static var isGated: Bool {
        #if DEBUG
        // OUTBOUND_GATED=1 tries the paid flow from a development build.
        ProcessInfo.processInfo.environment["OUTBOUND_GATED"] != nil
        #else
        true
        #endif
    }

    private var watch: Task<Void, Never>?
    private var pending: (checkout: UUID, started: Date, url: URL?)?
    private static let pendingKey = "pendingCheckout"

    init() {
        let saved = LicenseKeychain.load()
        record = saved
        status = LicenseStatus(saved)
    }

    var unlocks: Bool {
        !Self.isGated || status.unlocksWallpaper
    }

    var macName: String {
        Host.current().localizedName ?? "Mac"
    }

    func activate(_ typed: String) async {
        let key = LicenseStatus.clean(typed)
        guard !key.isEmpty, !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await activateKey(key)
        } catch {
            message = error.localizedDescription
        }
    }

    private func activateKey(_ key: String) async throws {
        let previous = record
        // The same key pasted again, say after a long time offline: confirm this Mac's activation rather than
        // taking another of the key's three.
        if let previous, previous.key == key, let confirmed = try? await Polar().validate(previous) {
            store(confirmed)
            return
        }
        // A different key replaces the old one, so give its activation back first.
        if let previous, previous.key != key { try? await Polar().deactivate(previous) }
        store(try await Polar().activate(key: key, label: macName))
    }

    // MARK: - Buying

    /// Starts a checkout the app can watch, opens it in the browser, and unlocks once it is paid. If the site
    /// can't be reached, the plain checkout link still works: its thank-you page hands the purchase back.
    func buy() {
        if waitingForPurchase, let url = pending?.url {
            NSWorkspace.shared.open(url)
            return
        }
        message = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let checkout = try await Shop().startCheckout()
                NSWorkspace.shared.open(checkout.url)
                startWatching(checkout.id, since: .now, url: checkout.url)
            } catch {
                NSWorkspace.shared.open(Store.checkoutURL)
            }
        }
    }

    func cancelPurchase() {
        stopWatching()
    }

    /// Picks up a purchase that was still being watched when Outbound last quit.
    func resumePurchase() {
        guard !unlocks,
              let saved = UserDefaults.standard.dictionary(forKey: Self.pendingKey),
              let id = (saved["checkout"] as? String).flatMap(UUID.init(uuidString:)),
              let started = saved["started"] as? Date,
              Date.now.timeIntervalSince(started) < PurchaseWatch.giveUpAfter else {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            return
        }
        startWatching(id, since: started, url: (saved["url"] as? String).flatMap(URL.init(string:)))
    }

    /// Asks straight away rather than at the next tick, as when the buyer comes back from the browser.
    func checkPurchaseNow() {
        guard let pending, waitingForPurchase else { return }
        startWatching(pending.checkout, since: pending.started, url: pending.url)
    }

    private func startWatching(_ checkout: UUID, since started: Date, url: URL?) {
        watch?.cancel()
        pending = (checkout, started, url)
        waitingForPurchase = true
        UserDefaults.standard.set(["checkout": checkout.uuidString, "started": started, "url": url?.absoluteString ?? ""],
                                  forKey: Self.pendingKey)
        watch = Task { [weak self] in
            while !Task.isCancelled, let delay = PurchaseWatch.delay(after: Date.now.timeIntervalSince(started)) {
                guard let self else { return }
                switch await self.claim(checkout) {
                case .activated, .alreadyActive, .failed, .declined:
                    self.stopWatching()
                    return
                case .waiting:
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            if !Task.isCancelled { self?.stopWatching() }
        }
    }

    private func stopWatching() {
        watch?.cancel()
        watch = nil
        pending = nil
        waitingForPurchase = false
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
    }

    // MARK: - Claiming a purchase

    enum Claim: Equatable {
        case activated
        case alreadyActive
        case waiting
        /// The buyer chose to keep the license already on this Mac.
        case declined
        case failed
    }

    /// Fetches the key for a paid checkout and activates it. A different license already working on this Mac is
    /// only replaced if `replace` agrees, given the email the new one was bought with.
    func claim(_ checkout: UUID, replace: (String?) async -> Bool = { _ in true }) async -> Claim {
        let answer: Shop.Answer
        do {
            answer = try await Shop().license(for: checkout)
        } catch {
            return .waiting
        }
        switch answer {
        case .waiting:
            return .waiting
        case .closed:
            message = String(localized: "That purchase didn't finish, or was refunded.")
            return .failed
        case .ready(let key, let email):
            if let record, record.key == key, unlocks {
                if pending?.checkout == checkout { stopWatching() }
                return .alreadyActive
            }
            if Self.isGated, status.unlocksWallpaper, record != nil, !(await replace(email)) { return .declined }
            guard !busy else { return .waiting }
            busy = true
            message = nil
            defer { busy = false }
            do {
                try await activateKey(key)
            } catch Polar.Failure.offline, Polar.Failure.busy, Polar.Failure.server {
                // Paid and the key is ready; only the store was out of reach. Keep trying.
                return .waiting
            } catch {
                message = error.localizedDescription
                return .failed
            }
            if pending?.checkout == checkout { stopWatching() }
            return .activated
        }
    }

    // MARK: - Checking in

    /// Confirms the key with the store now and then. Offline is forgiven until the grace period runs out.
    func refresh() async {
        // Time passes while the app runs, so the status ages too.
        update(LicenseStatus(record))
        guard let record, !busy, status != .valid || Date.now.timeIntervalSince(record.validatedAt) > 24 * 3600
        else { return }
        do {
            let confirmed = try await Polar().validate(record)
            // Something else, an activation or a deactivation, may have changed the license while this was out.
            guard self.record == record else { return }
            store(confirmed)
        } catch Polar.Failure.noLongerActive, Polar.Failure.unknownKey {
            guard self.record == record else { return }
            // Kept rather than deleted, so a mistaken answer is undone by the next good check.
            var revoked = record
            revoked.revokedAt = .now
            store(revoked, keepMessage: true)
            message = String(localized: "Your license is no longer active.")
        } catch {
            if status == .lapsed { message = String(localized: "Connect to the internet so Outbound can check your license.") }
        }
    }

    func deactivate() async {
        guard let record else { return }
        busy = true
        defer { busy = false }
        do {
            try await Polar().deactivate(record)
            forget()
        } catch {
            message = error.localizedDescription
        }
    }

    private func store(_ record: LicenseRecord, keepMessage: Bool = false) {
        self.record = record
        let saved = LicenseKeychain.save(record)
        if !keepMessage {
            message = saved ? nil
                : String(localized: "Couldn't save your license. You may be asked for it again.")
        }
        update(LicenseStatus(record))
    }

    private func forget() {
        record = nil
        LicenseKeychain.delete()
        update(.unlicensed)
    }

    private func update(_ newStatus: LicenseStatus) {
        let was = unlocks
        status = newStatus
        if unlocks != was { onChange(unlocks) }
    }
}
#endif
