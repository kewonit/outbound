import Foundation
import IOKit.ps
import OutboundCore

/// Watches the power source, Low Power Mode and the thermal state.
@MainActor
final class PowerMonitor {
    private(set) var state = PowerState()
    var onChange: (PowerState) -> Void = { _ in }
    private var runLoopSource: CFRunLoopSource?

    init(batteryMode: PowerState.BatteryMode) {
        state.batteryMode = batteryMode
        read()
        let center = NotificationCenter.default
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.read() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    var batteryMode: PowerState.BatteryMode {
        get { state.batteryMode }
        set { update { $0.batteryMode = newValue } }
    }

    private func read() {
        update { state in
            state.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            state.thermal = switch ProcessInfo.processInfo.thermalState {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .serious
            }
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
            let source = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
            state.onBattery = source == kIOPSBatteryPowerValue
            #if DEBUG
            // OUTBOUND_POWER=ac or battery tries either tier whatever the Mac is running on.
            if let forced = ProcessInfo.processInfo.environment["OUTBOUND_POWER"] { state.onBattery = forced == "battery" }
            #endif
        }
    }

    private func update(_ change: (inout PowerState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        Log.power.info("Power \(String(describing: next), privacy: .public)")
        onChange(next)
    }
}
