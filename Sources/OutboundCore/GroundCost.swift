import Foundation

/// What painting the ground costs on this Mac's GPU, learned from each piece of it as it finishes, so that no one
/// piece of GPU work runs long. macOS stops GPU work that runs too long, and after enough of that it stops taking
/// any from the app at all; a slow GPU then simply paints in smaller pieces.
public struct GroundCost: Codable, Equatable, Sendable {
    /// GPU milliseconds per million texels painted.
    public private(set) var millisecondsPerMillion: Double
    /// GPU milliseconds one piece of painting may take.
    public private(set) var target: Double

    /// Until it has painted anything, a GPU is taken to be a slow one.
    public static let initial = GroundCost(millisecondsPerMillion: 150, target: 10)

    public init(millisecondsPerMillion: Double, target: Double) {
        self.millisecondsPerMillion = millisecondsPerMillion
        self.target = target
    }

    /// Texels one piece of painting may hold, never so few that painting crawls.
    public var texelsPerPiece: Int {
        let texels = target / max(millisecondsPerMillion, 0.5) * 1e6
        return texels.isFinite ? max(Int(min(texels, 1e9)), 16_384) : 16_384
    }

    /// A piece of `texels` took `milliseconds` of GPU time, and the next is sized from it, at most twice or half the
    /// last: one quick piece never leads to an overlong one, and a GPU that was idle, slow for its first few pieces
    /// while it wakes, isn't then fed pieces too small to wake it.
    public mutating func finished(texels: Int, milliseconds: Double) {
        guard texels >= 4096, milliseconds.isFinite, milliseconds > 0 else { return }
        let sample = milliseconds / (Double(texels) / 1e6)
        let next = millisecondsPerMillion * min(max(sample / millisecondsPerMillion, 0.5), 2)
        millisecondsPerMillion = min(max(next, 0.5), 20_000)
    }

    /// The GPU stopped work for running too long: every piece from now on aims at a quarter of the time.
    public mutating func backOff() {
        target = max(target / 4, 1)
    }

    /// A step back towards the usual time a piece, after a while without trouble.
    public mutating func recover() {
        target = min(target * 2, Self.initial.target)
    }
}

/// When GPU work failing means pieces should be cut down. One stall fails everything on the GPU with it, each display's
/// frame and the pieces under way, so pieces are cut once for it, not once for every piece of work it took down: work
/// is stamped with `cuts` as it is sent, and only work sent since the last cut counts. For a moment after a cut only
/// work stopped for running too long counts; anything else then is what the stall left behind.
public struct GPUFailures: Sendable {
    /// Times pieces were cut down since launch.
    public private(set) var cuts = 0
    private var cutAt = -Double.infinity
    private var recent: [Double] = []

    /// How long after a cut other failures are taken for what the stall left behind.
    public static let settling: Double = 3
    /// How many failures that aren't timeouts, in how many seconds, mean pieces should be cut down.
    public static let tolerated = (count: 3, seconds: 60.0)

    public init() {}

    /// Work stamped `sent` failed at `time`, for running too long or not. Whether pieces should be cut down now.
    public mutating func failed(sent: Int, tooLong: Bool, at time: Double) -> Bool {
        guard sent == cuts, tooLong || time - cutAt >= Self.settling else { return false }
        recent = recent.filter { time - $0 < Self.tolerated.seconds } + [time]
        guard tooLong || recent.count >= Self.tolerated.count else { return false }
        cuts += 1
        cutAt = time
        recent = []
        return true
    }
}
