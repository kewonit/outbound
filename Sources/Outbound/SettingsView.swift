import AppKit
import OutboundCore
import ServiceManagement
import SwiftUI

/// The sections of Settings, down its sidebar as System Settings has them, each with its symbol on a colored square.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, flight, places, power, license, about
    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .flight: String(localized: "Flight")
        case .places: String(localized: "Places")
        case .power: String(localized: "Saving Power")
        case .license: String(localized: "License")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .flight: "bird.fill"
        case .places: "map.fill"
        case .power: "bolt.fill"
        case .license: "key.fill"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general, .about: .gray
        case .flight: .cyan
        case .places: .orange
        case .power: .green
        case .license: .blue
        }
    }

    /// The sidebar's groups, with a gap between them as System Settings has: what it does, then the app itself.
    static let groups: [[SettingsPane]] = [[.general, .flight, .places, .power], [.license, .about]]
}

/// Which section of Settings is open, shared by the sidebar and the section beside it, and kept for next time.
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var pane: SettingsPane {
        didSet {
            defaults.set(pane.rawValue, forKey: "settingsPane")
            onChange(pane)
        }
    }
    var onChange: (SettingsPane) -> Void = { _ in }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pane = defaults.string(forKey: "settingsPane").flatMap(SettingsPane.init(rawValue:)) ?? .general
    }
}

/// Outbound's Settings window, made as System Settings is: AppKit's own sidebar, which runs up behind the window's
/// buttons, the open section beside it, and its name in the toolbar over that. It reopens on the section open last,
/// can be closed and minimised, not zoomed, and the sidebar can't be hidden.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let selection = SettingsSelection()

    init(preferences: Preferences, license: LicenseController, canCheckForUpdates: Bool,
         checkForUpdates: @escaping () -> Void, sendFeedback: @escaping () -> Void) {
        let split = NSSplitViewController()
        split.splitView = SeamlessSplitView()
        split.splitView.isVertical = true
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(
            rootView: SettingsSidebar(selection: selection, license: license)))
        sidebar.canCollapse = false
        sidebar.minimumThickness = 215
        sidebar.maximumThickness = 215
        let detail = NSSplitViewItem(viewController: NSHostingController(
            rootView: SettingsDetail(selection: selection, preferences: preferences, license: license,
                                     canCheckForUpdates: canCheckForUpdates, checkForUpdates: checkForUpdates,
                                     sendFeedback: sendFeedback)))
        detail.minimumThickness = Self.size.width - sidebar.minimumThickness
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(detail)

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.setContentSize(Self.size)
        // The window is named after the section open, for the toolbar, the Window menu and Mission Control.
        window.title = selection.pane.title
        selection.onChange = { [weak window] in window?.title = $0.title }
    }

    static let size = NSSize(width: 740, height: 560)

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The title sits over the section rather than over the sidebar, as it does in System Settings.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
}

/// The sidebar meets the section with no line drawn between them, as in System Settings.
private final class SeamlessSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }
}

/// Outbound and its license on top, as the account sits over System Settings, then the sections in two groups.
struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsSelection
    @ObservedObject var license: LicenseController

    var body: some View {
        List(selection: Binding<SettingsPane?>(get: { selection.pane }, set: { if let chosen = $0 { selection.pane = chosen } })) {
            // Opens the License section.
            Section {
                Button { selection.pane = .license } label: { LicenseCard(license: license) }
                    .buttonStyle(.plain)
            }
            ForEach(SettingsPane.groups, id: \.self) { group in
                Section {
                    ForEach(group) { pane in
                        Label { Text(pane.title) } icon: { Badge(symbol: pane.symbol, color: pane.color) }
                            .padding(.vertical, 2)
                            .tag(pane)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // The sidebar's own material shows through, as in System Settings, rather than the list's grey.
        .scrollContentBackground(.hidden)
    }
}

/// The open section's settings, grouped as System Settings has them.
struct SettingsDetail: View {
    @ObservedObject var selection: SettingsSelection
    @ObservedObject var preferences: Preferences
    @ObservedObject var license: LicenseController
    /// What the menu's Check for Updates and Send Feedback do, so the buttons here do just the same.
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void
    let sendFeedback: () -> Void

    var body: some View {
        switch selection.pane {
        case .general: GeneralPane(preferences: preferences)
        case .flight: FlightPane(preferences: preferences)
        case .places: PlacesPane(preferences: preferences)
        case .power: PowerPane(preferences: preferences)
        case .license: LicensePane(license: license)
        case .about: AboutPane(canCheckForUpdates: canCheckForUpdates, checkForUpdates: checkForUpdates,
                               sendFeedback: sendFeedback)
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var preferences: Preferences
    @State private var opensAtLogin = LoginItem.isOn

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.matchingStill) {
                    Described("Show the painting on the lock screen", "A still of the current view, kept as the desktop picture.")
                }
                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
            } footer: {
                Text("Fly To, light, season and speed are in the menu bar, under the seagull.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private func setOpensAtLogin(_ on: Bool) {
        LoginItem.set(on)
        opensAtLogin = LoginItem.isOn
    }
}

/// How the flight goes and what the gull does.
private struct FlightPane: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.fliesStraight) {
                    Described("Fly straight", "The land comes straight down the screen, without drifting from side to side.")
                }
            }
            Section {
                Toggle("Show the seagull", isOn: $preferences.showsBird)
                Toggle(isOn: $preferences.followsPointer) {
                    Described("Seagull follows the pointer", "For a few seconds after the pointer moves over the desktop.")
                }
                .disabled(!preferences.showsBird)
            }
        }
        .formStyle(.grouped)
    }
}

/// Which places the flight moves on to, in the order it flies them, and whether it goes in that order. The order is
/// changed in a sheet of its own, as macOS orders network services.
private struct PlacesPane: View {
    @ObservedObject var preferences: Preferences
    @State private var changingOrder = false

    private var places: [Place] {
        preferences.placeOrder.compactMap(Place.named)
    }

    var body: some View {
        Form {
            Section {
                Picker("Order", selection: $preferences.shufflesPlaces) {
                    Text("In Order").tag(false)
                    Text("Shuffled").tag(true)
                }
            }
            Section {
                ForEach(places, id: \.id) { place in
                    Toggle(isOn: visits(place)) { Text(verbatim: place.name) }
                        // The round always keeps one place.
                        .disabled(isOnlyOneLeft(place))
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Change Order…") { changingOrder = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $changingOrder) {
            PlaceOrderSheet(order: preferences.placeOrder, skipped: preferences.skippedPlaces) { order in
                if order != preferences.placeOrder { preferences.placeOrder = order }
            }
        }
    }

    private func visits(_ place: Place) -> Binding<Bool> {
        Binding(get: { !preferences.skippedPlaces.contains(place.id) },
                set: { on in
                    if on { preferences.skippedPlaces.remove(place.id) } else { preferences.skippedPlaces.insert(place.id) }
                })
    }

    private func isOnlyOneLeft(_ place: Place) -> Bool {
        !preferences.skippedPlaces.contains(place.id)
            && Place.all.allSatisfy { $0.id == place.id || preferences.skippedPlaces.contains($0.id) }
    }
}

/// The places numbered in the order they come, to drag or move one step at a time with the arrows. Nothing changes
/// until Done; Cancel leaves the order as it was. Places left out keep their position, dimmed.
private struct PlaceOrderSheet: View {
    @State private var order: [String]
    let skipped: Set<String>
    let done: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    init(order: [String], skipped: Set<String>, done: @escaping ([String]) -> Void) {
        _order = State(initialValue: order)
        self.skipped = skipped
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag places into the order you want.")
            List {
                ForEach(Array(order.enumerated()), id: \.element) { index, id in
                    row(index: index, id: id)
                }
                .onMove { from, to in order.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 8 * 28 + 6)
            HStack {
                Button("Restore Default Order") { withAnimation { order = Preferences.usualOrder } }
                    .disabled(order == Preferences.usualOrder)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    done(order)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(index: Int, id: String) -> some View {
        HStack(spacing: 10) {
            Text(index + 1, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(verbatim: Place.named(id)?.name ?? id)
                .foregroundStyle(skipped.contains(id) ? .secondary : .primary)
            Spacer()
            Button { move(id, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help(Text("Move Up"))
                .accessibilityLabel(Text("Move Up"))
            Button { move(id, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == order.count - 1)
                .help(Text("Move Down"))
                .accessibilityLabel(Text("Move Down"))
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    private func move(_ id: String, by step: Int) {
        guard let from = order.firstIndex(of: id) else { return }
        let to = from + step
        guard order.indices.contains(to) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { order.swapAt(from, to) }
    }
}

/// When it holds still to save power: choices made once, so here rather than in the menu.
private struct PowerPane: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker(selection: $preferences.away) {
                    ForEach(Preferences.Away.allCases) { Text($0.title).tag($0) }
                } label: {
                    Described("Hold still while I'm away", "When nobody has used the Mac for a while.")
                }
                Toggle(isOn: $preferences.pausesWhenHidden) {
                    Described("Hold still while windows cover the desktop", "When every display is covered, as by full-screen apps.")
                }
            }
            // A section of its own: as a third row under the two above, it set the whole pane 6 points lower than every
            // other one.
            Section {
                Picker("On battery", selection: $preferences.batteryMode) {
                    ForEach(PowerState.BatteryMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LicensePane: View {
    @ObservedObject var license: LicenseController

    var body: some View {
        Form {
            Section {
                if !LicenseController.isGated {
                    LabeledContent("License", value: String(localized: "Development build"))
                } else if license.record == nil || !license.unlocks {
                    // A key refunded, or not checked for too long, is kept but no longer unlocks it; the line in red
                    // below says which.
                    LabeledContent("License", value: String(localized: "Not active on this Mac"))
                } else {
                    LabeledContent("License") {
                        HStack {
                            Text("Active on \(license.macName)").foregroundStyle(.secondary)
                            Button("Deactivate") { Task { await license.deactivate() } }
                                .disabled(license.busy)
                        }
                    }
                }
                if LicenseController.isGated, license.record != nil {
                    LabeledContent("Your key and Macs") {
                        Link("Customer Portal", destination: Store.portalURL)
                    }
                }
                if let message = license.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Which version this is and what it does by itself, then the site, help, feedback and updates.
private struct AboutPane: View {
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void
    let sendFeedback: () -> Void

    private static let website = URL(string: "https://outbound.edbn.me")!
    private static let support = URL(string: "https://outbound.edbn.me/support")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("It pauses by itself while you're away.")
                    Text("Quit it and your own desktop picture comes back.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("Website") { Link(destination: Self.website) { Text(verbatim: "outbound.edbn.me") } }
                LabeledContent("Support") { Link(destination: Self.support) { Text(verbatim: "outbound.edbn.me/support") } }
                LabeledContent("Feedback") { Button("Send Feedback…", action: sendFeedback) }
                LabeledContent("Updates") {
                    Button("Check for Updates…", action: checkForUpdates).disabled(!canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Outbound's icon, name and license, at the top of the sidebar.
private struct LicenseCard: View {
    @ObservedObject var license: LicenseController

    private var state: String {
        if !LicenseController.isGated { return String(localized: "Development build") }
        if license.record == nil || !license.unlocks { return String(localized: "Not active on this Mac") }
        return String(localized: "Active on \(license.macName)")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Outbound").font(.headline)
                Text(state).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

/// A section's symbol on a colored rounded square, as System Settings draws them.
private struct Badge: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.gradient))
    }
}

/// A setting's name with a line under it saying what it does.
private struct Described: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    init(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        // Longer languages wrap rather than cut the words off.
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Whether Outbound opens at login. macOS keeps this, not Outbound's preferences.
@MainActor
enum LoginItem {
    static var isOn: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        guard on != isOn else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
