#if DEV
import AppKit
import OutboundCore
import SwiftUI

/// Dev builds: a floating panel with every developer control, opened from the gull's menu. Closing it keeps whatever
/// it pretends; Reset Everything or quitting puts it back.
@MainActor
final class DevPanel {
    private let panel: NSPanel
    private let controls: DevControls
    private var observer: NSObjectProtocol?

    init(controls: DevControls) {
        self.controls = controls
        panel = NSPanel(contentViewController: NSHostingController(rootView: DevPanelView(controls: controls)))
        panel.title = "Developer"
        panel.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        panel.isFloatingPanel = true
        // Outbound is seldom the active app, and the panel should stay up while you look at the desktop.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.opensWhereTheUserIs()
        if !panel.setFrameUsingName("Developer") { panel.center() }
        panel.setFrameAutosaveName("Developer")
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel,
                                                          queue: .main) { [weak controls] _ in
            MainActor.assumeIsolated { controls?.panelOpen = false }
        }
    }

    func show() {
        controls.panelOpen = true
        panel.bringForward()
    }
}

/// Words in the panel are the developer's, in English, and never go into the app's string catalogue.
private func words(_ text: String) -> Text { Text(verbatim: text) }

private struct DevPanelView: View {
    @ObservedObject var controls: DevControls
    @State private var hourDraft = Double(Calendar.current.component(.hour, from: .now))
    @State private var confirmsReset = false

    var body: some View {
        Form {
            readout
            journey
            sky
            scene
            power
            painting
            license
            Section {
                HStack {
                    Button { confirmsReset = true } label: { words("Reset Settings to Defaults…") }
                        .confirmationDialog(Text(verbatim: "Put every setting back to its default?"),
                                            isPresented: $confirmsReset) {
                            Button(role: .destructive) { controls.resetSettings() } label: { words("Reset Settings") }
                        }
                    Spacer()
                    Button { controls.resetEverything() } label: { words("Reset Everything") }
                        .keyboardShortcut(.defaultAction)
                }
            } footer: {
                words("Reset Everything stops pretending anything and paints the desktop picture afresh. Quitting does too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 460, minHeight: 420, idealHeight: 760)
    }

    private var readout: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(controls.readout.enumerated()), id: \.offset) { _, line in
                    words(line).font(.system(.caption, design: .monospaced))
                }
            }
            .textSelection(.enabled)
            HStack {
                Toggle(isOn: $controls.showsOnDesktop) { words("Show on the Desktop") }
                Spacer()
                Button { controls.copyDiagnostics() } label: { words("Copy Diagnostics") }
            }
            if let message = controls.message {
                words(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: { words("Now") }
    }

    private var journey: some View {
        Section {
            HStack {
                Button { controls.nextPlace() } label: { words("Next Place Now") }
                Menu {
                    ForEach(Place.all, id: \.id) { place in
                        Button { controls.fly(to: place) } label: { words(place.name) }
                    }
                } label: { words("Fly To") }
                .fixedSize()
                Spacer()
            }
            HStack {
                words("Skip ahead")
                Spacer()
                ForEach([(10.0, "10 s"), (60, "1 min"), (600, "10 min")], id: \.0) { seconds, name in
                    Button { controls.skip(seconds) } label: { words(name) }
                }
            }
            Picker(selection: $controls.timeScale) {
                ForEach([1.0, 2, 5, 10, 30, 60], id: \.self) { words("×\(DevControls.number($0))").tag($0) }
            } label: { words("Fast-forward") }
            .pickerStyle(.segmented)
        } header: { words("Journey") }
    }

    private var sky: some View {
        Section {
            Toggle(isOn: Binding(get: { controls.hour != nil },
                                 set: { controls.hour = $0 ? hourDraft : nil })) {
                words("Hour of the Day")
            }
            HStack {
                Slider(value: $hourDraft, in: 0...23.75, step: 0.25) { editing in
                    if !editing, controls.hour != nil { controls.hour = hourDraft }
                } label: { EmptyView() }
                words(String(format: "%02d:%02d", Int(hourDraft), Int((hourDraft - hourDraft.rounded(.down)) * 60)))
                    .font(.system(.body, design: .monospaced))
            }
            .disabled(controls.hour == nil)
            Picker(selection: $controls.month) {
                words("Real").tag(Int?.none)
                ForEach(1...12, id: \.self) { words(Calendar.current.monthSymbols[$0 - 1]).tag(Int?.some($0)) }
            } label: { words("Month") }
            HStack {
                words("Cloud Cover")
                Slider(value: $controls.cloudCover, in: 0...1) { EmptyView() }
                words(DevControls.number(controls.cloudCover)).font(.system(.body, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
            Picker(selection: $controls.cloudSpeed) {
                ForEach([0.0, 0.5, 1, 2, 3], id: \.self) { words("×\(DevControls.number($0))").tag($0) }
            } label: { words("Cloud Speed") }
            .pickerStyle(.segmented)
        } header: { words("Sky") } footer: {
            words("An hour lights the land as Your Time does; a month sets the seasons as the calendar does.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scene: some View {
        Section {
            HStack {
                Menu {
                    Button { controls.bringFlock(nil, named: "This place's flock") } label: { words("This Place's Own") }
                        .disabled(controls.flockHere == nil)
                    Divider()
                    ForEach(DevControls.flocks, id: \.name) { name, flock in
                        Button { controls.bringFlock(flock, named: name) } label: { words(name) }
                    }
                } label: { words("Flock Now") }
                .fixedSize()
                Button { controls.bringTrain() } label: { words("Skip to the Train") }
                Spacer()
            }
            Toggle(isOn: $controls.chasing) { words("Gull Chases a Pretend Pointer") }
        } header: { words("Scene") }
    }

    private var power: some View {
        Section {
            Picker(selection: $controls.power) {
                words("Real").tag(PowerMonitor.Forced?.none)
                ForEach(PowerMonitor.Forced.allCases, id: \.self) { words($0.rawValue).tag(PowerMonitor.Forced?.some($0)) }
            } label: { words("Power") }
            Picker(selection: $controls.cover) {
                words("Real").tag(DevControls.Cover?.none)
                ForEach(DevControls.Cover.allCases) { words($0.rawValue).tag(DevControls.Cover?.some($0)) }
            } label: { words("Desktop Under Windows") }
            Picker(selection: $controls.frameRate) {
                words("Real").tag(Double?.none)
                ForEach([20.0, 24, 30, 60], id: \.self) { words("\(DevControls.number($0)) fps").tag(Double?.some($0)) }
            } label: { words("Frame Rate") }
            Toggle(isOn: $controls.asleep) { words("Screens Asleep") }
            Toggle(isOn: $controls.locked) { words("Locked") }
            HStack {
                Button { controls.awayNow() } label: { words("Away Now") }
                Spacer()
                Button { controls.shutdownAsked() } label: { words("Shutdown Asked") }
                Button { controls.shutdownCancelled() } label: { words("Shutdown Cancelled") }
            }
        } header: { words("Power and Holds") } footer: {
            words("Hidden holds the flight only while Pause When Hidden is on. Asleep, locked and away never install an update here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var painting: some View {
        Section {
            HStack {
                Button { controls.repaint() } label: { words("Repaint") }
                Button { controls.repaintAtOnce() } label: { words("Repaint at Once") }
                Spacer()
                Button { controls.paintDesktop() } label: { words("Write Desktop Picture") }
            }
            Toggle(isOn: $controls.smallPieces) { words("Paint the Ground in the Smallest Pieces") }
        } header: { words("Painting") } footer: {
            words("Repaint sweeps down the view as a change of light does; at once paints it all before the next frame.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var license: some View {
        Section {
            Picker(selection: $controls.licenseStatus) {
                words("Real").tag(LicenseStatus?.none)
                ForEach(DevControls.licenses, id: \.name) { name, status in words(name).tag(LicenseStatus?.some(status)) }
            } label: { words("License") }
            HStack {
                Button { controls.showActivation() } label: { words("Show Activation") }
                Button { controls.previewThankYou() } label: { words("Show Thank You") }
                Spacer()
                Menu {
                    ForEach(DevControls.notices, id: \.name) { name, claim in
                        Button { controls.notice(claim) } label: { words(name) }
                    }
                } label: { words("Notice") }
                .fixedSize()
            }
        } header: { words("License") } footer: {
            words("Unlicensed and Lapsed lock the wallpaper and put your pictures back, as a real lapse would.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
