import AppKit
import ApplicationServices
import Carbon

@MainActor
enum SystemCommandRunner {
    static func run(_ command: LauncherCommand, completion: @escaping (Error?) -> Void) {
        switch command {
        case .toggleAppearance:
            Task {
                let message = await Task.detached(priority: .userInitiated) { () -> String? in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"]
                    let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
                    do {
                        try process.run()
                        let data = errors.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        guard process.terminationStatus != 0 else { return nil }
                        let details = String(data: data, encoding: .utf8) ?? ""
                        if details.contains("1743") { return "Allow seven to control System Events in System Settings → Privacy & Security → Automation." }
                        return "macOS couldn’t change appearance. Check seven’s Automation access in System Settings."
                    } catch { return "Couldn’t start the macOS appearance command." }
                }.value
                completion(message.map(error))
            }
        case .lockScreen:
            guard AXIsProcessTrusted() else {
                ClipboardPaste.requestPermission()
                completion(error("Allow seven in System Settings → Privacy & Security → Accessibility to use Lock Screen."))
                return
            }
            func send(attempt: Int) {
                if !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    guard attempt < 20 else { completion(error("Release the modifier keys and try Lock Screen again.")); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { send(attempt: attempt + 1) }
                    return
                }
                guard let source = CGEventSource(stateID: .privateState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false) else {
                    completion(error("Couldn’t send the Lock Screen shortcut.")); return
                }
                down.flags = [.maskCommand, .maskControl]; up.flags = [.maskCommand, .maskControl]
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                completion(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { send(attempt: 0) }
        }
    }
    private static func error(_ message: String) -> NSError { NSError(domain: "seven.SystemCommands", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
