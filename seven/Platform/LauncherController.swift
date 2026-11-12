import AppKit
import Carbon
import SwiftUI

@MainActor
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LauncherController {
    typealias ApplicationOpener = (URL, @escaping (Error?) -> Void) -> Void
    typealias CommandExecutor = (LauncherCommand, @escaping (Error?) -> Void) -> Void
    let store: LauncherStore
    private(set) var panel: LauncherPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var previousApplication: NSRunningApplication?
    private let opener: ApplicationOpener
    private let urlOpener: (URL) -> Bool
    private let commandExecutor: CommandExecutor
    private let pastePermission: () -> Bool
    private var pendingPasteID: UUID?
    private var clipboardActivation = ClipboardActivationGesture()
    private let actions: ClipboardActionsController

    var isVisible: Bool { panel?.isVisible == true }

    convenience init() { self.init(store: LauncherStore()) }

    init(store: LauncherStore, pastePermission: (() -> Bool)? = nil, commandExecutor: CommandExecutor? = nil,
         urlOpener: ((URL) -> Bool)? = nil, opener: ApplicationOpener? = nil) {
        self.store = store
        self.pastePermission = pastePermission ?? { ClipboardPaste.hasPermission }
        self.actions = ClipboardActionsController(launcher: store)
        self.commandExecutor = commandExecutor ?? SystemCommandRunner.run
        self.urlOpener = urlOpener ?? { NSWorkspace.shared.open($0) }
        self.opener = opener ?? { url, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                DispatchQueue.main.async { completion(error) }
            }
        }
        store.onLaunch = { [weak self] in self?.launch($0) }
        store.onCommand = { [weak self] in self?.run($0) }
        store.onOpenURL = { [weak self] in self?.openURL($0) }
        store.onRestore = { [weak self] entry, paste, plainText in self?.restore(entry, paste: paste, plainText: plainText) }
        store.onDismiss = { [weak self] in self?.dismiss(restoreFocus: true) }
        store.onShowActions = { [weak self] in
            guard let self, let panel = self.panel, self.store.mode == .clipboard else { return }
            self.actions.toggle(relativeTo: panel)
        }
    }

    func show(at anchor: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let expandsFromRight = anchor.x + 20 + LauncherLayout.width > visible.maxX - 12
        let desiredLeft = expandsFromRight ? anchor.x - 20 - LauncherLayout.width : anchor.x + 20
        let cardLeft = min(max(desiredLeft, visible.minX + 12), visible.maxX - LauncherLayout.width - 12)
        let desiredTop = min(anchor.y + 28, visible.maxY - 12)
        let maximumHeight = LauncherLayout.maximumHeight + 2 * LauncherLayout.inset
        let cardTop = max(desiredTop + LauncherLayout.inset - maximumHeight, visible.minY + 8)
            + maximumHeight - LauncherLayout.inset
        show(cardTopLeft: NSPoint(x: cardLeft, y: cardTop), expandsFromRight: expandsFromRight)
    }

    func showBelowNotch(on screen: NSScreen? = nil) {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let topLeft = LauncherLayout.belowNotchTopLeft(screenFrame: screen.frame,
                                                      visibleFrame: screen.visibleFrame,
                                                      topSafeAreaInset: screen.safeAreaInsets.top)
        show(cardTopLeft: topLeft, expandsFromRight: false)
    }

    private func show(cardTopLeft: NSPoint, expandsFromRight: Bool) {
        let previous = previousApplication ?? NSWorkspace.shared.frontmostApplication
        dismiss()
        store.reset()
        store.refreshApplicationsForPresentation()
        if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = previous }
        let width = LauncherLayout.width + 2 * LauncherLayout.inset
        let maximumHeight = LauncherLayout.maximumHeight + 2 * LauncherLayout.inset
        let height = store.cardHeight + 2 * LauncherLayout.inset
        let frame = NSRect(x: cardTopLeft.x - LauncherLayout.inset,
                           y: cardTopLeft.y + LauncherLayout.inset - height,
                           width: width, height: height)
        let panel = LauncherPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "seven Launcher"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // AppKit resets the level when isFloatingPanel changes.
        panel.level = SevenWindowLevel.overlay
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: LauncherView(store: store, expandsFromRight: expandsFromRight) { [weak self, weak panel] height in
            guard let self, let panel, self.panel === panel else { return }
            self.fitContent(height: height)
        })
        host.sizingOptions = []
        // A fixed canvas keeps SwiftUI's search field anchored while the window
        // follows the card's animated height. Resizing the hosting view itself
        // would introduce a second layout animation.
        let surface = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.frame = NSRect(x: 0, y: height - maximumHeight, width: width, height: maximumHeight)
        host.autoresizingMask = [.width, .minYMargin]
        surface.addSubview(host)
        panel.contentView = surface
        panel.initialFirstResponder = host
        self.panel = panel
        installMonitors(for: panel)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak panel] in panel?.invalidateShadow() }
        NSCursor.arrow.set()
    }

    func showClipboard(at anchor: NSPoint) {
        show(at: anchor)
        store.toggleClipboard()
    }

    private func fitContent(height cardHeight: CGFloat) {
        guard let panel else { return }
        let height = min(max(cardHeight, LauncherLayout.searchHeight), LauncherLayout.maximumHeight) + 2 * LauncherLayout.inset
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    func dismiss(restoreFocus: Bool = false) {
        pendingPasteID = nil
        actions.dismiss(restoreFocus: false)
        clipboardActivation.reset()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        localMonitor = nil
        globalMonitor = nil
        resignObserver = nil
        let oldPanel = panel
        panel = nil
        oldPanel?.close()
        if restoreFocus, let previousApplication, !previousApplication.isTerminated {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmost == ProcessInfo.processInfo.processIdentifier || frontmost == previousApplication.processIdentifier {
                previousApplication.activate(options: [])
            }
        }
        previousApplication = nil
    }

    private func installMonitors(for panel: LauncherPanel) {
        clipboardActivation.reset(optionIsDown: NSEvent.modifierFlags.contains(.option))
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            guard let self, let panel, self.isVisible else { return event }
            if event.type == .flagsChanged {
                if self.clipboardActivation.flagsChanged(event.modifierFlags) {
                    self.actions.dismiss()
                    self.store.toggleClipboard()
                }
                return event
            }
            self.clipboardActivation.cancel()
            if event.type == .keyDown, event.window === panel {
                let flags = event.modifierFlags
                if flags.contains([.command, .shift]), event.keyCode == kVK_ANSI_C {
                    self.store.toggleClipboard(); return nil
                }
                if self.store.showsCalculations,
                   flags.intersection([.command, .option, .control, .shift]) == .option,
                   event.keyCode == kVK_Delete {
                    self.store.deleteSelection(); return nil
                }
                if self.store.mode == .clipboard {
                    if flags.contains(.command), event.keyCode == kVK_ANSI_K {
                        self.store.onShowActions?(); return nil
                    }
                    if flags.contains(.option), event.keyCode == kVK_Delete {
                        self.store.deleteSelection(); return nil
                    }
                    if flags.contains(.command), let character = event.charactersIgnoringModifiers,
                       let number = Int(character), (1...9).contains(number), number <= self.store.resultCount {
                        self.store.select(index: number - 1)
                        self.store.launchSelection(paste: flags.contains(.option), plainText: flags.contains(.shift))
                        return nil
                    }
                }
                switch Int(event.keyCode) {
                case kVK_Escape: self.dismiss(restoreFocus: true); return nil
                case kVK_UpArrow: self.store.moveSelection(by: -1); return nil
                case kVK_DownArrow: self.store.moveSelection(by: 1); return nil
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    self.store.launchSelection(paste: flags.contains(.option), plainText: flags.contains(.shift)); return nil
                default: return event
                }
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window === self.actions.panel { return event }
                self.actions.dismiss(restoreFocus: false)
                let point = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
                let card = NSRect(origin: .zero, size: panel.frame.size).insetBy(dx: LauncherLayout.inset, dy: LauncherLayout.inset)
                if event.window !== panel || !card.contains(point) { self.dismiss() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.actions.isVisible else { return }
                self.dismiss()
            }
        }
    }

    private func launch(_ application: LauncherApplication) {
        guard !store.isLaunching else { return }
        store.isLaunching = true
        opener(application.url) { [weak self] error in
            guard let self else { return }
            self.store.isLaunching = false
            if let error {
                self.store.reportLaunchError("Couldn’t open \(application.name): \(error.localizedDescription)")
            } else {
                self.dismiss()
            }
        }
    }

    private func openURL(_ url: URL) {
        guard !store.isLaunching else { return }
        store.isLaunching = true
        let opened = urlOpener(url)
        store.isLaunching = false
        if opened { dismiss() }
        else { store.reportLaunchError("Couldn’t open Google in your default browser.") }
    }

    private func restore(_ entry: ClipboardEntry, paste: Bool, plainText: Bool) {
        let destination = previousApplication
        if paste {
            guard pastePermission() else { store.reportClipboardError(.accessibilityRequired); return }
            guard let destination, !destination.isTerminated else {
                store.reportClipboardError(.destinationUnavailable); return
            }
        }
        guard store.clipboard.restore(entry, plainText: plainText) else {
            store.reportLaunchError("Couldn’t restore this clipboard item.")
            NSSound.beep()
            return
        }
        let anchor = NSEvent.mouseLocation
        dismiss(restoreFocus: true)
        if paste, let destination {
            let requestID = UUID()
            pendingPasteID = requestID
            ClipboardPaste.paste(into: destination, isCancelled: { [weak self] in self?.pendingPasteID != requestID }) { [weak self] error in
                guard let self, self.pendingPasteID == requestID else { return }
                self.pendingPasteID = nil
                guard let error else { return }
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard frontmost == destination.processIdentifier || frontmost == ProcessInfo.processInfo.processIdentifier else { return }
                self.showClipboard(at: anchor)
                self.store.select(entry)
                self.store.reportClipboardError(error)
            }
        }
    }

    private func run(_ command: LauncherCommand) {
        guard !store.isLaunching else { return }
        store.isLaunching = true
        commandExecutor(command) { [weak self] error in
            guard let self else { return }
            self.store.isLaunching = false
            if let error { self.store.reportLaunchError(error.localizedDescription) }
            else { self.dismiss(restoreFocus: command != .lockScreen) }
        }
    }
}
