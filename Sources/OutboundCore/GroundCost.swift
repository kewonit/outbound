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
        max(Int(target / millisecondsPerMillion * 1e6), 16_384)
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
}
