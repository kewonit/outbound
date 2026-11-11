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
            rest()
        } else if resting && idle < 2 && !restsByHand {
            wake()
        }
    }

    private func rest() {
        resting = true
        onChange(true)
        schedule(every: 2)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }
    }

    #if DEV
    /// Dev builds: rests now, as if nobody had touched the Mac for a while. Moving the mouse outside Outbound's own
    /// windows wakes it, as it does any rest.
    func restNow() {
        guard !resting else { return }
        restsByHand = true
        rest()
    }

    private var restsByHand = false
    #else
    private let restsByHand = false
    #endif

    private func wake() {
        guard resting else { return }
        resting = false
        #if DEV
        restsByHand = false
        #endif
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        schedule(every: 10)
        onChange(false)
    }
}
