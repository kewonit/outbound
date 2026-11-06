import Foundation

/// Hears the Mac asking whether to shut down, restart or log out. AppKit says nothing until the quit itself, and
/// `NSWorkspace.willPowerOffNotification` comes with that, a fraction of a second before nothing can draw any more, so
/// this listens to loginwindow's own notifications. They aren't documented, but nor are the lock screen's, and should
/// they ever go quiet Outbound simply quits as it always did.
@MainActor
final class SessionEndWatch: NSObject {
    /// Called with true as the question is asked, and false if the answer turns out to be no.
    var onChange: (Bool) -> Void = { _ in }
    private(set) var ending = false
    /// How long to wait for the next word before carrying on regardless, so one that never comes can't hold the flight
    /// for good. The system's dialog answers itself after a minute.
    var patience: TimeInterval = 90
    private var timer: Timer?

    private static let asked = ["com.apple.shutdownInitiated", "com.apple.restartInitiated", "com.apple.logoutInitiated"]
    private static let confirmed = "com.apple.logoutContinued"
    /// An app can still stop it after it is confirmed, so only this is final.
    private static let final = "com.apple.pointOfNoReturn"
    private static let called = ["com.apple.logoutCancelled", "com.apple.logoutInterrupted"]

    func start() {
        let center = DistributedNotificationCenter.default()
        for name in Self.asked + Self.called + [Self.confirmed, Self.final] {
            // At once, as Outbound is never the active app, whose notifications otherwise wait for it to be.
            center.addObserver(self, selector: #selector(notified), name: Notification.Name(name), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
    }

    @objc private func notified(_ notification: Notification) {
        heard(notification.name.rawValue)
    }

    func heard(_ name: String) {
        Log.display.notice("Session: \(name, privacy: .public)")
        switch name {
        case Self.final:
            timer?.invalidate()
            timer = nil
        case _ where Self.called.contains(name):
            set(false)
        default:
            // Confirmed with nothing asked, as with no dialog, it is ending all the same.
            set(true)
            wait()
        }
    }

    private func set(_ on: Bool) {
        if !on {
            timer?.invalidate()
            timer = nil
        }
        guard on != ending else { return }
        ending = on
        onChange(on)
    }

    private func wait() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: patience, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.display.notice("Session: nothing more heard, carrying on")
                self?.set(false)
            }
        }
    }
}
