import AppKit
import QuartzCore

/// The name of the place under the bird, in small white type in the corner of the desktop.
/// The text and its shadow are drawn once into a bitmap whenever the place changes, so the render
/// server only ever composites a still picture over the painting.
final class CaptionView: NSView {
    private static let placeFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let noteFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
    /// Room around the text for the shadow's blur.
    static let margin: CGFloat = 10

    private let text = CALayer()
    private var place = ""
    private var note: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        text.anchorPoint = .zero
        text.contentsGravity = .bottomLeft
        // Only the picture fades when the place changes; the frame jumps straight to its new size.
        text.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw(animated: false)
    }

    func update(place newPlace: String, note newNote: String?) {
        guard newPlace != place || newNote != note else { return }
        let animated = !place.isEmpty
        place = newPlace
        note = newNote
        redraw(animated: animated)
    }

    private func redraw(animated: Bool) {
        guard !place.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image = Self.image(place: place, note: note, scale: scale) else { return }
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.8) } else { CATransaction.setDisableActions(true) }
        text.contents = image
        text.contentsScale = scale
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        text.frame = CGRect(origin: CGPoint(x: -Self.margin, y: -Self.margin), size: size)
        CATransaction.commit()
    }

    /// White type with two shadows: a wide soft one that keeps it readable over snow and mustard,
    /// and a tight one that keeps the letters crisp.
    static func image(place: String, note: String?, scale: CGFloat) -> CGImage? {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        func line(_ string: String, _ font: NSFont, _ alpha: CGFloat, _ shadow: NSShadow) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: NSColor(white: 1, alpha: alpha), .kern: 0.15,
                .paragraphStyle: style, .shadow: shadow
            ])
        }
        func shadow(_ alpha: CGFloat, blur: CGFloat, y: CGFloat) -> NSShadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: alpha)
            shadow.shadowBlurRadius = blur
            shadow.shadowOffset = CGSize(width: 0, height: y)
            return shadow
        }
        let soft = shadow(0.32, blur: 7, y: -1), tight = shadow(0.4, blur: 1.2, y: -0.5)
        let lines = [(place, placeFont, CGFloat(0.94))] + (note.map { [($0, noteFont, CGFloat(0.66))] } ?? [])
        let gap: CGFloat = 2
        let sizes = lines.map { line($0.0, $0.1, $0.2, soft).size() }
        let width = ceil(sizes.map(\.width).max() ?? 0) + margin * 2
        let height = ceil(sizes.map(\.height).reduce(0, +) + gap * CGFloat(lines.count - 1)) + margin * 2
        let pixelsWide = Int(width * scale), pixelsHigh = Int(height * scale)
        guard pixelsWide > 0, pixelsHigh > 0,
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // The place name sits at the top, any note below it; the bottom line rests on the margin.
        var y = margin
        for (index, entry) in lines.enumerated().reversed() {
            let origin = CGPoint(x: margin, y: y)
            line(entry.0, entry.1, entry.2, soft).draw(at: origin)
            line(entry.0, entry.1, entry.2, tight).draw(at: origin)
            y += sizes[index].height + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
