import AppKit
import Combine
import SwiftUI

enum ClipboardAction: String, CaseIterable, Identifiable {
    case copy, paste, pasteWithoutFormatting, delete, pause, automatic, clear
    var id: String { rawValue }
    var group: Int { self == .copy ? 0 : [.paste, .pasteWithoutFormatting, .delete].contains(self) ? 1 : 2 }
    var symbol: String {
        switch self {
        case .copy: return "document.on.clipboard"
        case .paste: return "clipboard"
        case .pasteWithoutFormatting: return "textformat"
        case .delete, .clear: return "trash"
        case .pause: return "pause.circle"
        case .automatic: return "arrow.turn.down.right"
        }
    }

}

@MainActor
final class ClipboardActionsStore: ObservableObject {
    let launcher: LauncherStore
    @Published var selected: ClipboardAction? = .copy
    var onPerform: ((ClipboardAction) -> Void)?
    private var observations: [AnyCancellable] = []

    init(launcher: LauncherStore) {
        self.launcher = launcher
        observations = [launcher.objectWillChange, launcher.clipboard.objectWillChange].map { publisher in
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    var actions: [ClipboardAction] { ClipboardAction.allCases }
    var listHeight: CGFloat {
        if actions.isEmpty { return 44 }
        let dividers = zip(actions, actions.dropFirst()).filter { pair in pair.0.group != pair.1.group }.count
        return CGFloat(actions.count) * 32 + CGFloat(dividers) * 9 + 12
    }
    var cardHeight: CGFloat { min(listHeight, 260) }
    func title(_ action: ClipboardAction) -> String {
        switch action {
        case .copy: return "Copy to Clipboard"
        case .paste: return "Paste"
        case .pasteWithoutFormatting: return "Paste Without Formatting"
        case .delete: return "Delete Entry"
        case .pause: return launcher.clipboard.isPaused ? "Resume Recording" : "Pause Recording"
        case .automatic: return "Paste Automatically"
        case .clear: return "Clear History"
        }
    }
    func isEnabled(_ action: ClipboardAction) -> Bool {
        switch action {
        case .copy, .paste, .delete: return launcher.selectedClipboardEntry != nil
        case .pasteWithoutFormatting: return launcher.selectedClipboardEntry?.text != nil
        case .clear: return !launcher.clipboard.entries.isEmpty
        default: return true
        }
    }
    func isChecked(_ action: ClipboardAction) -> Bool {
        action == .pause ? launcher.clipboard.isPaused : action == .automatic && launcher.clipboard.pasteAutomatically
    }
    func move(by offset: Int) {
        let enabled = actions.filter(isEnabled)
        guard !enabled.isEmpty else { selected = nil; return }
        let index = selected.flatMap { enabled.firstIndex(of: $0) } ?? (offset > 0 ? -1 : enabled.count)
        selected = enabled[min(max(index + offset, 0), enabled.count - 1)]
    }
    func perform(_ action: ClipboardAction?) { if let action, isEnabled(action) { onPerform?(action) } }
    func execute(_ action: ClipboardAction) {
        switch action {
        case .copy: launcher.launchSelection(respectAutomaticPaste: false)
        case .paste: launcher.launchSelection(paste: true)
        case .pasteWithoutFormatting: launcher.launchSelection(paste: true, plainText: true)
        case .delete: launcher.deleteSelection()
        case .pause: launcher.clipboard.isPaused.toggle()
        case .automatic:
            launcher.clipboard.pasteAutomatically.toggle()
            if launcher.clipboard.pasteAutomatically { ClipboardPaste.requestPermission() }
        case .clear: launcher.clipboard.clear()
        }
    }
}

struct ClipboardActionsView: View {
    @ObservedObject var store: ClipboardActionsStore
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if store.actions.isEmpty {
                            Text("No actions found").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 32)
                        }
                        ForEach(Array(store.actions.enumerated()), id: \.element.id) { index, action in
                            if index > 0, store.actions[index - 1].group != action.group {
                                Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1).padding(.vertical, 4)
                            }
                            actionRow(action).id(action)
                        }
                    }.padding(6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(store.listHeight, 260))
                .onChange(of: store.selected) { _, action in if let action { scroll.scrollTo(action) } }
            }

        }
        .frame(width: 240)
        .background { LauncherMaterial(cornerRadius: 14) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 0.75))
        .padding(8)
    }
    private func actionRow(_ action: ClipboardAction) -> some View {
        let enabled = store.isEnabled(action)
        return Button { store.perform(action) } label: {
            HStack(spacing: 9) {
                Image(systemName: store.isChecked(action) ? "checkmark" : action.symbol)
                    .font(.system(size: 13, weight: .medium)).frame(width: 16)
                Text(store.title(action)).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .foregroundStyle(Color.primary.opacity(enabled ? 0.95 : 0.32))
            .padding(.horizontal, 9).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(store.selected == action && enabled ? 0.10 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { if $0 && enabled { store.selected = action } }
        .accessibilityAddTraits(store.selected == action ? .isSelected : [])
    }
}
