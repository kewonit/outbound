import AppKit
import CoreGraphics

/// Notices when nobody has touched the Mac for a while, so the wallpaper can hold still until someone does.
/// The first movement of the mouse wakes it at once; keys are noticed within a couple of seconds.
@MainActor
final class RestMonitor {
    var onChange: (Bool) -> Void = { _ in }
    /// Seconds without input before resting; nil never rests.
    var after: TimeInterval? = 300 {
        didSet { check() }
    }
    private(set) var resting = false
    private var timer: Timer?
    private var monitor: Any?

    func start() {
        schedule(every: 10)
    }

    private func schedule(every interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = interval * 0.2
    }

    private var idleSeconds: TimeInterval {
        // kCGAnyInputEventType, which Swift's CGEventType has no case for.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: unsafeBitCast(UInt32.max, to: CGEventType.self))
    }

    private func check() {
        guard let after else {
            if resting { wake() }
            return
        }
        let idle = idleSeconds
        if !resting && idle > after {
            resting = true
            onChange(true)
            schedule(every: 2)
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
        } else if resting && idle < 2 {
            wake()
        }
    }

    private func wake() {
        guard resting else { return }
        resting = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        schedule(every: 10)
        onChange(false)
    }
}
