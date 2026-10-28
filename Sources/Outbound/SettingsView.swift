import AppKit
import OutboundCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var license: LicenseController
    /// What the menu's Check for Updates and Feedback do, so the buttons here do just the same.
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void
    let sendFeedback: () -> Void
    @State private var opensAtLogin = LoginItem.isOn

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.restsWhenAway) {
                    Described("Hold still while I'm away", "Rests after five minutes with nobody at the Mac.")
                }
                Toggle(isOn: $preferences.matchingStill) {
                    Described("Show the painting on the lock screen", "A still of the current view, kept as the desktop picture.")
                }
                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
            } footer: {
                Text("Light, seasons, pace and the rest of the choices are in the menu bar, under the gull.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            } footer: {
                AboutFooter(canCheckForUpdates: canCheckForUpdates, checkForUpdates: checkForUpdates,
                            sendFeedback: sendFeedback)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    private func setOpensAtLogin(_ on: Bool) {
        LoginItem.set(on)
        opensAtLogin = LoginItem.isOn
    }
}

/// Under the settings: which Outbound this is, what it does by itself, and buttons for the site, help, feedback and
/// updates, centred, as an About window has them.
struct AboutFooter: View {
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void
    let sendFeedback: () -> Void

    private static let website = URL(string: "https://outbound.edbn.me")!
    private static let support = URL(string: "https://outbound.edbn.me/support")!

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: .outboundGull)
                .renderingMode(.template)
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Outbound \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Text("It pauses by itself while you're away.")
                Text("Quit it and your own desktop picture comes back.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // The same width each where the words allow, so the row sits even.
            HStack(spacing: 8) {
                Button { NSWorkspace.shared.open(Self.website) } label: { Text("Website").frame(minWidth: 72) }
                Button { NSWorkspace.shared.open(Self.support) } label: { Text("Support").frame(minWidth: 72) }
                Button(action: sendFeedback) { Text("Feedback").frame(minWidth: 72) }
            }
            .padding(.top, 8)
            Button("Check for Updates…", action: checkForUpdates)
                .disabled(!canCheckForUpdates)
                .padding(.top, 2)
        }
        .buttonStyle(.bordered)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
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
