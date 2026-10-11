import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text on the clipboard and, with Accessibility access, pastes it into the frontmost app.
@MainActor
enum Paster {
    private static var askedThisLaunch = false

    static var canPaste: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt.
    static func requestAccess() {
        askedThisLaunch = true
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copies, then sends ⌘V once focus is back in the app that was in front.
    /// Without access it asks once per launch and leaves the text on the clipboard.
    static func paste(_ text: String) {
        copy(text)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() else { return }
        guard canPaste else {
            if !askedThisLaunch { requestAccess() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { sendCommandV() }
    }

    private static func sendCommandV() {
        let key = virtualKey(typing: "v") ?? CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys still held on the keyboard should not mix into the paste.
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)
        // Some apps also look at the left Command device bit.
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICELCMDKEYMASK))
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cgSessionEventTap)
        }
    }

    /// The key that types `character` while Command is held in the current layout,
    /// so ⌘V lands correctly on Dvorak, AZERTY and similar layouts.
    private static func virtualKey(typing character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8),
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, characters.count, &length, &characters)
                if status == noErr, length == 1, String(utf16CodeUnits: characters, count: 1) == String(character) {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
