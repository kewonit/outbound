import AppKit
@preconcurrency import Sparkle

/// Keeps Outbound up to date. Sparkle checks the site's appcast once a day, downloads a new version in the
/// background, checks its signature, and holds it until nobody is looking, when the screens are asleep or locked
/// or the Mac has been left alone. Then it installs and Outbound relaunches. Development builds never update.
@MainActor
final class Updates: NSObject {
    private var controller: SPUStandardUpdaterController!
    /// An update downloaded and waiting for a quiet moment.
    private var install: (() -> Void)?
    /// Whether nobody is watching: the screens are asleep or locked, or the Mac has been left alone.
    var isQuiet: () -> Bool = { false }

    override init() {
        super.init()
        #if DEBUG
        let starts = false
        #else
        let starts = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: starts, updaterDelegate: self, userDriverDelegate: nil)
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    func checkNow() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Installs a waiting update if this is a quiet moment.
    func installIfQuiet() {
        guard let install, isQuiet() else { return }
        self.install = nil
        install()
    }
}

extension Updates: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        install = immediateInstallationBlock
        installIfQuiet()
        return true
    }
}
