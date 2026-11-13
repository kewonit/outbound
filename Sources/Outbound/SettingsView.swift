import AppKit
import OutboundCore
import ServiceManagement
import SwiftUI

/// The sections of Settings, down its sidebar as System Settings has them, each with its symbol on a colored square.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, power, license, about
    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .power: String(localized: "Saving Power")
        case .license: String(localized: "License")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .power: "bolt.fill"
        case .license: "key.fill"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general, .about: .gray
        case .power: .green
        case .license: .blue
        }
    }
}

/// Outbound's Settings, laid out as macOS's own: a sidebar with Outbound and its license on top, and the chosen
/// section's grouped settings beside it. It opens on the section open last.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var license: LicenseController
    /// What the menu's Check for Updates and Send Feedback do, so the buttons here do just the same.
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void
    let sendFeedback: () -> Void
    @AppStorage("settingsPane") private var pane: SettingsPane = .general

    var body: some View {
        // The sidebar always shows: System Settings has no way to hide it.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding<SettingsPane?>(get: { pane }, set: { if let chosen = $0 { pane = chosen } })) {
                // Outbound and its license, as the account sits over System Settings, and opens the License section.
                Button { pane = .license } label: { LicenseCard(license: license) }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)
                ForEach(SettingsPane.allCases) { pane in
                    Label { Text(pane.title) } icon: { Badge(symbol: pane.symbol, color: pane.color) }
                        .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            switch pane {
            case .general: GeneralPane(preferences: preferences)
            case .power: PowerPane(preferences: preferences)
            case .license: LicensePane(license: license)
            case .about: AboutPane(canCheckForUpdates: canCheckForUpdates, checkForUpdates: checkForUpdates,
                                   sendFeedback: sendFeedback)
            }
        }
        .frame(width: 740, height: 460)
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

/// When it holds still to save power: choices made once, so here rather than in the menu.
private struct PowerPane: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.restsWhenAway) {
                    Described("Hold still while I'm away", "Rests after five minutes with nobody at the Mac.")
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
                } else if license.record == nil {
                    LabeledContent("License", value: String(localized: "Not active on this Mac"))
                } else {
                    LabeledContent("License") {
                        HStack {
                            Text("Active on \(license.macName)").foregroundStyle(.secondary)
                            Button("Deactivate") { Task { await license.deactivate() } }
                                .disabled(license.busy)
                        }
                    }
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
        if license.record == nil { return String(localized: "Not active on this Mac") }
        return String(localized: "Active on \(license.macName)")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
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
