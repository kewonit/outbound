#if DEBUG
import QuartzCore

/// How evenly one display's frames reach the screen, and what they cost, logged every ten seconds while developing.
/// A frame is off the beat when it stays on screen more than half a refresh longer or shorter than the rate asked for.
@MainActor
final class FrameStats {
    private let display: CGDirectDisplayID
    private var started = CACurrentMediaTime()
    private var frames = 0
    private var shown: [CFTimeInterval] = []
    /// On screen minus the moment the frame shows, in milliseconds.
    private var offsets: [Double] = []
    private var dropped = 0
    private var latest = 0.0
    private var waitedMost = 0.0
    private var ticksTotal = 0.0
    private var tickMost = 0.0
    private var gpu: [Double] = []
    private var painted: [Int] = []
    var birdMoves = 0
    var birdStalls = 0
    /// Heavy work seen this period: full repaints, wave frames, cloud repaints, sweep frames, stills.
    var events: [String: Int] = [:]

    init(display: CGDirectDisplayID) {
        self.display = display
    }

    func ticked(late: Double, took: Double, waited: Double) {
        frames += 1
        latest = max(latest, late)
        ticksTotal += took
        tickMost = max(tickMost, took)
        waitedMost = max(waitedMost, waited)
    }

    func presented(at time: CFTimeInterval, showing moment: CFTimeInterval) {
        guard time > 0 else {
            dropped += 1
            return
        }
        shown.append(time)
        offsets.append((time - moment) * 1000)
    }

    func finished(gpu milliseconds: Double, painted texels: Int) {
        gpu.append(milliseconds)
        painted.append(texels)
    }

    func note(_ event: String) {
        events[event, default: 0] += 1
    }

    /// Logs and starts a new period once ten seconds have passed. `rate` is the frame rate asked for, `refresh` the
    /// display's refresh interval.
    func reportIfDue(rate: Double, refresh: Double) {
        let elapsed = CACurrentMediaTime() - started
        guard elapsed > 10, frames > 0 else { return }
        let times = shown.sorted()
        let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
        let expected = 1000 / rate
        let mean = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let deviation = intervals.isEmpty ? 0
            : (intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)).squareRoot()
        let offBeat = intervals.filter { abs($0 - expected) > refresh * 500 }.count
        let sortedGPU = gpu.sorted()
        let line = String(
            format: "Display %u: %.1f fps asked %.1f; on screen every %.2f ms (sd %.2f, %.1f..%.1f), %d off the beat, %d dropped; shown minus moment %.1f..%.1f ms; late max %.1f ms; nextDrawable max %.2f ms; tick mean %.2f max %.2f ms; GPU median %.2f max %.2f ms; painted max %.2f MP; bird %d moved %d stalled; %@",
            display, Double(frames) / elapsed, rate, mean, deviation, intervals.min() ?? 0, intervals.max() ?? 0,
            offBeat, dropped, offsets.min() ?? 0, offsets.max() ?? 0, latest * 1000, waitedMost * 1000,
            ticksTotal / Double(frames) * 1000, tickMost * 1000, sortedGPU.isEmpty ? 0 : sortedGPU[sortedGPU.count / 2],
            sortedGPU.last ?? 0, Double(painted.max() ?? 0) / 1e6, birdMoves, birdStalls,
            events.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        Log.render.info("\(line, privacy: .public)")
        started = CACurrentMediaTime()
        frames = 0
        shown = shown.suffix(1)
        offsets = []
        dropped = 0
        latest = 0
        waitedMost = 0
        ticksTotal = 0
        tickMost = 0
        gpu = []
        painted = []
        birdMoves = 0
        birdStalls = 0
        events = [:]
    }
}
#endif
