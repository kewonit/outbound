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
        guard !key.isEmpty else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let record = try await Polar().activate(key: key, label: macName)
            store(record)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Confirms the key with the store now and then. Offline is forgiven until the grace period runs out.
    func refresh() async {
        guard let record, status != .valid || Date.now.timeIntervalSince(record.validatedAt) > 24 * 3600 else { return }
        do {
            store(try await Polar().validate(record))
        } catch Polar.Failure.unknownKey {
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
        let was = unlocks
        self.record = record
        LicenseKeychain.save(record)
        status = LicenseStatus(record)
        message = nil
        if unlocks != was { onChange(unlocks) }
    }

    private func forget() {
        let was = unlocks
        record = nil
        LicenseKeychain.delete()
        status = .unlicensed
        if unlocks != was { onChange(unlocks) }
    }
}
