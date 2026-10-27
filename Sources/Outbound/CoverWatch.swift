import AppKit
import OutboundCore

/// Works out, for each display, whether app windows hide its desktop (see `DesktopCover`), and says when that changes.
/// One read of the window list serves every display: every second while each desktop is in view, three times a second
/// while one is covered so coming back is noticed at once, and straight after anything that moves windows about, like
/// switching desktops or apps. Each read takes a fraction of a millisecond.
@MainActor
final class CoverWatch {
    /// Called with a display and whether app windows now cover its desktop.
    var onChange: (CGDirectDisplayID, Bool) -> Void = { _, _ in }
    /// The displays to watch.
    var displays: [CGDirectDisplayID] = [] {
        didSet {
            let gone = Set(oldValue).subtracting(displays)
            for id in gone {
                debounces[id] = nil
                covered.remove(id)
            }
            if displays != oldValue { check() }
        }
    }
    /// The displays whose desktops app windows cover.
    private(set) var covered: Set<CGDirectDisplayID> = []
    /// How long app windows must cover a desktop before it counts. Switching between apps covers and uncovers it all
    /// the time; only a cover that stays should still the painting, or it would stop and start with every switch.
    static let confirm: TimeInterval = 2
    private var debounces: [CGDirectDisplayID: CoverDebounce] = [:]
    private var running = false
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    /// While a desktop is covered, a click anywhere may have moved or closed what covers it.
    private var clicks: Any?
    /// Each app's bundle, by process, for telling apps whose windows may be see-through.
    private var bundles: [pid_t: String] = [:]

    func start() {
        guard !running else { return }
        running = true
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            // Desktops slide past for a moment, so read again once they have settled.
            MainActor.assumeIsolated { self?.check(now: true, after: [0.35, 0.8]) }
        })
        let apps: [Notification.Name] = [NSWorkspace.didActivateApplicationNotification,
                                         NSWorkspace.didHideApplicationNotification,
                                         NSWorkspace.didUnhideApplicationNotification,
                                         NSWorkspace.didLaunchApplicationNotification]
        for name in apps {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(now: true, after: [0.35]) }
            })
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.bundles[pid] = nil }
                self?.check(now: true, after: [0.35])
            }
        })
        check()
    }

    /// Stops reading while nothing is drawn anyway, as the Mac is locked or asleep. What it knew stands until the next
    /// start reads again, so a desktop still covered then stays covered rather than flickering into view.
    func stop() {
        guard running else { return }
        running = false
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        timer?.invalidate()
        timer = nil
        interval = 0
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        // A cover read before must be read again for as long after, not count across the time stopped.
        for id in debounces.keys { debounces[id]?.restart() }
    }

    /// Reads now, and again after each of `delays` in seconds.
    func check(now: Bool = true, after delays: [TimeInterval]) {
        if now { check() }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        }
    }

    /// Reads the window list and updates every display.
    func check() {
        guard running else { return }
        let time = CACurrentMediaTime()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = list.compactMap { info -> DesktopCover.Window? in
            // Only ordinary app windows can count; skipping the rest early spares a bundle lookup.
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return DesktopCover.Window(frame: frame, alpha: info[kCGWindowAlpha as String] as? Double ?? 1, pid: pid,
                                       bundle: bundle(of: pid))
        }
        let rects = DesktopCover.covering(windows, ownPID: ProcessInfo.processInfo.processIdentifier)
        let watched = displays.compactMap { id in NSScreen.screens.first { $0.displayID == id }.map { (id, $0) } }
        let bounds = watched.map { CGDisplayBounds($0.0) }
        let over = DesktopCover.assign(rects, to: bounds, separateSpaces: NSScreen.screensHaveSeparateSpaces)
        var unconfirmed = false
        for (i, (id, screen)) in watched.enumerated() {
            let frame = screen.frame, visible = screen.visibleFrame
            let area = DesktopCover.area(bounds: bounds[i],
                                         top: max(frame.maxY - visible.maxY, screen.safeAreaInsets.top),
                                         left: visible.minX - frame.minX, bottom: visible.minY - frame.minY,
                                         right: frame.maxX - visible.maxX)
            let reading = DesktopCover.covers(over[i], area: area)
            var debounce = debounces[id] ?? CoverDebounce(confirm: Self.confirm)
            let counts = debounce.read(reading, at: time)
            debounces[id] = debounce
            if reading, !counts { unconfirmed = true }
            guard counts != covered.contains(id) else { continue }
            if counts { covered.insert(id) } else { covered.remove(id) }
            #if DEBUG
            Log.display.info("Display \(id) area \(String(describing: area), privacy: .public) under \(over[i].count) window(s): \(over[i].map { String(describing: $0) }.joined(separator: ", "), privacy: .public)")
            #endif
            onChange(id, counts)
        }
        // A first covered reading is confirmed by one once the cover has stayed, which needn't wait for the timer.
        if unconfirmed {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirm + 0.05) { [weak self] in self?.check() }
        }
        pace()
    }

    /// Reads every second while every desktop is in view, three times a second while one is covered.
    private func pace() {
        let wanted: TimeInterval = covered.isEmpty ? 1 : 0.33
        if wanted != interval {
            interval = wanted
            timer?.invalidate()
            let timer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            timer.tolerance = wanted * 0.2
            // The common modes, so it keeps reading while a menu is open.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if covered.isEmpty, let clicks {
            NSEvent.removeMonitor(clicks)
            self.clicks = nil
        } else if !covered.isEmpty, clicks == nil {
            clicks = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(now: false, after: [0.05, 0.4]) }
            }
        }
    }

    private func bundle(of pid: pid_t) -> String? {
        if let known = bundles[pid] { return known }
        // Only an app's is kept: a process that isn't one yet, or whose number an app takes later, is asked again.
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        bundles[pid] = bundle
        return bundle
    }
}
