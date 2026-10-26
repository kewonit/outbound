import AppKit

extension NSImage {
    /// The gull from Outbound's icon, as a menu bar glyph. It is drawn rather than stored, so it stays sharp at
    /// every scale, and it is a template, so the menu bar colours it.
    static let outboundGull = gull(CGSize(width: 18, height: 18))

    /// The same gull to go in a line of text, where it sits on the baseline about as tall as a lowercase letter.
    static let outboundGullInline = gull(CGSize(width: 17, height: 8))

    private static func gull(_ size: CGSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            gullPath(width: rect.width, in: rect).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Outbound"
        return image
    }

    /// The gull of `mark.svg`, `width` points across and centred in `rect`. Its wings are raised a little more
    /// than in the icon, so it still reads as a bird at this size.
    static func gullPath(width: CGFloat, in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        // The mark's 64-unit square, its y axis turned to point up.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: 64 - y) }
        path.move(to: point(11, 30))
        path.curve(to: point(31.5, 33), controlPoint1: point(18, 23.5), controlPoint2: point(24.5, 24))
        path.curve(to: point(52, 30), controlPoint1: point(38.5, 24), controlPoint2: point(45, 23.5))
        path.curve(to: point(31.5, 38.5), controlPoint1: point(44.5, 28), controlPoint2: point(38.5, 31))
        path.curve(to: point(11, 30), controlPoint1: point(24.5, 31), controlPoint2: point(18.5, 28))
        path.close()
        let bounds = path.bounds
        let scale = width / bounds.width
        var transform = AffineTransform(translationByX: rect.midX, byY: rect.midY)
        transform.scale(x: scale, y: scale * 1.25)
        transform.translate(x: -bounds.midX, y: -bounds.midY)
        path.transform(using: transform)
        return path
    }
}
