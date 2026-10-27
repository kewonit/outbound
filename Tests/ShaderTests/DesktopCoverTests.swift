import CoreGraphics
import Testing
@testable import OutboundCore

/// Telling whether app windows hide a display's desktop, from the window list alone (`DesktopCover`).
@Suite
struct DesktopCoverTests {
    /// A 1512 by 982 display at the origin, less a 33 point menu bar, as the window list measures it.
    static let area = DesktopCover.area(bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), top: 33, left: 0,
                                        bottom: 0, right: 0)

    @Test func nothingCoversWithNoWindows() {
        #expect(!DesktopCover.covers([], area: Self.area))
    }

    @Test func oneWindowOverTheWholeAreaCovers() {
        #expect(DesktopCover.covers([Self.area], area: Self.area))
        #expect(DesktopCover.covers([Self.area.insetBy(dx: -40, dy: -40)], area: Self.area))
        // A maximised window stops short of the edges by a few points; that still hides the desktop.
        #expect(DesktopCover.covers([Self.area.insetBy(dx: 6, dy: 6)], area: Self.area))
    }

    @Test func twoHalvesCoverAndANarrowGapStillCounts() {
        let (left, right) = Self.area.divided(atDistance: Self.area.width / 2, from: .minXEdge)
        #expect(DesktopCover.covers([left, right], area: Self.area))
        // Tiled windows with margins, or Split View's divider.
        #expect(DesktopCover.covers([left.insetBy(dx: 4, dy: 0), right.insetBy(dx: 4, dy: 0)], area: Self.area))
        // A real strip of desktop between them.
        #expect(!DesktopCover.covers([left.insetBy(dx: 30, dy: 0), right.insetBy(dx: 30, dy: 0)], area: Self.area))
    }

    @Test func aWindowShortOfTheDesktopLeavesItShowing() {
        let shorter = CGRect(x: 0, y: 33, width: 1512, height: 700)
        #expect(!DesktopCover.covers([shorter], area: Self.area))
    }

    @Test func displaysLeftOfOrAboveTheMainOneWork() {
        // An external display above and to the left, as the window list places it: negative coordinates.
        let bounds = CGRect(x: -1048, y: -1080, width: 2560, height: 1080)
        let area = DesktopCover.area(bounds: bounds, top: 25, left: 0, bottom: 0, right: 0)
        #expect(area == CGRect(x: -1048, y: -1055, width: 2560, height: 1055))
        #expect(DesktopCover.covers([bounds], area: area))
        #expect(!DesktopCover.covers([CGRect(x: 0, y: 0, width: 1512, height: 982)], area: area))
    }

    @Test func theDockAndNotchStripsAreLeftOut() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(DesktopCover.area(bounds: bounds, top: 33, left: 0, bottom: 70, right: 0)
            == CGRect(x: 0, y: 33, width: 1512, height: 879))
        #expect(DesktopCover.area(bounds: bounds, top: 33, left: 64, bottom: 0, right: 0)
            == CGRect(x: 64, y: 33, width: 1448, height: 949))
        #expect(DesktopCover.area(bounds: bounds, top: 33, left: 0, bottom: 0, right: 64)
            == CGRect(x: 0, y: 33, width: 1448, height: 949))
        // A window that stops at the Dock, as maximised windows do, covers what is left.
        let docked = DesktopCover.area(bounds: bounds, top: 33, left: 0, bottom: 70, right: 0)
        #expect(DesktopCover.covers([CGRect(x: 0, y: 33, width: 1512, height: 879)], area: docked))
        // A rotated display is just taller than it is wide.
        let rotated = DesktopCover.area(bounds: CGRect(x: 1512, y: 0, width: 1080, height: 1920), top: 25, left: 0,
                                        bottom: 0, right: 0)
        #expect(DesktopCover.covers([CGRect(x: 1512, y: 25, width: 1080, height: 1895)], area: rotated))
        #expect(DesktopCover.area(bounds: bounds, top: 600, left: 0, bottom: 600, right: 0).isNull)
    }

    @Test func onlyOpaqueAppWindowsOfSomeSizeCount() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let windows = [
            DesktopCover.Window(frame: frame, pid: 10, bundle: "com.apple.Safari"),
            DesktopCover.Window(frame: frame, pid: 99),
            DesktopCover.Window(frame: frame, layer: 3, pid: 10),
            DesktopCover.Window(frame: frame, alpha: 0.9, pid: 10),
            DesktopCover.Window(frame: frame, pid: 11, bundle: "com.apple.dock"),
            DesktopCover.Window(frame: frame, pid: 12, bundle: "com.apple.WindowManager"),
            DesktopCover.Window(frame: frame, pid: 13, bundle: "com.mitchellh.ghostty"),
            DesktopCover.Window(frame: frame, pid: 14, bundle: "com.apple.Terminal"),
            DesktopCover.Window(frame: CGRect(x: 0, y: 0, width: 40, height: 600), pid: 10),
        ]
        #expect(DesktopCover.covering(windows, ownPID: 99) == [frame])
    }

    @Test func eachWindowCountsWhereItShows() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let above = CGRect(x: -1048, y: -1080, width: 2560, height: 1080)
        // Mostly on the main display, a little over the top edge.
        let window = CGRect(x: 100, y: -100, width: 800, height: 900)
        #expect(DesktopCover.assign([window], to: [main, above], separateSpaces: true) == [[window], []])
        #expect(DesktopCover.assign([window], to: [main, above], separateSpaces: false) == [[window], [window]])
        // Off every display.
        #expect(DesktopCover.assign([CGRect(x: 5000, y: 0, width: 10, height: 10)], to: [main, above],
                                    separateSpaces: true) == [[], []])
    }

    @Test func coverCountsOnlyOnceItHolds() {
        var debounce = CoverDebounce(confirm: 0.3)
        let readings: [(Bool, Double, Bool)] = [
            (true, 10, false), (true, 10.2, false), (true, 10.35, true), (true, 11, true),
            // One clear reading uncovers it straight away, and covering starts over.
            (false, 11.1, false), (true, 11.2, false), (true, 11.6, true),
        ]
        for (covered, time, expected) in readings {
            let counts = debounce.read(covered, at: time)
            #expect(counts == expected, "at \(time)")
        }
    }
}
