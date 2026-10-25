import AppKit
import OutboundCore

/// Whether this copy may fly. Release builds need a license key bought from the store; builds made for
/// development run without one and say so in the caption.
@MainActor
@Observable
final class LicenseController {
    private(set) var record: LicenseRecord?
    private(set) var status: LicenseStatus
    private(set) var busy = false
    private(set) var message: String?
    var onChange: (Bool) -> Void = { _ in }

    static var isGated: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

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
        let previous = record
        do {
            // The same key pasted again, say after a long time offline: confirm this Mac's activation rather than
            // taking another of the key's three.
            if let previous, previous.key == key, let confirmed = try? await Polar().validate(previous) {
                store(confirmed)
                return
            }
            // A different key replaces the old one, so give its activation back first.
            if let previous, previous.key != key { try? await Polar().deactivate(previous) }
            store(try await Polar().activate(key: key, label: macName))
        } catch {
            message = error.localizedDescription
        }
    }

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
        } catch Polar.Failure.unknownKey {
            guard self.record == record else { return }
            forget()
            message = "This Mac's license is no longer active. Paste a key to keep flying."
        } catch {
            if status == .lapsed { message = "Outbound needs to confirm your license. Connect to the internet and try again." }
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

    private func store(_ record: LicenseRecord) {
        self.record = record
        message = LicenseKeychain.save(record) ? nil
            : "Outbound couldn't save your license to the keychain, so it will ask for the key again next time."
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
