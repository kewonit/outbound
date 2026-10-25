import AppKit
import QuartzCore

/// A scrap of paper in the corner naming the place under the bird, like the caption under a print.
/// Built from plain layers: the paper and its shadow are drawn once, and only text that changes
/// is redrawn, so the ticking coordinates cost next to nothing.
final class CaptionView: NSView {
    private static let ink = NSColor(srgbRed: 0.19, green: 0.18, blue: 0.17, alpha: 1)
    private static let placeFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let seasonFont = NSFont.systemFont(ofSize: 11.5)
    private static let coordinateFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let noteFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    private let paper = CAShapeLayer()
    private let place = CATextLayer()
    private let season = CATextLayer()
    private let coordinates = CATextLayer()
    private let note = CATextLayer()
    private var size = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        paper.fillColor = NSColor(srgbRed: 0.985, green: 0.972, blue: 0.94, alpha: 1).cgColor
        paper.shadowColor = NSColor.black.cgColor
        paper.shadowOpacity = 0.18
        paper.shadowRadius = 3
        paper.shadowOffset = CGSize(width: 1, height: -1.5)
        layer?.addSublayer(paper)
        for (text, font, color) in [(place, Self.placeFont, Self.ink), (season, Self.seasonFont, Self.ink.withAlphaComponent(0.62)),
                                    (coordinates, Self.coordinateFont, Self.ink.withAlphaComponent(0.45)),
                                    (note, Self.noteFont, NSColor(srgbRed: 0.72, green: 0.32, blue: 0.2, alpha: 1))] {
            text.font = font
            text.fontSize = font.pointSize
            text.foregroundColor = color.cgColor
            text.alignmentMode = .left
            text.truncationMode = .none
            layer?.addSublayer(text)
        }
        // The coordinates change several times a second; never animate them.
        coordinates.actions = ["contents": NSNull()]
        note.actions = ["contents": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in [place, season, coordinates, note] { text.contentsScale = scale }
    }

    func update(place newPlace: String, season newSeason: String, coordinates newCoordinates: String, note newNote: String?) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.8)
        if place.string as? String != newPlace { place.string = newPlace }
        if season.string as? String != newSeason { season.string = newSeason }
        if coordinates.string as? String != newCoordinates { coordinates.string = newCoordinates }
        if note.string as? String != (newNote ?? "") { note.string = newNote ?? "" }
        CATransaction.commit()
        layoutText(note: newNote)
    }

    private func layoutText(note text: String?) {
        func width(_ string: String, _ font: NSFont) -> CGFloat {
            ceil((string as NSString).size(withAttributes: [.font: font]).width)
        }
        let lines: [(CATextLayer, NSFont, CGFloat)] = [
            (place, Self.placeFont, 0), (season, Self.seasonFont, 2.5), (coordinates, Self.coordinateFont, 4)
        ] + (text == nil ? [] : [(note, Self.noteFont, 4)])
        let textWidth = lines.map { width(($0.0.string as? String) ?? "", $0.1) }.max() ?? 0
        let paddingX: CGFloat = 14, top: CGFloat = 10, bottom: CGFloat = 11
        var height = top + bottom
        for (_, font, gap) in lines { height += ceil(font.ascender - font.descender) + gap }
        let newSize = CGSize(width: textWidth + paddingX * 2, height: height)
        guard newSize != size else { return }
        size = newSize

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var y = newSize.height - top
        for (layer, font, gap) in lines {
            let lineHeight = ceil(font.ascender - font.descender)
            y -= lineHeight + gap
            layer.frame = CGRect(x: paddingX, y: y, width: textWidth + 4, height: lineHeight + 2)
        }
        note.isHidden = text == nil
        let path = Self.tornPath(CGRect(origin: .zero, size: newSize))
        paper.path = path
        paper.shadowPath = path
        CATransaction.commit()
    }

    /// A rectangle whose edges look torn by hand, the same every launch.
    private static func tornPath(_ rect: CGRect) -> CGPath {
        var random = SplitMix(seed: 7)
        let path = CGMutablePath()
        var first = true
        func edge(from a: CGPoint, to b: CGPoint, depth: CGFloat) {
            let length = hypot(b.x - a.x, b.y - a.y)
            let count = max(Int(length / 3.2), 1)
            let normal = CGPoint(x: (a.y - b.y) / length, y: (b.x - a.x) / length)
            for i in 0..<count {
                let t = CGFloat(i) / CGFloat(count)
                let wobble = (CGFloat(random.next()) - 0.5) * depth
                let point = CGPoint(x: a.x + (b.x - a.x) * t + normal.x * wobble, y: a.y + (b.y - a.y) * t + normal.y * wobble)
                if first { path.move(to: point); first = false } else { path.addLine(to: point) }
            }
        }
        edge(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY), depth: 1.6)
        edge(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY), depth: 2.6)
        edge(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY), depth: 1.6)
        edge(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.minY), depth: 1.2)
        path.closeSubpath()
        return path
    }
}

/// Small deterministic random numbers.
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
