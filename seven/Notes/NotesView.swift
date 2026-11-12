import AppKit
import SwiftUI
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex

private enum LatexRendering {
  static let bridge = SwiftMathBridge()
}

private enum CodeHighlighters {
  static let bridge = HighlighterSwiftBridge(
    lightBackground: NSColor.black.withAlphaComponent(0.045),
    darkBackground: NSColor.white.withAlphaComponent(0.06),
    preferredFontNames: ["Menlo-Regular"]
  )
}

private struct NotesGlassControls: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.buttonStyle(.glass).buttonBorderShape(.capsule)
    } else {
      content.buttonStyle(.bordered).buttonBorderShape(.capsule)
    }
  }
}

private struct NotesGlassIcon: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
    } else {
      content.buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
    }
  }
}

private struct FloatingCompletionPanel<PanelContent: View>: NSViewRepresentable {
  let isPresented: Bool
  let anchorRect: CGRect
  let contentSize: CGSize
  @ViewBuilder let content: () -> PanelContent

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let panelContent = AnyView(content())
    guard let parentWindow = nsView.window else {
      if isPresented {
        DispatchQueue.main.async {
          context.coordinator.update(
            isPresented: isPresented,
            anchorRect: anchorRect,
            contentSize: contentSize,
            content: panelContent,
            relativeTo: nsView
          )
        }
      }
      return
    }
    context.coordinator.update(
      isPresented: isPresented,
      anchorRect: anchorRect,
      contentSize: contentSize,
      content: panelContent,
      relativeTo: nsView,
      parentWindow: parentWindow
    )
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.dismiss()
  }

  final class Coordinator {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?

    func update(
      isPresented: Bool,
      anchorRect: CGRect,
      contentSize: CGSize,
      content: AnyView,
      relativeTo anchorView: NSView,
      parentWindow suppliedParent: NSWindow? = nil
    ) {
      guard isPresented else {
        dismiss()
        return
      }
      guard let parentWindow = suppliedParent ?? anchorView.window else { return }

      let panel = panel ?? makePanel()
      let hostingView: NSHostingView<AnyView>
      if let existing = self.hostingView {
        existing.rootView = content
        hostingView = existing
      } else {
        let created = NSHostingView(rootView: content)
        created.frame = NSRect(origin: .zero, size: contentSize)
        panel.contentView = created
        self.hostingView = created
        hostingView = created
      }
      hostingView.frame = NSRect(origin: .zero, size: contentSize)

      if panel.parent !== parentWindow {
        panel.parent?.removeChildWindow(panel)
        parentWindow.addChildWindow(panel, ordered: .above)
      }

      let localAnchor = NSRect(
        x: anchorRect.minX,
        y: anchorView.bounds.height - anchorRect.maxY,
        width: anchorRect.width,
        height: anchorRect.height
      )
      let windowAnchor = anchorView.convert(localAnchor, to: nil)
      let screenAnchor = parentWindow.convertToScreen(windowAnchor)
      let visibleFrame = (parentWindow.screen ?? NSScreen.main)?.visibleFrame ?? parentWindow.screen?.frame ?? .zero
      let edgeInset: CGFloat = 12
      let gap: CGFloat = 7
      let width = min(contentSize.width, max(1, visibleFrame.width - edgeInset * 2))
      let belowTop = screenAnchor.minY - gap
      let aboveBottom = screenAnchor.maxY + gap
      let spaceBelow = max(0, belowTop - visibleFrame.minY - edgeInset)
      let spaceAbove = max(0, visibleFrame.maxY - edgeInset - aboveBottom)
      let placeBelow = spaceBelow >= contentSize.height || (spaceBelow >= spaceAbove && spaceBelow > 0)
      let height = min(contentSize.height, max(1, placeBelow ? spaceBelow : spaceAbove))
      let proposedX = screenAnchor.minX
      let x = min(
        max(visibleFrame.minX + edgeInset, proposedX),
        visibleFrame.maxX - edgeInset - width
      )
      let y = placeBelow ? belowTop - height : aboveBottom

      panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
      panel.orderFront(nil)
    }

    func dismiss() {
      guard let panel else { return }
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
      let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
      )
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.isMovable = false
      panel.hidesOnDeactivate = true
      panel.animationBehavior = .none
      panel.collectionBehavior = [.transient]
      panel.becomesKeyOnlyIfNeeded = true
      self.panel = panel
      return panel
    }
  }
}

struct NotesView: View {
  @Bindable var vaultStore: VaultStore
  var onClose: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  private let editorFontName = NSFont.systemFont(ofSize: 14).fontName
  private let editorFontSize = 14.0
  @State private var searchResults: [FileSearchResult] = []
  @FocusState private var isSearchFocused: Bool
  @State private var isAddingVault = false
  @State private var searchQuery = ""
  @State private var isShowingSearch = true
  @State private var hoveredFileID: String?
  @State private var hoveredSearchLineID: String?
  @State private var filePendingDeletion: VaultFile?
  @State private var isWikiLinkActive = false
  @State private var inlineSelection: InlineSelectionState?
  @State private var pendingInlineReplacement: InlineReplacementRequest?
  @State private var linkedFileToOpenAfterReplacement: VaultFile?
  @State private var inlinePreviewRect = CGRect.zero
  @State private var selectedLinkSuggestion = 0
  @State private var linkedDocumentHistory: [VaultFile] = []
  @State private var isEditingFileName = false
  @State private var editedFileName = ""
  @FocusState private var isFileNameFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider().opacity(0.5)
      ZStack {
        NativeTextViewWrapper(
          text: Binding(get: { vaultStore.draft }, set: { vaultStore.updateDraft($0) }),
          isWikiLinkActive: $isWikiLinkActive,
          pendingInlineReplacement: $pendingInlineReplacement,
          configuration: editorConfiguration,
          fontName: editorFontName,
          fontSize: editorFontSize,
          documentId: editorDocumentID,
          isEditable: !isShowingSearch,
          onLinkClick: openEditorLink,
          onCaretRectChange: { inlinePreviewRect = $0 },
          onInlineSelectionChange: updateInlineSelection,
          onInlinePreviewKey: handleInlinePreviewKey,
          header: vaultStore.selectedFile.map { AnyView(documentHeader(for: $0)) }
        )
          .background {
            FloatingCompletionPanel(
              isPresented: isWikiLinkSuggestionActive && !linkSuggestions.isEmpty && !isShowingSearch,
              anchorRect: inlinePreviewRect,
              contentSize: CGSize(width: 300, height: linkAutocompleteDesiredHeight)
            ) {
              linkAutocompletePanel
            }
          }
          .opacity(isShowingSearch ? 0 : 1)
          .allowsHitTesting(!isShowingSearch)
          .accessibilityHidden(isShowingSearch)
          .padding(.bottom, linkedDocumentHistory.isEmpty ? 16 : 74)
          .overlay(alignment: .bottom) {
            if !linkedDocumentHistory.isEmpty && !isShowingSearch {
              linkedDocumentBackBar
            }
          }

        if isShowingSearch {
          searchPage
        }
      }
    }
    .frame(minWidth: NotesLayout.width, minHeight: NotesLayout.minimumHeight)
    .background { LauncherMaterial() }
    .clipShape(RoundedRectangle(cornerRadius: LauncherLayout.cornerRadius, style: .continuous))
    .overlay { LauncherBorder() }
    .padding(LauncherLayout.inset)
    .background(NotesEditorFocus(documentID: editorDocumentID, isEditing: !isShowingSearch))
    .sheet(isPresented: $isAddingVault) {
      AddVaultView { folder in
        try vaultStore.add(folder)
      }
    }
    .alert("Vault unavailable", isPresented: Binding(
      get: { vaultStore.error != nil },
      set: { if !$0 { vaultStore.error = nil } }
    )) {
      if vaultStore.hasUnsavedFileChanges {
        Button("Retry Save") { vaultStore.updateDraft(vaultStore.draft) }
        Button("Discard Changes", role: .destructive) { vaultStore.discardUnsavedChanges() }
      }
      Button("OK", role: .cancel) { vaultStore.error = nil }
    } message: {
      Text(vaultStore.error ?? "")
    }
    .alert(
      "Move \(filePendingDeletion?.name ?? "file") to the Trash?",
      isPresented: Binding(
        get: { filePendingDeletion != nil },
        set: { if !$0 { filePendingDeletion = nil } }
      ),
      presenting: filePendingDeletion
    ) { file in
      Button("Move to Trash", role: .destructive) {
        _ = vaultStore.delete(file)
        filePendingDeletion = nil
      }
      Button("Cancel", role: .cancel) {
        filePendingDeletion = nil
      }
    } message: { file in
      Text("“\(file.name)” will be removed from this vault and can be recovered from the Trash.")
    }
    .task(id: searchRequest) {
      let request = searchRequest
      guard isShowingSearch else { return }
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      let results = await Task.detached(priority: .userInitiated) {
        VaultSearch.results(for: request.query, files: request.files)
      }.value
      guard !Task.isCancelled else { return }
      searchResults = results
    }
    .onChange(of: isShowingSearch, initial: true) { _, showing in
      if showing {
        inlineSelection = nil
        vaultStore.refreshFiles()
        isSearchFocused = true
      }
    }
    .onChange(of: searchQuery) { _, _ in searchResults = [] }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      if isShowingSearch { vaultStore.refreshFiles() }
    }
    .onChange(of: editorDocumentID) { _, _ in
      isEditingFileName = false
      isFileNameFocused = false
      inlineSelection = nil
      isWikiLinkActive = false
    }
    .onChange(of: isFileNameFocused) { _, focused in
      if !focused && isEditingFileName { commitFileName() }
    }
    .onChange(of: vaultStore.selectedID) { _, _ in
      linkedDocumentHistory.removeAll()
      isShowingSearch = true
      searchResults = []
    }
    .onChange(of: pendingInlineReplacement?.id) { previousID, currentID in
      guard previousID != nil, currentID == nil,
            let file = linkedFileToOpenAfterReplacement else { return }
      linkedFileToOpenAfterReplacement = nil
      navigateToLinkedFile(file)
    }
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      vaultMenu
      Spacer(minLength: 0)
      if !isShowingSearch {
        Button { showFiles() } label: {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .frame(width: 28, height: 28)
        }
          .modifier(NotesGlassIcon())
          .help("Browse files (⌘⇧F)")
          .accessibilityLabel("Browse files")
      }
      Button { createNote() } label: {
        Image(systemName: "square.and.pencil")
          .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
          .frame(width: 28, height: 28)
      }
        .modifier(NotesGlassIcon())
        .disabled(vaultStore.selectedVault == nil)
        .keyboardShortcut("n", modifiers: .command)
        .help("New note (⌘N)")
        .accessibilityLabel("New note")
    }
    .controlSize(.regular)
    .font(.system(size: 13))
    .padding(.horizontal, 12)
    .frame(height: 48)
    .background(NotesWindowDragArea())
    .background {
      HStack {
        Button("Browse files", action: showFiles)
          .keyboardShortcut("f", modifiers: [.command, .shift])
        Button("Close notes", action: onClose)
          .keyboardShortcut("w", modifiers: .command)
      }
      .hidden()
    }
  }

  private func showFiles() {
    isShowingSearch = true
    isSearchFocused = true
    vaultStore.refreshFiles()
  }

  private func createNote() {
    if vaultStore.createNote() {
      linkedDocumentHistory.removeAll()
      isShowingSearch = false
    }
  }

  private var searchRequest: VaultSearch.Request {
    VaultSearch.Request(query: normalizedSearchQuery, files: vaultStore.files, isActive: isShowingSearch)
  }

  private var vaultMenu: some View {
    Menu {
      if vaultStore.vaults.isEmpty {
        Text("No vaults yet")
      } else {
        Picker("Vault", selection: Binding<UUID?>(
          get: { vaultStore.selectedID },
          set: { vaultStore.select($0) }
        )) {
          ForEach(vaultStore.vaults) { vault in
            Text(vaultStore.name(for: vault)).tag(Optional(vault.id))
          }
        }
        .pickerStyle(.inline)
      }
      Divider()
      Button("Scratchpad", systemImage: "note.text") {
        if vaultStore.openDraft() {
          linkedDocumentHistory.removeAll()
          isShowingSearch = false
        }
      }
      .disabled(vaultStore.selectedVault == nil)
      Button("Refresh Files", systemImage: "arrow.clockwise", action: showFiles)
      Button("Show Vault in Finder", systemImage: "folder") {
        if let url = vaultStore.vaultURL { NSWorkspace.shared.open(url) }
      }
      .disabled(vaultStore.selectedVault == nil)
      Divider()
      Button("Add New Vault…", systemImage: "folder.badge.plus") {
        isAddingVault = true
      }
    } label: {
      Label(vaultStore.selectedVault.map { vaultStore.name(for: $0) } ?? "Select Vault", systemImage: "folder")
    }
    .labelStyle(.titleAndIcon)
    .menuStyle(.button)
    .modifier(NotesGlassControls())
    .lineLimit(1)
    .truncationMode(.middle)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help("Select a vault")
  }

  private var editorConfiguration: MarkdownEditorConfiguration {
    var configuration = MarkdownEditorConfiguration.default
    configuration.safeAreaInsets = SafeAreaInsets(top: 8)
    configuration.textInsets = TextInsets(horizontal: 12)
    configuration.lists.indentPerLevel = 12
    configuration.services = MarkdownEditorServices(
      wikiLinks: vaultLinkResolver,
      syntaxHighlighter: CodeHighlighters.bridge,
      latex: LatexRendering.bridge
    )
    return configuration
  }

  private var editorDocumentID: String {
    "\(vaultStore.selectedID?.uuidString ?? "scratch")|\(vaultStore.selectedFile?.relativePath ?? "draft")"
  }

  private var vaultLinkResolver: VaultLinkResolver {
    VaultLinkResolver(
      paths: vaultStore.files.filter { $0.name.lowercased().hasSuffix(".md") }.map(\.relativePath),
      currentFolder: vaultStore.selectedFile.map { ($0.relativePath as NSString).deletingLastPathComponent } ?? ""
    )
  }

  private func openEditorLink(_ target: String) {
    if target.hasPrefix("#") {
      vaultStore.refreshFiles()
      searchQuery = target
      isShowingSearch = true
      return
    }
    vaultStore.refreshFiles()
    guard let path = vaultLinkResolver.matchingPath(for: target),
          let file = vaultStore.files.first(where: { $0.relativePath == path }) else { return }
    navigateToLinkedFile(file)
  }

  private var linkSuggestions: [VaultFile] {
    guard let inlineSelection else { return [] }
    guard case .wikiLink = inlineSelection.kind else { return [] }
    let query = wikiLinkQuery(from: inlineSelection.selection.placeholder)
    let currentID = vaultStore.selectedFile?.id
    let candidates = vaultStore.files.filter {
      $0.id != currentID && $0.name.lowercased().hasSuffix(".md")
    }
    guard !query.isEmpty else { return Array(candidates.prefix(8)) }

    return Array(candidates.filter { file in
      file.name.deletingMarkdownExtension.localizedCaseInsensitiveContains(query)
        || file.relativePath.deletingMarkdownExtension.localizedCaseInsensitiveContains(query)
    }.sorted { lhs, rhs in
      let leftName = lhs.name.deletingMarkdownExtension
      let rightName = rhs.name.deletingMarkdownExtension
      let leftStarts = leftName.lowercased().hasPrefix(query.lowercased())
      let rightStarts = rightName.lowercased().hasPrefix(query.lowercased())
      if leftStarts != rightStarts { return leftStarts }
      return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }.prefix(8))
  }

  private var linkAutocompletePanel: some View {
    ScrollView {
      LazyVStack(spacing: 2) {
        ForEach(Array(linkSuggestions.enumerated()), id: \.element.id) { index, file in
          Button {
            commitLinkSuggestion(file)
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "doc.text")
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
              VStack(alignment: .leading, spacing: 2) {
                Text(file.name.deletingMarkdownExtension)
                  .foregroundStyle(Color(nsColor: .labelColor))
                if !file.folderPrefix.isEmpty {
                  Text(file.folderPrefix.dropLast())
                    .font(uiFont(size: max(10, editorFontSize - 4)))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
              }
              Spacer(minLength: 0)
            }
            .font(uiFont(size: max(12, editorFontSize - 2)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
              index == selectedLinkSuggestion
                ? Color(nsColor: .labelColor).opacity(0.10)
                : .clear,
              in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .onHover { hovering in
            if hovering { selectedLinkSuggestion = index }
          }
        }
      }
      .padding(6)
    }
    .background { LauncherMaterial(cornerRadius: 12) }
  }

  private var linkAutocompleteDesiredHeight: CGFloat {
    let rowsHeight = linkSuggestions.reduce(CGFloat.zero) { height, file in
      height + (file.folderPrefix.isEmpty ? 42 : 56)
    }
    return min(236, rowsHeight + 12)
  }

  private var linkedDocumentBackBar: some View {
    HStack {
      Button {
        navigateBackToReferrer()
      } label: {
        Label(referrerButtonTitle, systemImage: "arrow.turn.down.left")
          .font(uiFont(size: max(12, editorFontSize - 2)))
          .lineLimit(1)
      }
      .modifier(NotesGlassControls())
      .keyboardShortcut("[", modifiers: .command)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
  }

  private var referrerButtonTitle: String {
    let name = linkedDocumentHistory.last?.name.deletingMarkdownExtension ?? "Previous note"
    guard name.count > 16 else { return name }
    return String(name.prefix(15)) + "…"
  }

  private func updateInlineSelection(_ state: InlineSelectionState?) {
    let previousPlaceholder = inlineSelection?.selection.placeholder
    inlineSelection = state
    if previousPlaceholder != state?.selection.placeholder {
      selectedLinkSuggestion = 0
    } else if selectedLinkSuggestion >= linkSuggestions.count {
      selectedLinkSuggestion = max(0, linkSuggestions.count - 1)
    }
  }

  private func handleInlinePreviewKey(_ key: InlinePreviewKey) -> Bool {
    let suggestions = linkSuggestions
    switch key {
    case .moveUp:
      guard !suggestions.isEmpty else { return false }
      selectedLinkSuggestion = (selectedLinkSuggestion - 1 + suggestions.count) % suggestions.count
      return true
    case .moveDown:
      guard !suggestions.isEmpty else { return false }
      selectedLinkSuggestion = (selectedLinkSuggestion + 1) % suggestions.count
      return true
    case .confirm:
      guard suggestions.indices.contains(selectedLinkSuggestion) else { return false }
      commitLinkSuggestion(suggestions[selectedLinkSuggestion])
      return true
    case .confirmAndOpen:
      guard suggestions.indices.contains(selectedLinkSuggestion) else { return false }
      commitLinkSuggestion(suggestions[selectedLinkSuggestion], openAfterCommit: true)
      return true
    case .cancel:
      inlineSelection = nil
      return true
    }
  }

  private func commitLinkSuggestion(_ file: VaultFile, openAfterCommit: Bool = false) {
    guard let selection = inlineSelection?.selection else { return }
    let displayName = file.name.deletingMarkdownExtension
    pendingInlineReplacement = InlineReplacementRequest(
      documentId: editorDocumentID,
      selection: selection,
      storageFragment: "[[\(displayName)|\(file.relativePath)]]",
      isImageEmbedMode: false
    )
    inlineSelection = nil
    selectedLinkSuggestion = 0

    if openAfterCommit {
      linkedFileToOpenAfterReplacement = file
    }
  }

  private func wikiLinkQuery(from placeholder: String) -> String {
    var value = placeholder
    if value.hasPrefix("[[") { value.removeFirst(2) }
    if value.hasSuffix("]]" ) { value.removeLast(2) }
    if let pipe = value.firstIndex(of: "|") { value = String(value[..<pipe]) }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isWikiLinkSuggestionActive: Bool {
    guard let inlineSelection else { return false }
    guard case .wikiLink = inlineSelection.kind else { return false }
    return true
  }

  private func navigateToLinkedFile(_ file: VaultFile) {
    guard vaultStore.selectedFile?.id != file.id else { return }
    let referrer = vaultStore.selectedFile
    if vaultStore.open(file) {
      if let referrer { linkedDocumentHistory.append(referrer) }
      isShowingSearch = false
    }
  }

  private func navigateBackToReferrer() {
    guard let referrer = linkedDocumentHistory.popLast() else { return }
    vaultStore.refreshFiles()
    guard let current = vaultStore.files.first(where: { $0.id == referrer.id }),
          vaultStore.open(current) else {
      linkedDocumentHistory.append(referrer)
      return
    }
    isShowingSearch = false
  }

  private func documentHeader(for file: VaultFile) -> some View {
    let parts = fileNameParts(file.name)
    return VStack(spacing: 8) {
      HStack(spacing: 0) {
        if isEditingFileName {
          TextField("File name", text: $editedFileName)
            .textFieldStyle(.plain)
            .frame(minWidth: 40, idealWidth: editedFileNameWidth, maxWidth: editedFileNameWidth)
            .focused($isFileNameFocused)
            .onSubmit { commitFileName() }
            .onExitCommand { cancelFileNameEdit() }
        } else {
          Text(parts.name)
            .foregroundStyle(Color(nsColor: .labelColor))
            .textSelection(.disabled)
            .onTapGesture {
              editedFileName = parts.name
              isEditingFileName = true
              isFileNameFocused = true
            }
            .help("Click to rename")
        }
        Text(parts.ext)
          .foregroundStyle(.secondary)
          .textSelection(.disabled)
      }
      .font(uiFont(size: editorFontSize))
      .lineLimit(1)
      .truncationMode(.middle)

      TimelineView(.periodic(from: .now, by: 60)) { context in
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { documentDates(for: file, relativeTo: context.date) }
          VStack(spacing: 3) { documentDates(for: file, relativeTo: context.date) }
        }
        .font(uiFont(size: max(11, editorFontSize - 3)))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
    .padding(.top, 16)
    .padding(.bottom, 14)
  }

  @ViewBuilder
  private func documentDates(for file: VaultFile, relativeTo date: Date) -> some View {
    Text(file.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "Date unavailable")
    if let modifiedAt = file.modifiedAt,
       (0..<2 * 24 * 60 * 60).contains(date.timeIntervalSince(modifiedAt)) {
      Text("Last updated \(relativeUpdateTime(modifiedAt, relativeTo: date))")
    }
  }

  private func relativeUpdateTime(_ date: Date, relativeTo now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
  }

  private func fileNameParts(_ name: String) -> (name: String, ext: String) {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
          name.index(after: dot) != name.endIndex else { return (name, "") }
    return (String(name[..<dot]), String(name[dot...]))
  }

  private var editedFileNameWidth: CGFloat {
    let font = NSFont.systemFont(ofSize: editorFontSize)
    let textWidth = ceil((editedFileName as NSString).size(withAttributes: [.font: font]).width)
    return editedFileName.isEmpty ? 60 : min(600, textWidth + 2)
  }

  private func commitFileName() {
    guard isEditingFileName, let file = vaultStore.selectedFile else { return }
    if vaultStore.renameSelectedFile(to: editedFileName + fileNameParts(file.name).ext) {
      cancelFileNameEdit()
    }
  }

  private func cancelFileNameEdit() {
    isEditingFileName = false
    isFileNameFocused = false
  }

  private func uiFont(size: CGFloat) -> Font { .system(size: size) }

  private var searchPage: some View {
    VStack(spacing: 0) {
      persistentSearchField
      Divider().opacity(0.5)
      fileBrowserList
    }
  }

  private var persistentSearchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))

      TextField("Search file contents", text: $searchQuery)
        .textFieldStyle(.plain)
        .font(uiFont(size: max(13, editorFontSize - 1)))
        .disabled(vaultStore.selectedVault == nil)
        .focused($isSearchFocused)

      if !searchQuery.isEmpty {
        Button {
          searchQuery = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 34)
    .background(
      Color(nsColor: .labelColor).opacity(0.065),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var fileBrowserList: some View {
    let results = searchResults
    return List {
      if vaultStore.selectedVault == nil {
        VStack(spacing: 12) {
          Text("Your notes, in one place").font(.headline)
          Text("Choose a folder to browse and write Markdown notes.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Add Vault…") { isAddingVault = true }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(24)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      } else if normalizedSearchQuery.isEmpty {
        if vaultStore.files.isEmpty {
          emptyListRow("No files in this vault.")
        } else {
          ForEach(vaultStore.files) { file in
            fileRow(file)
              .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
          }
        }
      } else if results.isEmpty {
        emptyListRow("No matches for “\(normalizedSearchQuery)”.")
      } else {
        ForEach(results) { result in
          searchResultRow(result)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
  }

  private func fileRow(_ file: VaultFile) -> some View {
    Button {
      openFile(file)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        filePathLabel(file, size: editorFontSize)

        Text(file.createdAt.map { "\($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Creation date unavailable")
          .font(uiFont(size: max(10, editorFontSize - 3)))
          .foregroundStyle(Color(nsColor: .secondaryLabelColor))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      hoveredFileID == file.id
        ? Color(nsColor: .labelColor).opacity(0.07)
        : .clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .onHover { hovering in
      hoveredFileID = hovering ? file.id : nil
    }
    .contextMenu {
      fileContextMenu(file)
    }
  }

  private func searchResultRow(_ result: FileSearchResult) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        openFile(result.file)
      } label: {
        searchResultFilePathLabel(result.file)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 2)

      if !result.matches.isEmpty {
        VStack(spacing: 1) {
          ForEach(result.matches) { match in
            let lineID = searchLineID(file: result.file, match: match)
            Button {
              openFile(result.file)
            } label: {
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(match.lineNumber)")
                  .font(.system(size: max(10, editorFontSize - 4), design: .monospaced))
                  .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                  .frame(minWidth: 28, alignment: .trailing)

                highlightedSearchLine(match.text)
                  .font(uiFont(size: max(12, editorFontSize - 1)))
                  .lineLimit(1)
                  .truncationMode(.tail)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 6)
              .padding(.vertical, 5)
              .background(
                hoveredSearchLineID == lineID
                  ? Color(nsColor: .labelColor).opacity(0.08)
                  : .clear,
                in: RoundedRectangle(cornerRadius: 6)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
              hoveredSearchLineID = hovering ? lineID : nil
            }
          }
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      hoveredFileID == result.file.id
        ? Color(nsColor: .labelColor).opacity(0.045)
        : .clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .onHover { hovering in
      hoveredFileID = hovering ? result.file.id : nil
      if !hovering { hoveredSearchLineID = nil }
    }
    .contextMenu {
      fileContextMenu(result.file)
    }
  }

  private func filePathLabel(_ file: VaultFile, size: CGFloat) -> some View {
    HStack(spacing: 0) {
      Text(file.folderPrefix)
        .font(uiFont(size: size))
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
      Text(file.name)
        .font(uiFont(size: size))
        .foregroundStyle(Color(nsColor: .labelColor))
    }
    .lineLimit(1)
  }

  private func searchResultFilePathLabel(_ file: VaultFile) -> some View {
    HStack(spacing: 0) {
      Text(file.folderPrefix)
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
      highlightedSearchLine(file.name)
        .foregroundStyle(Color(nsColor: .labelColor))
    }
    .font(uiFont(size: editorFontSize))
    .lineLimit(1)
  }

  private func fileContextMenu(_ file: VaultFile) -> some View {
    Button("Move to Trash…", systemImage: "trash", role: .destructive) {
      filePendingDeletion = file
    }
  }

  private func searchLineID(file: VaultFile, match: SearchLineMatch) -> String {
    "\(file.id)|\(match.id)"
  }

  private func emptyListRow(_ message: String) -> some View {
    Text(message)
      .font(uiFont(size: editorFontSize))
      .foregroundStyle(Color(nsColor: .secondaryLabelColor))
      .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
      .padding(24)
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }

  private var normalizedSearchQuery: String {
    searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func highlightedSearchLine(_ line: String) -> Text {
    let query = normalizedSearchQuery
    guard !query.isEmpty else { return Text(line) }

    var result = AttributedString()
    var remaining = line[line.startIndex...]
    while let range = remaining.range(of: query, options: [.caseInsensitive]) {
      result.append(AttributedString(String(remaining[..<range.lowerBound])))
      var highlighted = AttributedString(String(remaining[range]))
      highlighted.foregroundColor = Color(nsColor: .controlAccentColor)
      highlighted.inlinePresentationIntent = .stronglyEmphasized
      result.append(highlighted)
      remaining = remaining[range.upperBound...]
    }
    result.append(AttributedString(String(remaining)))
    return Text(result)
  }

  private func openFile(_ file: VaultFile) {
    if vaultStore.open(file) {
      linkedDocumentHistory.removeAll()
      isShowingSearch = false
    }
  }
}
