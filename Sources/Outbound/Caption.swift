import AppKit
import OutboundCore
import SwiftUI

/// What the label in the corner says.
@MainActor
@Observable
final class Caption {
    var place = ""
    var season = ""
    var coordinates = ""
    var note: String?
}

/// A scrap of paper in the corner naming the place under the bird, like the caption under a print.
struct CaptionView: View {
    let caption: Caption

    private static let ink = Color(red: 0.19, green: 0.18, blue: 0.17)

    var body: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            Text(caption.place)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.ink)
                .id(caption.place)
                .transition(.opacity)
            Text(caption.season)
                .font(.system(size: 11.5))
                .foregroundStyle(Self.ink.opacity(0.62))
                .id(caption.season)
                .transition(.opacity)
            Text(caption.coordinates)
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Self.ink.opacity(0.45))
                .padding(.top, 1.5)
            if let note = caption.note {
                Text(note)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.72, green: 0.32, blue: 0.2))
                    .padding(.top, 2)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: caption.place)
        .animation(.easeInOut(duration: 0.8), value: caption.season)
        .animation(.easeOut(duration: 0.3), value: caption.coordinates)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .background(
            TornPaper(seed: 7)
                .fill(Color(red: 0.985, green: 0.972, blue: 0.94))
                .shadow(color: .black.opacity(0.18), radius: 3, x: 1, y: 1.5)
        )
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}

/// A rectangle whose edges look torn by hand.
struct TornPaper: Shape {
    let seed: UInt64

    func path(in rect: CGRect) -> Path {
        var random = SplitMix(seed: seed)
        let step: CGFloat = 3.2
        var points: [CGPoint] = []
        func edge(from a: CGPoint, to b: CGPoint, depth: CGFloat) {
            let length = hypot(b.x - a.x, b.y - a.y)
            let count = max(Int(length / step), 1)
            let normal = CGPoint(x: (a.y - b.y) / length, y: (b.x - a.x) / length)
            for i in 0..<count {
                let t = CGFloat(i) / CGFloat(count)
                let wobble = (CGFloat(random.next()) - 0.5) * depth
                points.append(CGPoint(x: a.x + (b.x - a.x) * t + normal.x * wobble,
                                      y: a.y + (b.y - a.y) * t + normal.y * wobble))
            }
        }
        edge(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY), depth: 1.6)
        edge(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY), depth: 2.6)
        edge(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY), depth: 1.6)
        edge(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.minY), depth: 1.2)
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

/// Small deterministic random numbers, so the torn edge is the same every launch.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
