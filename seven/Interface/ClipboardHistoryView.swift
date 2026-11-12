import AppKit
import SwiftUI

struct ClipboardHistoryRow: View {
    @ObservedObject var store: LauncherStore
    let entry: ClipboardEntry

    private var selected: Bool { store.selectedClipboardEntry?.id == entry.id }

    var body: some View {
        Button {
            store.select(entry)
            let flags = NSEvent.modifierFlags
            store.launchSelection(paste: true, plainText: flags.contains(.shift))
        } label: {
            HStack(spacing: 8) {
                preview.frame(width: 20, height: 20)
                Text(entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: LauncherLayout.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LauncherLayout.rowCornerRadius, style: .continuous).fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: LauncherLayout.rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { store.select(entry) } }
        .help(entry.detail)
        .accessibilityLabel("Paste \(entry.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay {
            ClipboardSecondaryClick { store.select(entry); store.onShowActions?() }
        }
    }

    @ViewBuilder private var preview: some View {
        if let image = store.clipboard.thumbnail(for: entry) {
            Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: entry.kind == .files ? "doc.fill" : entry.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

}

struct ShortcutKeycap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
    }
}

struct ClipboardHistoryFooter: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject var history: ClipboardHistory

    init(store: LauncherStore) { self.store = store; self.history = store.clipboard }

    var body: some View {
        HStack {
            if history.isPaused { Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Recording paused") }
            if let error = history.storageError { Image(systemName: "exclamationmark.triangle").help(error) }
            Spacer(minLength: 0)
            Button { store.onShowActions?() } label: {
                HStack(spacing: 7) {
                    Text("Actions").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 3) { ShortcutKeycap(key: "⌘"); ShortcutKeycap(key: "K") }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("Actions ⌘K")
            .accessibilityIdentifier("clipboard-actions")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
    }
}


struct ClipboardSecondaryClick: NSViewRepresentable {
    let action: () -> Void
    final class View: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
    }
    func makeNSView(context: Context) -> View { let view = View(); view.action = action; return view }
    func updateNSView(_ view: View, context: Context) { view.action = action }
}
