import AppKit
import Carbon
import SwiftUI

@MainActor
final class ClipboardActionsController {
    let store: ClipboardActionsStore
    private(set) var panel: LauncherPanel?
    private weak var parent: NSWindow?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    var isVisible: Bool { panel?.isVisible == true }

    init(launcher: LauncherStore) {
        store = ClipboardActionsStore(launcher: launcher)
        store.onPerform = { [weak self] action in
            guard let self else { return }
            self.dismiss()
            self.store.execute(action)
        }

    }
    func toggle(relativeTo parent: NSWindow) { isVisible ? dismiss() : show(relativeTo: parent) }
    func show(relativeTo parent: NSWindow) {
        dismiss(restoreFocus: false)
        self.parent = parent
        store.selected = store.actions.first(where: store.isEnabled)
        let frame = frame(relativeTo: parent)
        let panel = LauncherPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "seven Actions"
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        let host = NSHostingView(rootView: ClipboardActionsView(store: store))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]; panel.contentView = host
        self.panel = panel
        parent.addChildWindow(panel, ordered: .above)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            guard let self, let panel else { return event }
            if event.type == .keyDown, event.window === panel {
                let flags = event.modifierFlags
                if flags.contains(.command), event.keyCode == kVK_ANSI_K { self.dismiss(); return nil }
                switch Int(event.keyCode) {
                case kVK_Escape: self.dismiss(); return nil
                case kVK_UpArrow: self.store.move(by: -1); return nil
                case kVK_DownArrow: self.store.move(by: 1); return nil
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    self.store.perform(self.store.selected)
                    return nil
                default: return event
                }
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                if event.window !== panel { self.dismiss(restoreFocus: false) }
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }
    func dismiss(restoreFocus: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil; resignObserver = nil
        let old = panel; panel = nil
        if let old { parent?.removeChildWindow(old); old.orderOut(nil) }
        if restoreFocus, old != nil, parent?.isVisible == true {
            parent?.makeKeyAndOrderFront(nil)
            store.launcher.focusSearch()
        }
        parent = nil
    }
    private func frame(relativeTo parent: NSWindow) -> NSRect {
        let width: CGFloat = 256
        let height = store.cardHeight + 16
        let bounds = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        let right = parent.frame.maxX - LauncherLayout.inset + 8
        let bottom = parent.frame.minY + LauncherLayout.inset + LauncherLayout.footerHeight + 2
        return NSRect(x: min(max(right - width, bounds.minX + 6), bounds.maxX - width - 6),
                      y: min(max(bottom, bounds.minY + 6), bounds.maxY - height - 6), width: width, height: height)
    }
}
