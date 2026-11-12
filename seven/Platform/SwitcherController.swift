import AppKit
import Carbon
import SwiftUI

@MainActor
final class SwitcherController {
    private(set) var session: SwitcherSession
    let appearance: SwitcherAppearance
    private var surfaces: [(panel: OverlayPanel, view: OverlaySurface)] = []
    private var timer: Timer?
    private var scrollSelector = ScrollSelector()
    var onCommit: ((SwitcherMode) -> Void)?
    var onConfirm: ((SwitcherMode, NSPoint) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    init(mode: SwitcherMode) {
        session = SwitcherSession(mode: mode)
        appearance = SwitcherAppearance(mode: mode)
    }

    func activate(keepOpen: Bool) {
        if session.isVisible {
            if session.activation == .toggle { confirm() }
            else { select(session.mode.other) }
            return
        }
        show(activation: keepOpen ? .toggle : .holdOption)
    }

    func preview() {
        if session.isVisible { dismiss(); return }
        show(activation: .toggle)
    }

    func select(_ mode: SwitcherMode) {
        guard session.mode != mode else { return }
        session.select(mode)
        appearance.mode = mode
        for surface in surfaces {
            surface.view.setAccessibilityValue(mode.title)
        }
    }

    private func show(activation: SwitcherSession.Activation) {
        session.open(activation: activation)
        scrollSelector.reset()
        let pointer = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            // A barely nonzero alpha keeps transparent areas in the window's
            // hit region, so scrolling cannot leak into the app underneath.
            panel.backgroundColor = .black.withAlphaComponent(0.001)
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            // AppKit resets the level when isFloatingPanel changes.
            panel.level = SevenWindowLevel.overlay
            panel.becomesKeyOnlyIfNeeded = false
            panel.acceptsMouseMovedEvents = true
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.title = "seven Overlay"
            let surface = OverlaySurface(appearance: appearance)
            surface.onScroll = { [weak self] in self?.handleScroll($0) }
            surface.onKey = { [weak self] in self?.handleKey($0) }
            surface.onFlags = { [weak self] in self?.handleFlags($0) }
            surface.onClick = { [weak self] cancelled in
                if cancelled { self?.dismiss(cancelled: true) }
                else { self?.confirm() }
            }
            panel.contentView = surface
            surfaces.append((panel, surface))
            panel.orderFrontRegardless()
            if screen.frame.contains(pointer) {
                panel.makeKey()
                panel.makeFirstResponder(surface)
            }
        }
        updatePointer()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onVisibilityChanged?(true)
    }

    private func tick() {
        guard session.isVisible else { return }
        if session.shouldDismiss(isOptionDown: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)) {
            confirm()
            return
        }
        updatePointer()
    }

    private func updatePointer() {
        let point = NSEvent.mouseLocation
        for item in surfaces {
            let contains = item.panel.frame.contains(point)
            if contains {
                appearance.pillOnLeft = point.x >= item.panel.frame.minX + 50
                let local = NSPoint(x: point.x - item.panel.frame.minX, y: point.y - item.panel.frame.minY)
                // Keep the pill readable at display edges without moving the
                // native pointer, including on stacked displays.
                appearance.pillVerticalOffset = local.y - min(max(local.y, 30), item.panel.frame.height - 30)
                item.view.placeHUD(at: local, visible: true)
                if !item.panel.isKeyWindow {
                    item.panel.makeKey()
                    item.panel.makeFirstResponder(item.view)
                }
            } else {
                item.view.placeHUD(at: .zero, visible: false)
            }
        }
    }

    func handleScroll(_ event: NSEvent) {
        if event.phase == .began { scrollSelector.reset() }
        if let mode = scrollSelector.selection(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, momentum: event.momentumPhase != [], timestamp: event.timestamp) {
            select(mode)
        }
    }

    private func handleFlags(_ event: NSEvent) {
        if session.shouldDismiss(isOptionDown: event.modifierFlags.contains(.option)) { confirm() }
    }

    private func handleKey(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: dismiss(cancelled: true)
        case kVK_Return, kVK_ANSI_KeypadEnter: confirm()
        case kVK_UpArrow, kVK_ANSI_T: select(.text)
        case kVK_DownArrow, kVK_ANSI_N: select(.notes)
        default: break
        }
    }

    func confirm() {
        guard session.isVisible else { return }
        let mode = session.mode
        let anchor = NSEvent.mouseLocation
        dismiss()
        onConfirm?(mode, anchor)
    }

    func dismiss(cancelled: Bool = false) {
        guard session.isVisible else { return }
        timer?.invalidate()
        timer = nil
        session.close(cancelled: cancelled)
        appearance.mode = session.mode
        for item in surfaces { item.panel.orderOut(nil) }
        surfaces.removeAll()
        NSCursor.arrow.set()
        onVisibilityChanged?(false)
        if !cancelled { onCommit?(session.mode) }
    }
}
