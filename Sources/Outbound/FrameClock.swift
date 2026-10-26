import AppKit
import CoreVideo
import QuartzCore

/// A display's frame clock: calls back on the main thread at a chosen rate, saying when the current refresh began,
/// when the frame being drawn is due, and how long one refresh lasts. On macOS 14 and later it is a CADisplayLink. The
/// Mac has none before that, so on macOS 13 it is a CVDisplayLink, which runs on a thread of its own every refresh and
/// passes on every so many.
@MainActor
final class FrameClock {
    struct Tick {
        /// When the current refresh began.
        let timestamp: CFTimeInterval
        /// When the frame drawn now is due.
        let targetTimestamp: CFTimeInterval
        /// How long one refresh of the display lasts.
        let duration: CFTimeInterval
    }

    /// The CADisplayLink on macOS 14 and later, kept untyped as the class doesn't exist before.
    private var displayLink: NSObject?
    private var videoLink: VideoLink?
    private var paused = false

    /// Ticks on the main thread while not paused, `rate` times a second.
    init(view: NSView, display: CGDirectDisplayID, action: @escaping @MainActor (Tick) -> Void) {
        if #available(macOS 14, *), !Self.forcesVideoLink {
            let target = LinkTarget { link in
                action(Tick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp, duration: link.duration))
            }
            let link = view.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            videoLink = VideoLink(display: display, action: action)
        }
        applyRate()
    }

    /// Frames a second wanted, which the display should be able to show evenly (see `FramePacing`).
    var rate: Float = 30 {
        didSet {
            guard rate != oldValue else { return }
            applyRate()
        }
    }

    var isPaused: Bool {
        get { paused }
        set {
            paused = newValue
            if #available(macOS 14, *) { (displayLink as? CADisplayLink)?.isPaused = newValue }
            videoLink?.isPaused = newValue
        }
    }

    func invalidate() {
        if #available(macOS 14, *) { (displayLink as? CADisplayLink)?.invalidate() }
        displayLink = nil
        videoLink?.invalidate()
        videoLink = nil
    }

    private func applyRate() {
        // A ceiling a hair above the rate, so a display a hair off its round refresh still gets the right fraction of
        // it, and room to go down to 80% when something else limits the display.
        if #available(macOS 14, *) {
            (displayLink as? CADisplayLink)?.preferredFrameRateRange = CAFrameRateRange(
                minimum: rate * 0.8, maximum: rate * 1.01, preferred: rate)
        }
        videoLink?.rate = Double(rate)
    }

    private static var forcesVideoLink: Bool {
        #if DEBUG
        // OUTBOUND_VIDEO_LINK=1 runs the macOS 13 clock on later systems, to try it.
        ProcessInfo.processInfo.environment["OUTBOUND_VIDEO_LINK"] != nil
        #else
        false
        #endif
    }
}

/// CADisplayLink wants an Objective-C target; this one passes the link on.
@available(macOS 14, *)
private final class LinkTarget: NSObject {
    private let fire: @MainActor (CADisplayLink) -> Void

    init(_ fire: @escaping @MainActor (CADisplayLink) -> Void) {
        self.fire = fire
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        fire(link)
    }
}

/// The macOS 13 clock. CVDisplayLink calls back on its own thread at every refresh, with the time the frame drawn now
/// will be shown; every so many of those, chosen from the rate, go on to the main thread.
@MainActor
private final class VideoLink {
    /// What the display link's thread and the main thread share.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var stride = 1
        var count = 0
        #if DEBUG
        var leads: [Double] = []
        var fired = 0
        #endif
    }

    private var link: CVDisplayLink?
    private let shared = Shared()
    private var refresh = 1.0 / 60
    private var running = false

    var rate: Double = 30 {
        didSet { updateStride() }
    }

    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            updateRunning()
        }
    }

    init(display: CGDirectDisplayID, action: @escaping @MainActor (FrameClock.Tick) -> Void) {
        guard CVDisplayLinkCreateWithCGDisplay(display, &link) == kCVReturnSuccess, let link else { return }
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        if period.timeScale > 0, period.timeValue > 0 { refresh = Double(period.timeValue) / Double(period.timeScale) }
        let shared = shared
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
        CVDisplayLinkSetOutputHandler(link) { _, now, output, _, _ in
            shared.lock.lock()
            shared.count += 1
            let stride = shared.stride
            let fires = shared.count >= stride
            if fires { shared.count = 0 }
            shared.lock.unlock()
            guard fires else { return kCVReturnSuccess }
            #if DEBUG
            shared.lock.lock()
            shared.leads.append(Double(Int64(output.pointee.hostTime) - Int64(now.pointee.hostTime)) * secondsPerTick * 1000)
            shared.fired += 1
            if shared.fired % 300 == 0 {
                let leads = shared.leads.sorted()
                let line = String(format: "Video link: output is %.2f..%.2f ms after now (median %.2f) over %d frames",
                                  leads.first ?? 0, leads.last ?? 0, leads[leads.count / 2], leads.count)
                shared.leads = []
                Log.render.info("\(line, privacy: .public)")
            }
            shared.lock.unlock()
            #endif
            let refresh = output.pointee.videoRefreshPeriod > 0 && output.pointee.videoTimeScale > 0
                ? Double(output.pointee.videoRefreshPeriod) / Double(output.pointee.videoTimeScale) : 1.0 / 60
            // The output time is the coming refresh, a few milliseconds away, which leaves too little time to draw.
            // Like CADisplayLink's target, the frame is due a whole frame's worth of refreshes on instead.
            let shown = Double(output.pointee.hostTime) * secondsPerTick
            let tick = FrameClock.Tick(timestamp: Double(now.pointee.hostTime) * secondsPerTick,
                                       targetTimestamp: shown + Double(stride - 1) * refresh, duration: refresh)
            DispatchQueue.main.async { MainActor.assumeIsolated { action(tick) } }
            return kCVReturnSuccess
        }
        updateStride()
        updateRunning()
    }

    func invalidate() {
        if let link, running { CVDisplayLinkStop(link) }
        running = false
        link = nil
    }

    private func updateStride() {
        let stride = max(Int((1 / refresh / rate).rounded()), 1)
        shared.lock.lock()
        shared.stride = stride
        shared.lock.unlock()
    }

    private func updateRunning() {
        guard let link else { return }
        if isPaused, running {
            CVDisplayLinkStop(link)
            running = false
        } else if !isPaused, !running {
            CVDisplayLinkStart(link)
            running = true
        }
    }
}
