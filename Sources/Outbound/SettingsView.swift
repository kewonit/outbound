import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel")
}

struct SettingsView: View {
    let libraryURL: URL
    let importPrompts: ([URL]) -> Int
    @State private var imported: Int?
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var canPaste = Paster.canPaste

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Open Outbound", name: .togglePanel)
            Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
            LabeledContent("Paste into apps") {
                if canPaste {
                    Text("Allowed").foregroundStyle(.secondary)
                } else {
                    Button("Allow…", action: Paster.requestAccess)
                }
            }
            LabeledContent("Library") {
                HStack {
                    if let imported {
                        Text(imported == 1 ? "Added 1" : "Added \(imported)").foregroundStyle(.secondary)
                    }
                    Button("Import…", action: chooseImport)
                    Button("Show in Finder", action: showLibrary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .task {
            // Both can change in System Settings while this window is open.
            while !Task.isCancelled {
                canPaste = Paster.canPaste
                opensAtLogin = SMAppService.mainApp.status == .enabled
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func setOpensAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        try? on ? service.register() : service.unregister()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        opensAtLogin = service.status == .enabled
    }

    /// Text files become prompts. Each subfolder of a chosen folder becomes a category.
    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        imported = importPrompts(panel.urls)
    }

    private func showLibrary() {
        let file = libraryURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}
