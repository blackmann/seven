import AppKit
import SwiftUI

enum SevenWindowLevel {
    // Stay above other apps' modal, floating, status, and popup windows.
    static let overlay = NSWindow.Level.screenSaver
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlaySurface: NSView {
    let hud: NSHostingView<SwitcherHUD>
    var onScroll: ((NSEvent) -> Void)?
    var onKey: ((NSEvent) -> Void)?
    var onFlags: ((NSEvent) -> Void)?
    var onClick: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    init(appearance: SwitcherAppearance) {
        hud = NSHostingView(rootView: SwitcherHUD(appearance: appearance))
        super.init(frame: .zero)
        hud.setFrameSize(SwitcherHUD.size)
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hud)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mode switcher. Scroll up for Launcher, down for Image. Escape cancels.")
        setAccessibilityValue(appearance.mode.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) { onFlags?(event) }
    override func mouseDown(with event: NSEvent) { onClick?(false) }
    override func rightMouseDown(with event: NSEvent) { onClick?(true) }

    func placeHUD(at point: NSPoint, visible: Bool) {
        hud.isHidden = !visible
        guard visible else { return }
        hud.setFrameOrigin(NSPoint(x: point.x - SwitcherHUD.cursorAnchor.x, y: point.y - SwitcherHUD.cursorAnchor.y))
    }
}
