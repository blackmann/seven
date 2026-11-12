import AppKit
import ApplicationServices
import Carbon

/// Waits for the nonactivating panel to release keyboard focus before sending paste.
/// Kept independent of AppKit so delayed focus and cancellation can be tested.
struct ClipboardPasteReadiness {
    enum Decision: Equatable { case wait, paste, cancel, fail(ClipboardPasteFailure) }
    let destinationPID: pid_t
    let ownPID: pid_t
    let deadline: TimeInterval

    func decision(now: TimeInterval, frontmostPID: pid_t?, destinationAlive: Bool,
                  panelHasFocus: Bool, inputHeld: Bool) -> Decision {
        guard destinationAlive else { return .fail(.destinationUnavailable) }
        if let frontmostPID, frontmostPID != destinationPID && frontmostPID != ownPID { return .cancel }
        if frontmostPID == destinationPID && !panelHasFocus && !inputHeld { return .paste }
        if now >= deadline { return .fail(inputHeld ? .inputStillHeld : .focusTimedOut) }
        return .wait
    }
}

enum ClipboardPasteFailure: Error, Equatable, LocalizedError {
    case accessibilityRequired, destinationUnavailable, focusTimedOut, inputStillHeld, eventsUnavailable
    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: return "Allow seven in System Settings → Privacy & Security → Accessibility, then try again."
        case .destinationUnavailable: return "Open seven from the app you want to paste into, then select this item again."
        case .focusTimedOut: return "Couldn’t return keyboard focus to the previous app. Try selecting this item again."
        case .inputStillHeld: return "Release the modifier keys and mouse button, then select this item again."
        case .eventsUnavailable: return "macOS couldn’t create the paste keystroke. Try again."
        }
    }
}

@MainActor
enum ClipboardPaste {
    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        guard !hasPermission else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func paste(into application: NSRunningApplication, isCancelled: @escaping () -> Bool = { false },
                      completion: @escaping (ClipboardPasteFailure?) -> Void = { _ in }) {
        guard hasPermission else { completion(.accessibilityRequired); return }
        let readiness = ClipboardPasteReadiness(destinationPID: application.processIdentifier,
                                               ownPID: ProcessInfo.processInfo.processIdentifier,
                                               deadline: ProcessInfo.processInfo.systemUptime + 2)
        func deliver() {
            guard !isCancelled() else { completion(nil); return }
            guard hasPermission else { completion(.accessibilityRequired); return }
            let modifiers = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            let decision = readiness.decision(now: ProcessInfo.processInfo.systemUptime,
                                              frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                              destinationAlive: !application.isTerminated,
                                              panelHasFocus: NSApp.keyWindow?.isVisible == true,
                                              inputHeld: !modifiers.isEmpty || NSEvent.pressedMouseButtons != 0)
            switch decision {
            case .wait: DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { deliver() }
            case .cancel: completion(nil) // The user switched apps; do not send paste somewhere else.
            case .fail(let error): completion(error)
            case .paste:
                guard let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                    completion(.eventsUnavailable); return
                }
                down.flags = .maskCommand; up.flags = .maskCommand
                // Use the normal session event stream after focus is restored, as Maccy does.
                down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
                completion(nil)
            }
        }
        DispatchQueue.main.async { deliver() }
    }
}
