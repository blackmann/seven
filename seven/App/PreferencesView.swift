import AppKit
import Carbon
import ServiceManagement
import SwiftUI

/// Registers seven as a login item through the system's ServiceManagement API,
/// so the setting also appears (and can be revoked) in System Settings → General → Login Items.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    init() { refresh() }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}

struct ShortcutStatus {
    var launcher: OSStatus
    var switcher: OSStatus
}

struct PreferencesView: View {
    let shortcuts: () -> ShortcutStatus

    var body: some View {
        // Inside a Settings scene, a TabView becomes the standard toolbar of icon tabs.
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutPreferences(shortcuts: shortcuts)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .scenePadding()
        .frame(width: 460)
    }
}

private struct GeneralPreferences: View {
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @AppStorage("keepOpen") private var keepOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch seven at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.requiresApproval {
                    Text("Allow seven in Login Items to finish turning this on.")
                        .foregroundStyle(.secondary)
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let message = launchAtLogin.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep switcher open after releasing Option", isOn: $keepOpen)
                Text("Scroll up for Launcher, down for Notes.\nClick to confirm, Esc to cancel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20) // line up with the checkbox title
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { launchAtLogin.refresh() }
        // The user may change the login item in System Settings while seven is in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}

private struct ShortcutPreferences: View {
    let shortcuts: () -> ShortcutStatus
    @State private var status = ShortcutStatus(launcher: noErr, switcher: noErr)

    var body: some View {
        Form {
            row("Show Launcher:", keys: "⌘Space", status: status.launcher)
            row("Show Switcher:", keys: "⌥⇥", status: status.switcher)
        }
        .formStyle(.columns)
        .onAppear { status = shortcuts() }
    }

    private func row(_ title: String, keys: String, status: OSStatus) -> some View {
        LabeledContent(title) {
            if status == noErr {
                Text(keys)
            } else {
                Text("\(keys) unavailable (error \(status))").foregroundStyle(.red)
            }
        }
    }
}
