import AppKit
import OutboundCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let license: LicenseController
    let restoreWallpaper: () -> Void
    let canRestore: Bool
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Light", selection: $preferences.light) {
                    ForEach(World.Light.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Seasons", selection: $preferences.followsCalendar) {
                    Text("What is growing there today").tag(true)
                    Text("Each place at its best").tag(false)
                }
                Picker("Pace", selection: $preferences.pace) {
                    ForEach(Preferences.Pace.allCases) { Text($0.title).tag($0) }
                }
                Picker("Stay over each place", selection: $preferences.stay) {
                    ForEach(Preferences.Stay.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker("On battery", selection: $preferences.batteryMode) {
                    Text("Keep flying, gently").tag(PowerState.BatteryMode.gentle)
                    Text("Hold a still painting").tag(PowerState.BatteryMode.still)
                }
                Toggle("Show the painting on the lock screen", isOn: $preferences.matchingStill)
                LabeledContent("Desktop picture") {
                    Button("Restore My Old Wallpaper", action: restoreWallpaper)
                        .disabled(!canRestore)
                }
                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
            }
            Section {
                if !LicenseController.isGated {
                    LabeledContent("License", value: "Development build")
                } else if license.record != nil {
                    LabeledContent("License") {
                        HStack {
                            Text("Active on \(license.macName)").foregroundStyle(.secondary)
                            Button("Deactivate") { Task { await license.deactivate() } }
                                .disabled(license.busy)
                        }
                    }
                }
                if let message = license.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Outbound pauses whenever the desktop is hidden, the screen sleeps or Low Power Mode is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
