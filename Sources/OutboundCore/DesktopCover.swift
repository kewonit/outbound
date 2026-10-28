import CoreGraphics

/// Whether app windows hide a display's desktop. macOS doesn't say so for a window at the desktop's level: the
/// translucent menu bar and Dock always show a strip of it, and full-screen Spaces count as showing it too. So this
/// works it out from the window list, the way a person would: the part of the display between the menu bar, the notch
/// and the Dock, and whether app windows lie over all of it.
///
/// Everything here is in the global display space the window list uses: points, the origin at the top left of the main
/// display, y growing down.
public enum DesktopCover {
    /// A window from the window list.
    public struct Window: Equatable, Sendable {
        public var frame: CGRect
        public var layer: Int
        public var alpha: Double
        public var pid: Int32
        public var bundle: String?

        public init(frame: CGRect, layer: Int = 0, alpha: Double = 1, pid: Int32 = 1, bundle: String? = nil) {
            self.frame = frame
            self.layer = layer
            self.alpha = alpha
            self.pid = pid
            self.bundle = bundle
        }
    }

    /// Apps that offer windows you can see through. The window list doesn't say whether a window's content is, so
    /// theirs never count as covering: the painting behind a see-through terminal keeps moving.
    public static let seeThrough: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "org.alacritty", "dev.warp.Warp-Stable",
    ]
    /// The system's own windows over the desktop: the Dock (and Mission Control in it) and Stage Manager.
    public static let system: Set<String> = ["com.apple.dock", "com.apple.WindowManager"]
    /// Smaller windows than this, a palette or a widget, never hide a desktop on their own.
    public static let smallest: CGFloat = 64

    /// The part of a display app windows can cover: its `bounds` less the strips along its edges that the menu bar, the
    /// notch and the Dock keep for themselves, which show the painting through them whatever covers the rest.
    public static func area(bounds: CGRect, top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) -> CGRect {
        // Worked out first: a CGRect reports its size as positive however it was made.
        let width = bounds.width - max(left, 0) - max(right, 0)
        let height = bounds.height - max(top, 0) - max(bottom, 0)
        guard width > 0, height > 0 else { return .null }
        return CGRect(x: bounds.minX + max(left, 0), y: bounds.minY + max(top, 0), width: width, height: height)
    }

    /// The windows that hide what is under them: ordinary app windows, opaque and of some size, not Outbound's own nor
    /// the system's, nor from an app whose windows may be see-through.
    public static func covering(_ windows: [Window], ownPID: Int32) -> [CGRect] {
        windows.filter { window in
            window.layer == 0 && window.alpha >= 0.99 && window.pid != ownPID
                && window.frame.width >= smallest && window.frame.height >= smallest
                && !(window.bundle.map { system.contains($0) || seeThrough.contains($0) } ?? false)
        }.map(\.frame)
    }

    /// The windows over each display. With a Space for each display, a window shows only on the display holding most
    /// of it; otherwise it shows on every display it reaches.
    public static func assign(_ windows: [CGRect], to displays: [CGRect], separateSpaces: Bool) -> [[CGRect]] {
        var out = displays.map { _ in [CGRect]() }
        for window in windows {
            let overlaps = displays.map { display -> CGFloat in
                let overlap = display.intersection(window)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            if separateSpaces {
                if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 {
                    out[best].append(window)
                }
            } else {
                for i in overlaps.indices where overlaps[i] > 0 { out[i].append(window) }
            }
        }
        return out
    }

    /// Whether `windows`, each grown by `inflate`, lie over every point of a `spacing` grid across `area`. The growing
    /// lets the narrow gaps of tiled windows and Split View's divider count as covered, as nobody sees a desktop
    /// through them.
    public static func covers(_ windows: [CGRect], area: CGRect, spacing: CGFloat = 32, inflate: CGFloat = 12) -> Bool {
        coverage(windows, area: area, spacing: spacing, inflate: inflate) >= 1
    }

    /// The share of the points of a `spacing` grid across `area` that `windows`, each grown by `inflate`, lie over.
    public static func coverage(_ windows: [CGRect], area: CGRect, spacing: CGFloat = 32, inflate: CGFloat = 12) -> Double {
        guard !area.isNull, !area.isEmpty, !windows.isEmpty, spacing > 0 else { return 0 }
        let grown = windows.map { $0.insetBy(dx: -inflate, dy: -inflate) }
        var points = 0, under = 0
        var y = area.minY + min(spacing, area.height) / 2
        while y < area.maxY {
            var x = area.minX + min(spacing, area.width) / 2
            while x < area.maxX {
                let point = CGPoint(x: x, y: y)
                points += 1
                if grown.contains(where: { $0.contains(point) }) { under += 1 }
                x += spacing
            }
            y += spacing
        }
        return points == 0 ? 0 : Double(under) / Double(points)
    }

    /// How much of a display's desktop shows.
    public enum Level: Sendable, Equatable {
        case open
        /// A strip or a corner shows, under a tenth of it.
        case mostly
        case hidden
    }

    /// The share of a desktop under windows at which only a strip of it shows.
    public static let mostly = 0.9
}

/// When a display counts as covered: covered readings `confirm` seconds apart, so a window passing over, or an app
/// switched to for a moment, doesn't count; one clear reading uncovers it at once, so coming back to the desktop is
/// never kept waiting.
public struct CoverDebounce: Sendable {
    public private(set) var covered = false
    private var since: Double?
    private let confirm: Double

    public init(confirm: Double = 0.3) {
        self.confirm = confirm
    }

    /// Takes a reading at `time` in seconds and says whether the display now counts as covered.
    @discardableResult
    public mutating func read(_ isCovered: Bool, at time: Double) -> Bool {
        guard isCovered else {
            since = nil
            covered = false
            return false
        }
        if covered { return true }
        if let since, time - since >= confirm {
            covered = true
        } else if since == nil {
            since = time
        }
        return covered
    }

    /// Forgets a cover not yet confirmed, keeping one that is: readings resume after a gap.
    public mutating func restart() {
        if !covered { since = nil }
    }
}
