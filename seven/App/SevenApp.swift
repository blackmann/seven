import AppKit
import Carbon
import SwiftUI

@main
enum SevenApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
enum ApplicationMenu {
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let application = NSMenu(title: "seven")
        application.addItem(withTitle: "Quit seven", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "seven", action: nil, keyEquivalent: "").submenu = application

        // Nil targets let AppKit route and validate standard editing actions
        // through the first responder, including in nonactivating panels.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let matchStyle = edit.addItem(withTitle: "Paste and Match Style",
                                     action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        matchStyle.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return main
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let shortcut = GlobalShortcut()
    private let launcherShortcut = GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), id: 2)
    private var controller: SwitcherController!
    private var launcher: LauncherController!
    private var clipboard: ClipboardHistory!
    private var notes: NotesController?
    private var notesDefaults: UserDefaults = .standard
    private var statusItem: NSStatusItem!
    private var modeItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var shortcutItem: NSMenuItem!
    private var launcherShortcutItem: NSMenuItem!
    private var sleepObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = ApplicationMenu.makeMainMenu()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--render-previews"), arguments.indices.contains(index + 1) {
            PreviewExporter.export(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            NSApp.terminate(nil)
            return
        }
        if let index = arguments.firstIndex(of: "--render-motion"), arguments.indices.contains(index + 1) {
            PreviewExporter.exportMotion(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            NSApp.terminate(nil)
            return
        }

        let mode = SwitcherMode(savedValue: UserDefaults.standard.string(forKey: "selectedMode"))
        let isVerification = arguments.contains(where: { $0.hasSuffix("smoke-test") }) || NSClassFromString("XCTestCase") != nil
        if !isVerification { NotesPreferencesMigration.importWIfNeeded() }
        notesDefaults = isVerification ? UserDefaults(suiteName: "seven.notes.verification.\(UUID().uuidString)")! : .standard
        clipboard = ClipboardHistory(storageURL: isVerification ? nil : ClipboardHistory.defaultStorageURL,
                                     autoStart: !isVerification, defaults: isVerification ? nil : .standard)
        launcher = LauncherController(store: LauncherStore(clipboard: clipboard,
            calculationHistoryURL: isVerification ? nil : LauncherStore.defaultCalculationHistoryURL))
        controller = SwitcherController(mode: mode)
        controller.onCommit = { [weak self] mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "selectedMode")
            self?.refreshMenu()
        }
        controller.onConfirm = { [weak self] mode, anchor in
            switch mode {
            case .text: self?.launcher.show(at: anchor)
            case .notes: self?.presentNotes(at: anchor)
            }
        }
        makeMenu()
        shortcut.onPress = { [weak self] in
            guard let self else { return }
            self.launcher.dismiss(restoreFocus: true)
            self.controller.activate(keepOpen: UserDefaults.standard.bool(forKey: "keepOpen"))
        }
        shortcut.register()
        launcherShortcut.onPress = { [weak self] in self?.presentLauncher() }
        launcherShortcut.register()
        refreshMenu()

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.dismiss(); self?.launcher.dismiss() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.dismiss(); self?.launcher.dismiss() }
        }

        if arguments.contains("--preview") {
            DispatchQueue.main.async { [weak self] in self?.controller.preview() }
        }
        if arguments.contains("--smoke-test") { runSmokeTest() }
        if arguments.contains("--launcher-preview") {
            DispatchQueue.main.async { [weak self] in self?.launcher.show(at: NSEvent.mouseLocation) }

        }
        if arguments.contains("--notch-launcher-preview") {
            DispatchQueue.main.async { [weak self] in self?.presentLauncher() }
        }
        if arguments.contains("--clipboard-preview") {
            DispatchQueue.main.async { [weak self] in self?.launcher.showClipboard(at: NSEvent.mouseLocation) }
        }
        if arguments.contains("--notes-preview") {
            DispatchQueue.main.async { [weak self] in self?.presentNotes(at: NSEvent.mouseLocation) }
        }
        if arguments.contains("--launcher-smoke-test") { runLauncherSmokeTest() }
        if arguments.contains("--clipboard-smoke-test") { runClipboardSmokeTest() }
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "app.background.dotted", accessibilityDescription: "seven")
        // Let AppKit choose the icon color for the menu bar's background and appearance.
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        modeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(modeItem)
        menu.addItem(.separator())
        launcherShortcutItem = NSMenuItem(title: "Show Launcher   ⌘Space", action: #selector(showLauncher), keyEquivalent: "")
        launcherShortcutItem.target = self
        menu.addItem(launcherShortcutItem)
        shortcutItem = NSMenuItem(title: "Show Switcher   ⌥⇥", action: #selector(showSwitcher), keyEquivalent: "")
        shortcutItem.target = self
        menu.addItem(shortcutItem)
        let clipboardItem = NSMenuItem(title: "Clipboard History", action: #selector(showClipboard), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)
        let notesItem = NSMenuItem(title: "Notes", action: #selector(showNotes), keyEquivalent: "")
        notesItem.image = NSImage(systemSymbolName: "tornado", accessibilityDescription: "Notes")
        notesItem.target = self
        menu.addItem(notesItem)
        menu.addItem(NSMenuItem(title: "Scroll ↑ Launcher · ↓ Notes", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Esc cancels · Click confirms", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "Keep Open After Releasing Option", action: #selector(toggleKeepOpen), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit seven", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        notes?.prepareToClose() == false ? .terminateCancel : .terminateNow
    }

    @objc private func showNotes() {
        DispatchQueue.main.async { [weak self] in self?.presentNotes(at: NSEvent.mouseLocation) }
    }

    private func presentNotes(at anchor: NSPoint) {
        launcher.dismiss()
        controller.dismiss()
        if notes == nil { notes = NotesController(store: VaultStore(defaults: notesDefaults)) }
        notes?.show(at: anchor)
    }

    private func presentLauncher() {
        controller.dismiss(cancelled: true)
        launcher.showBelowNotch()
    }

    private func refreshMenu() {
        modeItem.title = "Selected Mode: \(controller.session.mode.title)"
        toggleItem.state = UserDefaults.standard.bool(forKey: "keepOpen") ? .on : .off
        statusItem.button?.toolTip = "seven · Command–Space Launcher · Option–Tab Switcher"
        shortcutItem.title = shortcut.registrationStatus == noErr
            ? "Show Switcher   ⌥⇥" : "Show Switcher (⌥⇥ unavailable: \(shortcut.registrationStatus))"
        launcherShortcutItem.title = launcherShortcut.registrationStatus == noErr
            ? "Show Launcher   ⌘Space" : "Show Launcher (⌘Space unavailable: \(launcherShortcut.registrationStatus))"
    }

    @objc private func showLauncher() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.presentLauncher() }
    }

    @objc private func showSwitcher() {
        // NSMenu is still closing during the action; wait until it has released
        // its own event tracking before ordering the transparent panels forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.controller.preview() }
    }

    @objc private func toggleKeepOpen() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "keepOpen"), forKey: "keepOpen")
        refreshMenu()
    }

    @objc private func showClipboard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.launcher.showClipboard(at: NSEvent.mouseLocation) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launcher?.dismiss()
        clipboard?.stop()
        clipboard?.flush()
        controller?.dismiss()
        shortcut.unregister()
        launcherShortcut.unregister()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func runSmokeTest() {
        // Exercise real AppKit panels and native scroll events without asking
        // for Accessibility or Input Monitoring permissions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            var failures: [String] = []
            func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
            check(shortcut.registrationStatus == noErr, "Global shortcut registration: \(shortcut.registrationStatus)")
            let original = controller.session.mode
            controller.preview()
            check(controller.session.isVisible, "Preview did not open")
            check(NSApp.windows.contains { $0.title == "seven Overlay" && $0.isVisible }, "No visible overlay panel")
            check(NSApp.keyWindow?.title == "seven Overlay", "Overlay did not become key")
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cg) {
                controller.handleScroll(event)
                check(controller.session.mode == .notes, "Downward scroll did not select Notes")
            } else { failures.append("Could not construct native scroll event") }
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cg) {
                controller.handleScroll(event)
                check(controller.session.mode == .text, "Upward scroll did not select Launcher")
            }
            controller.dismiss(cancelled: true)
            check(controller.session.mode == original, "Cancel did not restore the original mode")
            check(!controller.session.isVisible, "Overlay did not close")
            controller.select(.notes)
            controller.activate(keepOpen: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self, failures] in
                var failures = failures
                if controller.session.isVisible { failures.append("Option release did not dismiss overlay") }
                if notes?.panel?.isVisible != true { failures.append("Confirming Notes did not open its panel") }
                if launcher.isVisible { failures.append("Confirming Notes opened the launcher") }
                controller.dismiss(cancelled: true)
                let report = failures.isEmpty ? "PASS: shortcut, transparent panel, native scrolling, cancel, Option release, Notes activation\n" : "FAIL: \(failures.joined(separator: "; "))\n"
                FileHandle.standardOutput.write(Data(report.utf8))
                if !failures.isEmpty { exit(EXIT_FAILURE) }
                NSApp.terminate(nil)
            }
        }
    }

    private func runLauncherSmokeTest() {
        let fixtures = [
            LauncherApplication(url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari", bundleIdentifier: "com.apple.Safari"),
            LauncherApplication(url: URL(fileURLWithPath: "/Applications/Calendar.app"), name: "Calendar")
        ]
        var opened: URL?
        let testLauncher = LauncherController(store: LauncherStore(applications: fixtures), opener: { url, completion in
            opened = url
            completion(nil)
        })
        let anchor = NSPoint(x: (NSScreen.main?.frame.midX ?? 600) - 190, y: NSScreen.main?.frame.midY ?? 500)
        var confirmCount = 0
        controller.onConfirm = { mode, _ in
            confirmCount += 1
            if mode == .text { testLauncher.show(at: anchor) }
        }
        controller.preview()
        controller.select(.text)
        controller.dismiss(cancelled: true)
        var failures: [String] = []
        if FileManager.default.fileExists(atPath: "/Applications/Safari.app"),
           !ApplicationSearch.results(for: "saf", in: ApplicationCatalog.discover()).contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
            failures.append("Installed Safari was missing from the application catalog")
        }
        if testLauncher.isVisible || confirmCount != 0 { failures.append("Cancel opened the launcher") }
        controller.preview()
        controller.select(.text)
        controller.confirm()
        controller.confirm()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self, testLauncher] in
            if !testLauncher.isVisible { failures.append("Confirm did not open launcher") }
            if confirmCount != 1 { failures.append("Confirmation fired more than once") }
            if NSApp.keyWindow !== testLauncher.panel { failures.append("Launcher did not take keyboard focus") }
            if !(testLauncher.panel?.firstResponder is NSTextView) { failures.append("Search input was not focused") }
            if testLauncher.store.showsList { failures.append("Empty search displayed results") }
            if abs((testLauncher.panel?.frame.height ?? 0) - LauncherLayout.searchHeight - 2 * LauncherLayout.inset) > 1 { failures.append("Empty launcher window has excess padding") }
            testLauncher.store.query = "saf"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if testLauncher.store.results.first?.name != "Safari" { failures.append("Search did not produce the expected result") }
                if !testLauncher.store.showsList { failures.append("Results did not reveal the list") }
                if abs((testLauncher.panel?.frame.height ?? 0) - testLauncher.store.cardHeight - 2 * LauncherLayout.inset) > 1 { failures.append("Launcher window did not fit its results") }
                testLauncher.store.query = "zzzz"
                if testLauncher.store.hasExpandedResults { failures.append("No matches did not collapse results") }
                testLauncher.store.query = ""
                testLauncher.store.query = "com.apple.safari"
                if testLauncher.store.results.first?.name != "Safari" { failures.append("Bundle identifier search failed") }
                if testLauncher.store.cardHeight != LauncherLayout.expandedHeight { failures.append("Results did not expand again") }
                testLauncher.store.launchSelection()
                if opened != fixtures[0].url { failures.append("Return did not dispatch the selected app") }
                if testLauncher.isVisible { failures.append("Successful launch did not dismiss the panel") }
                testLauncher.dismiss()
                let report = failures.isEmpty ? "PASS: release confirmation, cancel, focus, installed Safari, package search, single expansion, launch dispatch, dismissal\n" : "FAIL: \(failures.joined(separator: "; "))\n"
                FileHandle.standardOutput.write(Data(report.utf8))
                if !failures.isEmpty { exit(EXIT_FAILURE) }
                self.launcher.dismiss()
                NSApp.terminate(nil)
            }
        }
    }
    private func runClipboardSmokeTest() {
        let board = NSPasteboard(name: .init("seven-smoke-" + UUID().uuidString))
        let history = ClipboardHistory(storageURL: nil, pasteboard: board, autoStart: true, defaults: nil)
        for number in 0..<8 {
            board.clearContents(); board.setString("Clipboard entry \(number)", forType: .string)
            history.captureIfChanged(sourceName: "Smoke test")
        }
        let store = LauncherStore(applications: [], clipboard: history)
        let testLauncher = LauncherController(store: store)
        let anchor = NSPoint(x: (NSScreen.main?.frame.midX ?? 600) - 190, y: NSScreen.main?.frame.midY ?? 500)
        let previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        testLauncher.showClipboard(at: anchor)
        board.clearContents(); board.setString("Timer capture", forType: .string)
        var failures: [String] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            if previousPID != ProcessInfo.processInfo.processIdentifier,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != previousPID {
                failures.append("Clipboard panel activated seven instead of preserving the original app")
            }
            if history.entries.count != 9 { failures.append("Clipboard timer did not capture a new copy") }
            if !testLauncher.isVisible || NSApp.keyWindow !== testLauncher.panel { failures.append("Clipboard panel did not become key") }
            if !(testLauncher.panel?.firstResponder is NSTextView) { failures.append("History search was not focused") }
            store.onShowActions?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if NSApp.keyWindow?.title != "seven Actions" {
                    failures.append("Actions panel did not take keyboard focus")
                }
                store.onShowActions?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if NSApp.keyWindow !== testLauncher.panel || !(testLauncher.panel?.firstResponder is NSTextView) {
                        failures.append("Closing actions did not restore launcher search focus")
                    }
                    store.query = "missing"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if store.hasExpandedResults { failures.append("No clipboard matches did not collapse the list") }
                        if abs((testLauncher.panel?.frame.height ?? 0) - store.cardHeight - 2 * LauncherLayout.inset) > 1 { failures.append("Empty results window did not collapse: actual \(testLauncher.panel?.frame.height ?? 0), expected \(store.cardHeight + 2 * LauncherLayout.inset)") }
                        store.query = "clipboard entry"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            if store.clipboardResults.count != 8 { failures.append("History content search failed") }
                            if abs((testLauncher.panel?.frame.height ?? 0) - store.cardHeight - 2 * LauncherLayout.inset) > 1 { failures.append("Results window did not expand: actual \(testLauncher.panel?.frame.height ?? 0), expected \(store.cardHeight + 2 * LauncherLayout.inset)") }
                            store.moveSelection(by: 7)
                            let expected = store.selectedClipboardEntry?.text
                            store.launchSelection(plainText: true)
                            if expected == nil || board.string(forType: .string) != expected { failures.append("History selection did not restore its content") }
                            if testLauncher.isVisible { failures.append("Restoring history did not dismiss the panel") }
                            if history.entries.count != 9 { failures.append("Restoring history made a duplicate") }
                            history.stop(); board.releaseGlobally()
                            let report = failures.isEmpty ? "PASS: clipboard monitoring, search focus, collapse, expansion, keyboard selection, custom actions focus, restore, dismissal\n" : "FAIL: \(failures.joined(separator: "; "))\n"
                            FileHandle.standardOutput.write(Data(report.utf8))
                            if !failures.isEmpty { exit(EXIT_FAILURE) }
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

}
