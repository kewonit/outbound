#if DEV
import AppKit
import OutboundCore

/// Dev builds: everything the Developer panel can bring on or pretend, so each case can be tried without waiting for
/// it. Nothing here is saved; quitting puts it all back.
@MainActor
final class DevControls: ObservableObject {
    /// What only the app delegate can do.
    struct Actions {
        var fly: (Place) -> Void
        var paintDesktop: () -> Void
        var showActivation: () -> Void
        var previewThankYou: () -> Void
        var notice: (LicenseController.Claim) -> Void
        var diagnostics: () -> String
    }

    enum Cover: String, CaseIterable, Identifiable {
        case open = "Open", edge = "Just Hidden", hidden = "Hidden"
        var id: Self { self }
        var coverage: Double {
            switch self {
            case .open: 0
            case .edge: DesktopCover.hidden
            case .hidden: 1
            }
        }
    }

    static let flocks: [(name: String, flock: Flock)] = [("Geese", .geese), ("Swans", .swans), ("Cranes", .cranes),
                                                          ("Flamingos", .flamingos), ("Egrets", .egrets),
                                                          ("Rooks", .rooks), ("Vultures", .vultures)]
    static let licenses: [(name: String, status: LicenseStatus)] = [("Unlicensed", .unlicensed), ("Valid", .valid),
                                                                    ("Needs Check", .needsCheck), ("Lapsed", .lapsed)]
    static let notices: [(name: String, claim: LicenseController.Claim)] = [
        ("Unlocked with the new key", .activated), ("Already unlocked", .alreadyActive),
        ("Still processing", .waiting), ("Didn't unlock", .failed),
    ]

    private let displays: DisplayManager
    private let license: LicenseController
    private let gpu: GPU
    private let preferences: Preferences
    private let sessionEnd: SessionEndWatch
    private let actions: Actions
    private var world: World { displays.world }
    private let usualCloudCover: Double
    private let usualNote: String?

    init(displays: DisplayManager, license: LicenseController, gpu: GPU, preferences: Preferences,
         sessionEnd: SessionEndWatch, actions: Actions) {
        self.displays = displays
        self.license = license
        self.gpu = gpu
        self.preferences = preferences
        self.sessionEnd = sessionEnd
        self.actions = actions
        usualCloudCover = displays.world.cloudCover
        usualNote = displays.note
        cloudCover = usualCloudCover
    }

    // MARK: - What is pretended

    @Published var timeScale = 1.0 {
        didSet {
            guard timeScale != oldValue else { return }
            world.setTimeScale(timeScale)
        }
    }
    /// The hour of the day, in hours, instead of the clock's; the light follows it as Your Time does.
    @Published var hour: Double? {
        didSet {
            guard hour != oldValue else { return }
            clockChanged()
        }
    }
    /// The month instead of the clock's; the seasons follow it, as with What is growing there today.
    @Published var month: Int? {
        didSet {
            guard month != oldValue else { return }
            clockChanged()
        }
    }
    @Published var cloudCover: Double {
        didSet {
            guard cloudCover != oldValue else { return }
            world.cloudCover = cloudCover
            displays.refreshClouds()
        }
    }
    @Published var cloudSpeed = 1.0 {
        didSet {
            guard cloudSpeed != oldValue else { return }
            world.setCloudSpeed(cloudSpeed)
        }
    }
    @Published var power: PowerMonitor.Forced? {
        didSet {
            guard power != oldValue else { return }
            displays.power.forced = power
        }
    }
    @Published var cover: Cover? {
        didSet {
            guard cover != oldValue else { return }
            displays.cover.forcedCoverage = cover?.coverage
        }
    }
    @Published var frameRate: Double? {
        didSet {
            guard frameRate != oldValue else { return }
            displays.forcedRate = frameRate
        }
    }
    @Published var smallPieces = false {
        didSet {
            guard smallPieces != oldValue else { return }
            gpu.paintsInSmallPieces = smallPieces
        }
    }
    @Published var asleep = false {
        didSet {
            guard asleep != oldValue else { return }
            quietly { displays.set(.asleep, asleep) }
        }
    }
    @Published var locked = false {
        didSet {
            guard locked != oldValue else { return }
            quietly {
                displays.set(.locked, locked)
                displays.onLockChange(locked)
            }
        }
    }
    @Published var licenseStatus: LicenseStatus? {
        didSet {
            guard licenseStatus != oldValue else { return }
            license.simulate(licenseStatus)
        }
    }
    /// The gull chases a pointer that circles the main display, as if someone were moving the mouse over the desktop.
    @Published var chasing = false {
        didSet {
            guard chasing != oldValue else { return }
            if chasing {
                let home = world.home, start = CACurrentMediaTime()
                world.isDesktop = { _ in true }
                world.pointer = {
                    let t = CACurrentMediaTime() - start
                    return CGPoint(x: home.midX + cos(t * 1.3) * home.width * 0.3,
                                   y: home.midY + sin(t * 1.7) * home.height * 0.3)
                }
            } else {
                world.pointer = { NSEvent.mouseLocation }
                world.isDesktop = { World.desktopIsUnder($0) }
            }
        }
    }
    /// A short readout in the corner of the desktop, under the place's name, for screenshots and recordings.
    @Published var showsOnDesktop = false {
        didSet {
            if !showsOnDesktop { displays.note = usualNote }
            tick()
            pace()
        }
    }
    /// What the last action did, or why it couldn't.
    @Published var message: String?
    @Published private(set) var readout: [String] = []

    /// A sleep, lock or rest pretended here is no time to install an update over the dev build.
    private(set) var simulatingQuiet = false

    private func quietly(_ change: () -> Void) {
        simulatingQuiet = true
        change()
        simulatingQuiet = false
    }

    /// What is pretended, by name, or nothing.
    var overrides: [String] {
        var names: [String] = []
        if timeScale != 1 { names.append("×\(Self.number(timeScale))") }
        if hour != nil { names.append("hour") }
        if month != nil { names.append("month") }
        if cloudCover != usualCloudCover { names.append("cloud cover") }
        if cloudSpeed != 1 { names.append("cloud speed") }
        if let power { names.append(power.rawValue.lowercased()) }
        if let cover { names.append("desktop \(cover.rawValue.lowercased())") }
        if let frameRate { names.append("\(Self.number(frameRate)) fps") }
        if smallPieces { names.append("small pieces") }
        if asleep { names.append("asleep") }
        if locked { names.append("locked") }
        if let licenseStatus { names.append("license \(String(describing: licenseStatus))") }
        if chasing { names.append("pretend pointer") }
        return names
    }

    // MARK: - The clock

    private func clockChanged() {
        if hour == nil, month == nil {
            world.now = { .now }
        } else {
            let calendar = Calendar.current
            let now = Date()
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
            if let month {
                parts.month = month
                parts.day = min(parts.day ?? 1, 28)
            }
            if let hour {
                parts.hour = Int(hour)
                parts.minute = Int(((hour - hour.rounded(.down)) * 60).rounded())
                parts.second = 0
            }
            let offset = (calendar.date(from: parts) ?? now).timeIntervalSince(now)
            world.now = { Date().addingTimeInterval(offset) }
        }
        imposeLook()
        world.journey.refreshSeasons(date: world.now())
        world.seasonsChanged()
        if world.isHeld { displays.repaintHeld() }
    }

    /// An hour set here needs the light to follow the clock, and a month the seasons to follow the calendar, whatever
    /// the menu says; without them, the menu has its way.
    private func imposeLook() {
        world.light = hour != nil ? .yourTime : preferences.light
        world.journey.followsCalendar = month != nil || preferences.followsCalendar
    }

    /// Puts back what applying the preferences just undid.
    func reapply() {
        guard hour != nil || month != nil else { return }
        let followed = world.journey.followsCalendar
        imposeLook()
        if world.journey.followsCalendar != followed {
            world.journey.refreshSeasons(date: world.now())
            world.seasonsChanged()
        }
    }

    // MARK: - Bringing things on

    func nextPlace() {
        if world.moveOn() {
            message = world.isHeld ? "The next place comes on once the flight moves again."
                : "The next place is coming in from the top."
        } else {
            message = "A band is in view. Try again once it has gone."
        }
    }

    func fly(to place: Place) {
        actions.fly(place)
        message = "Flying to \(place.name)."
    }

    func skip(_ seconds: TimeInterval) {
        guard !world.isHeld else {
            message = "Held still: skipping shows nothing until the flight moves."
            return
        }
        world.skip(seconds)
        message = "Skipped \(Self.duration(seconds))."
    }

    func bringFlock(_ flock: Flock?, named name: String) {
        guard let flock = flock ?? world.flockHere else {
            message = "No flock flies over this place this month."
            return
        }
        world.bringFlock(flock)
        message = "\(name) coming over."
    }

    var flockHere: Flock? { world.flockHere }

    func bringTrain() {
        guard !world.isHeld else {
            message = "Held still: the train comes once the flight moves."
            return
        }
        guard let ahead = world.trainAhead() else {
            message = "No railway ahead in this place. Try Next Place Now, then again."
            return
        }
        // So the nose comes into view and reaches the middle of the display a few seconds on.
        if ahead > 12 { world.skip(ahead - 12) }
        message = "Train coming through."
    }

    func awayNow() {
        guard preferences.restsWhenAway else {
            message = "Hold still while I'm away is off in Settings."
            return
        }
        quietly { displays.rest.restNow() }
        message = "Resting. Move the mouse outside this panel to wake it."
    }

    func shutdownAsked() {
        sessionEnd.heard("com.apple.shutdownInitiated")
        message = "Asked to shut down: the flight comes to rest."
    }

    func shutdownCancelled() {
        sessionEnd.heard("com.apple.logoutCancelled")
        message = "Shutdown cancelled: the flight carries on."
    }

    func repaint() {
        world.repaint()
        if world.isHeld { displays.repaintHeld() }
    }

    func repaintAtOnce() {
        displays.repaintHeld()
    }

    func paintDesktop() {
        actions.paintDesktop()
        message = "Asked for a new desktop picture."
    }

    func showActivation() { actions.showActivation() }

    func previewThankYou() { actions.previewThankYou() }

    func notice(_ claim: LicenseController.Claim) { actions.notice(claim) }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(actions.diagnostics(), forType: .string)
        message = "Copied the diagnostics line."
    }

    func resetSettings() {
        preferences.resetToDefaults()
        message = "Settings are back to their defaults."
    }

    /// Everything back as it runs, and a fresh desktop picture, so nothing pretended stays on the desktop or the lock
    /// screen.
    func resetEverything() {
        world.clearDevOverrides()
        timeScale = 1
        cloudSpeed = 1
        hour = nil
        month = nil
        cloudCover = usualCloudCover
        power = nil
        cover = nil
        frameRate = nil
        smallPieces = false
        asleep = false
        locked = false
        licenseStatus = nil
        chasing = false
        showsOnDesktop = false
        actions.paintDesktop()
        message = "Everything is back as it runs."
    }

    // MARK: - Readout

    /// Whether the panel is open, which is when the readout needs reading.
    var panelOpen = false {
        didSet {
            tick()
            pace()
        }
    }
    private var timer: Timer?

    private func pace() {
        let wanted = panelOpen || showsOnDesktop
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let world = world
        let mpp = World.metresPerPoint
        let bottom = world.camera.y + Double(world.desktop.minY) * mpp
        let top = world.camera.y + Double(world.desktop.maxY) * mpp
        let middle = world.camera.y + Double(world.home.midY) * mpp
        let leg = world.journey.leg(at: middle)
        let speed = world.journey.speed * world.timeScale
        let ahead: String
        if let join = world.journey.joins.first(where: { $0 > middle }) {
            let metres = join - top
            let minutes = speed > 0 ? " (\(Self.duration(max(metres, 0) / speed)))" : ""
            ahead = metres > 0 ? "next place \(Int(metres)) m above\(minutes)" : "next place in view"
        } else {
            ahead = world.journey.staysPut ? "stays over this place" : "next place not laid out yet"
        }
        let band = world.bank(from: bottom, to: top) != nil ? "band in view" : "no band"
        let clock = world.now().formatted(date: .abbreviated, time: .shortened)
        let night = Int((world.sun.night * 100).rounded())
        let elevation = Int((world.sun.elevation * 180 / .pi).rounded())
        let holds = displays.holdNames
        let rates = displays.wallpapers.values.map { Self.number(Double($0.framesPerSecond)) }.sorted()
        let power = displays.power.state
        let powerLine = [power.onBattery ? "battery" : "plugged in", power.lowPower ? "low power" : nil,
                         power.thermal == .nominal ? nil : "\(power.thermal)"].compactMap { $0 }.joined(separator: ", ")
        let lines = [
            "\(leg.place.name) · \(leg.season.line) · leg \(leg.index)",
            "t \(Int(world.time)) s · \(Self.number(world.journey.speed)) m/s ×\(Self.number(world.timeScale))"
                + (world.isHeld ? " · held" : ""),
            "\(ahead) · \(band)",
            "\(clock) · \(world.light) · sun \(elevation)° · night \(night)%",
            "clouds \(Self.number(world.cloudCover)) ×\(Self.number(world.cloudSpeed))"
                + (world.flock.map { " · flock \($0.0.formation)" } ?? "") + (world.trainPassing ? " · train" : ""),
            "holds \(holds.isEmpty ? "none" : holds.joined(separator: ", ")) · \(powerLine) · \(rates.joined(separator: "/")) fps",
            "pieces of \(gpu.texelsPerPiece / 1000)k texels · \(Int(gpu.groundCost.millisecondsPerMillion.rounded())) ms a million",
            overrides.isEmpty ? "nothing pretended" : "pretending: \(overrides.joined(separator: ", "))",
        ]
        if lines != readout { readout = lines }
        if showsOnDesktop {
            displays.note = "\(leg.index) · t \(Int(world.time)) ×\(Self.number(world.timeScale)) · "
                + "\(world.now().formatted(date: .omitted, time: .shortened))"
                + (overrides.isEmpty ? "" : " · \(overrides.joined(separator: ", "))")
        }
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(Int(seconds.rounded())) s" : "\(Int((seconds / 60).rounded())) min"
    }
}
#endif
