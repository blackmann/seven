import AppKit
import Carbon
import QuartzCore
import SwiftUI

enum NotesLayout {
    static let width = LauncherLayout.width
    static let height: CGFloat = 360
    static let minimumHeight: CGFloat = 240
}

@MainActor
final class NotesPanel: NSPanel {
    var onDoubleEscape: (() -> Void)?
    private var lastEscapeTime: TimeInterval?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func resetEscapeGesture() { lastEscapeTime = nil }

    override func resignKey() {
        resetEscapeGesture()
        super.resignKey()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if isKeyWindow, attachedSheet == nil, NSApp.modalWindow == nil,
               event.keyCode == kVK_Escape, modifiers.isEmpty {
                // Holding Escape must never count as the second press.
                guard !event.isARepeat else { return }
                if let previous = lastEscapeTime,
                   (0...0.5).contains(event.timestamp - previous) {
                    resetEscapeGesture()
                    onDoubleEscape?()
                    return
                }
                lastEscapeTime = event.timestamp
            } else {
                resetEscapeGesture()
            }
        } else if [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .flagsChanged].contains(event.type) {
            resetEscapeGesture()
        }
        // The first Escape still reaches completion, renaming, and text input.
        super.sendEvent(event)
    }

    // If no editor control handles Escape, stop at the window instead of
    // letting NSPanel's default cancellation close it on the first press.
    override func cancelOperation(_ sender: Any?) {}
}

@MainActor
final class NotesController: NSObject, NSWindowDelegate {
    let store: VaultStore
    private(set) var panel: NotesPanel?
    private let windowMask = CAShapeLayer()

    init(store: VaultStore) { self.store = store }

    func show(at anchor: NSPoint) {
        store.refreshFiles()
        let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let preferredSize = panel?.frame.size
            ?? NSSize(width: NotesLayout.width + 2 * LauncherLayout.inset,
                      height: NotesLayout.height + 2 * LauncherLayout.inset)
        let size = NSSize(width: min(preferredSize.width, visible.width - 24),
                          height: min(preferredSize.height, visible.height - 24))
        // Match the launcher's cursor gap and top alignment, flipping left
        // when needed and keeping the editor inside the pointer's screen.
        let contentWidth = size.width - 2 * LauncherLayout.inset
        let opensToLeft = anchor.x + 20 + contentWidth > visible.maxX - 12
        let desiredLeft = opensToLeft ? anchor.x - 20 - contentWidth : anchor.x + 20
        let cardLeft = min(max(desiredLeft, visible.minX + 12), visible.maxX - contentWidth - 12)
        let desiredTop = min(anchor.y + 28, visible.maxY - 12)
        let frame = NSRect(x: cardLeft - LauncherLayout.inset,
                           y: max(desiredTop + LauncherLayout.inset - size.height, visible.minY + 8),
                           width: size.width, height: size.height)
        if let panel {
            panel.resetEscapeGesture()
            panel.setFrame(frame, display: true)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // Notes owns application focus so modifier-only gestures stay in Seven.
        let panel = NotesPanel(contentRect: frame, styleMask: [.borderless, .resizable],
                               backing: .buffered, defer: false)
        panel.onDoubleEscape = { [weak self] in self?.close() }
        panel.title = "seven Notes"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: NotesLayout.width + 2 * LauncherLayout.inset,
                               height: NotesLayout.minimumHeight + 2 * LauncherLayout.inset)
        panel.delegate = self
        let host = NSHostingView(rootView: NotesView(vaultStore: store) { [weak self] in self?.close() })
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        updateWindowShape()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func updateWindowShape() {
        guard let frame = panel?.contentView?.superview else { return }
        // AppKit inserts sheet dimming alongside the hosting view. Mask their
        // common ancestor so native alerts cannot paint into the clear margin.
        frame.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        windowMask.frame = frame.bounds
        windowMask.path = RoundedRectangle(cornerRadius: LauncherLayout.cornerRadius, style: .continuous)
            .path(in: frame.bounds.insetBy(dx: LauncherLayout.inset, dy: LauncherLayout.inset)).cgPath
        frame.layer?.mask = windowMask
        CATransaction.commit()
        panel?.invalidateShadow()
    }

    func windowDidResize(_ notification: Notification) { updateWindowShape() }

    func close() {
        panel?.resetEscapeGesture()
        guard prepareToClose() else { return }
        // Keep the editor and its undo/navigation state alive between presentations.
        panel?.orderOut(nil)
    }

    func prepareToClose() -> Bool {
        guard store.hasUnsavedFileChanges else { return true }
        store.updateDraft(store.draft)
        guard store.hasUnsavedFileChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "This note has unsaved changes"
        alert.informativeText = store.error ?? "The note could not be saved."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        if alert.runModal() == .alertSecondButtonReturn { store.discardUnsavedChanges() }
        return !store.hasUnsavedFileChanges
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }
}

/// Drag only the unused space in the header, leaving editor selection untouched.
struct NotesWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// Restore typing focus when the browser gives way to a document or linked note.
struct NotesEditorFocus: NSViewRepresentable {
    let documentID: String
    let isEditing: Bool

    final class Coordinator { var request = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let request = "\(documentID)|\(isEditing)"
        guard context.coordinator.request != request else { return }
        context.coordinator.request = request
        guard isEditing else { return }
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView] in
            guard coordinator.request == request, let window = nsView?.window,
                  let content = window.contentView, let editor = Self.editor(in: content) else { return }
            window.makeFirstResponder(editor)
        }
    }

    private static func editor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, !text.isFieldEditor, text.isEditable { return text }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
}
