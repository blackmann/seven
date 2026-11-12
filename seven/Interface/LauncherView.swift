import AppKit
import SwiftUI

enum LauncherDisplayedResults: Equatable {
    case applications([LauncherSearchResult])
    case clipboard([ClipboardEntry])
    case calculations([LauncherCalculation])
    case dictionary(LauncherDictionaryResult)

    var count: Int {
        switch self {
        case .applications(let results): return results.count
        case .clipboard(let entries): return entries.count
        case .calculations(let entries): return entries.count
        case .dictionary(let result): return result.hasDefinition ? 1 : 0
        }
    }

    var shouldExpand: Bool {
        if case .calculations = self { return true }
        return count > 0
    }
}

@MainActor
final class LauncherResultsPresentation: ObservableObject {
    static let expansionDuration = 0.20
    static let rowDuration = 0.14
    static let stagger = 0.025

    @Published private(set) var results = LauncherDisplayedResults.applications([])
    @Published private(set) var isExpanded = false
    @Published private(set) var rowsVisible = false
    var firstVisibleRow = 0
    private var wantsResults = false
    private var expansionDeadline = ContinuousClock.now
    private var transitionTask: Task<Void, Never>?

    func update(_ results: LauncherDisplayedResults, reduceMotion: Bool) {
        let shouldExpand = results.shouldExpand
        // Keep outgoing rows alive until their exit finishes. Nonempty searches
        // still update immediately, without restarting the opening sequence.
        if shouldExpand { self.results = results }
        if reduceMotion {
            cancel()
            self.results = results
            wantsResults = shouldExpand
            isExpanded = shouldExpand
            rowsVisible = shouldExpand
            return
        }
        guard shouldExpand != wantsResults else { return }
        wantsResults = shouldExpand
        cancel()

        if shouldExpand {
            if !isExpanded { expansionDeadline = .now.advanced(by: .seconds(Self.expansionDuration)) }
            let deadline = expansionDeadline
            withAnimation(.easeInOut(duration: Self.expansionDuration)) { isExpanded = true }
            transitionTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                self.rowsVisible = true
            }
        } else {
            let visibleCount = min(LauncherLayout.visibleRowCount, max(0, self.results.count - firstVisibleRow))
            let exitDuration = rowsVisible ? Self.rowDuration + Double(max(0, visibleCount - 1)) * Self.stagger : 0
            rowsVisible = false
            transitionTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(exitDuration))
                    guard let self, !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: Self.expansionDuration)) { self.isExpanded = false }
                    try await Task.sleep(for: .seconds(Self.expansionDuration))
                    guard !Task.isCancelled else { return }
                    self.results = results
                } catch { return }
            }
        }
    }

    func rowDelay(at index: Int) -> Double {
        let last = max(0, min(LauncherLayout.visibleRowCount, results.count - firstVisibleRow) - 1)
        let position = min(max(0, index - firstVisibleRow), last)
        return Double(rowsVisible ? position : last - position) * Self.stagger
    }

    func cancel() {
        transitionTask?.cancel()
        transitionTask = nil
    }

    deinit { transitionTask?.cancel() }
}

struct LauncherMaterial: View {
    var cornerRadius: CGFloat = LauncherLayout.cornerRadius
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
    }
}

struct LauncherBorder: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        RoundedRectangle(cornerRadius: LauncherLayout.cornerRadius, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.20 : 0.65),
                                                   .black.opacity(colorScheme == .dark ? 0.22 : 0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
            .allowsHitTesting(false)
    }
}

private struct LauncherAnimatedHeight: AnimatableModifier {
    var height: CGFloat
    let onChange: (CGFloat) -> Void

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: height, alignment: .top)
            .onChange(of: height, initial: true) { _, value in onChange(value) }
    }
}

struct LauncherView: View {
    @ObservedObject var store: LauncherStore
    let expandsFromRight: Bool
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @StateObject private var presentation = LauncherResultsPresentation()
    @FocusState private var searchFocused: Bool
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    if store.needsAccessibilityAccess {
                        Button("Open System Settings") { ClipboardPaste.openAccessibilitySettings() }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: LauncherLayout.errorHeight)
            }
            VStack(spacing: 0) {
                separator
                resultsArea
                    .frame(height: LauncherLayout.resultsHeight)
                    .clipped()
            }
            .frame(height: presentation.isExpanded ? 1 + LauncherLayout.resultsHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(presentation.rowsVisible && store.hasExpandedResults)
            .accessibilityHidden(!presentation.rowsVisible || !store.hasExpandedResults)
            if store.mode == .clipboard {
                separator
                ClipboardHistoryFooter(store: store)
                    .frame(height: LauncherLayout.footerHeight)
            }
        }
        .frame(width: LauncherLayout.width)
        .modifier(LauncherAnimatedHeight(height: cardHeight, onChange: onHeightChange))
        .opacity(revealed ? 1 : 0)
        .frame(width: revealed ? LauncherLayout.width : 24, alignment: expandsFromRight ? .trailing : .leading)
        .background { LauncherMaterial() }
        .clipShape(RoundedRectangle(cornerRadius: LauncherLayout.cornerRadius, style: .continuous))
        .overlay { LauncherBorder() }
        .frame(maxWidth: .infinity, alignment: expandsFromRight ? .trailing : .leading)
        .padding(LauncherLayout.inset)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: currentResults, initial: true) { _, results in
            presentation.update(results, reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, _ in
            presentation.update(currentResults, reduceMotion: reduceMotion)
        }
        .onDisappear { presentation.cancel() }
        .onChange(of: store.searchFocusRequest) { _, _ in searchFocused = true }
        .onAppear {
            // The hosting view is attached before its panel becomes key.
            DispatchQueue.main.async { searchFocused = true }
            withAnimation(reduceMotion ? .linear(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.86)) {
                revealed = true
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    private var currentResults: LauncherDisplayedResults {
        if let result = store.dictionaryResult { return .dictionary(result) }
        if store.showsCalculations { return .calculations(store.calculationHistory) }
        return store.mode == .applications ? .applications(store.generalResults) : .clipboard(store.clipboardResults)
    }

    private var cardHeight: CGFloat {
        LauncherLayout.searchHeight
            + (presentation.isExpanded ? 1 + LauncherLayout.resultsHeight : 0)
            + (store.mode == .clipboard ? 1 + LauncherLayout.footerHeight : 0)
            + (store.errorMessage == nil ? 0 : LauncherLayout.errorHeight)
    }

    private var resultsArea: some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                LazyVStack(spacing: LauncherLayout.rowSpacing) {
                    switch presentation.results {
                    case .dictionary(let result):
                        animatedRow(at: 0) {
                            DictionaryDefinitionView(result: result)
                        }
                        .id("dictionary-definition")
                    case .applications(let results):
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            animatedRow(at: index) {
                                switch result {
                                case .application(let application): resultRow(application)
                                case .command(let command):
                                    actionRow(title: command.title, symbol: command.symbol, selected: store.selectedCommand == command) {
                                        store.select(command)
                                    }
                                case .googleSearch(let search):
                                    actionRow(title: search.title, symbol: "globe", selected: store.selectedGoogleSearch == search) {
                                        store.select(search)
                                    }
                                    .help("\(search.title) in your default browser")
                                }
                            }
                            .id(result.id)
                        }
                    case .clipboard(let entries):
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            animatedRow(at: index) {
                                ClipboardHistoryRow(store: store, entry: entry, index: index)
                            }
                            .id(entry.id.uuidString)
                        }
                    case .calculations(let entries):
                        if entries.isEmpty {
                            animatedRow(at: 0) {
                                VStack(spacing: 5) {
                                    Text("No calculations yet").font(.system(size: 12.5, weight: .medium))
                                    Text("Resolve an expression with = to start.").font(.system(size: 11))
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: LauncherLayout.resultsHeight - 2 * LauncherLayout.listInset)
                            }
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            animatedRow(at: index) {
                                CalculationHistoryRow(
                                    entry: entry,
                                    selected: store.selectedCalculation?.id == entry.id,
                                    visible: presentation.rowsVisible,
                                    delay: presentation.rowDelay(at: index),
                                    onSelect: { store.select(index: index) },
                                    onRecall: { store.recallCalculation(entry) },
                                    onDelete: { store.deleteCalculation(entry) }
                                )
                            }
                            .id(entry.id.uuidString)
                        }
                    }
                }
                .padding(LauncherLayout.listInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .overlay(alignment: .leading) {
                if case .calculations(let entries) = presentation.results, !entries.isEmpty {
                    Rectangle().fill(Color.primary.opacity(0.10))
                        .frame(width: 1)
                        .offset(x: LauncherLayout.listInset + (LauncherLayout.width - 2 * LauncherLayout.listInset) * 2 / 3)
                        .allowsHitTesting(false)
                }
            }
            .onScrollGeometryChange(for: Int.self) { geometry in
                max(0, Int(geometry.contentOffset.y / (LauncherLayout.rowHeight + LauncherLayout.rowSpacing)))
            } action: { _, index in
                presentation.firstVisibleRow = index
            }
            .onChange(of: store.selectedItemID) { _, id in
                if let id { scroll.scrollTo(id) }
            }
            .onChange(of: presentation.results) { _, _ in
                if case .dictionary = presentation.results { scroll.scrollTo("dictionary-definition", anchor: .top) }
                if store.selectedIndex == 0, let id = store.resultIDs.first { scroll.scrollTo(id, anchor: .top) }
            }
        }
    }

    private func animatedRow<Content: View>(at index: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(presentation.rowsVisible ? 1 : 0)
            .offset(y: presentation.rowsVisible || reduceMotion ? 0 : 6)
            .animation(reduceMotion ? nil : .easeOut(duration: LauncherResultsPresentation.rowDuration)
                .delay(presentation.rowDelay(at: index)), value: presentation.rowsVisible)
            .transition(.identity)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("Search", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .focused($searchFocused)
                .onSubmit { store.launchSelection() }
                .accessibilityLabel("Search")
                .accessibilityIdentifier("launcher-search")
                .help(store.errorMessage ?? "Search")
                .frame(minWidth: 60)
            if store.hasPendingAssignment {
                Text("Save ↵")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Press Return to save this variable")
            }
            if (store.mode == .applications && store.isLoading && !store.showsCalculations && !store.hasPendingAssignment && store.dictionaryResult == nil) || store.isLaunching {
                ProgressView().controlSize(.small).scaleEffect(0.75)
            }
            Button {
                store.toggleClipboard()
                searchFocused = true
            } label: {
                Image(systemName: LauncherLayout.clipboardSymbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(store.mode == .clipboard ? 0.90 : 0.50))
                    .frame(width: 24, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(store.mode == .clipboard ? 0.08 : 0)))
            }
            .buttonStyle(.plain)
            .help(store.mode == .clipboard ? "Back to launcher (⌘⇧C)" : "Clipboard history (tap Option or ⌘⇧C)")
            .accessibilityLabel(store.mode == .clipboard ? "Back to launcher" : "Clipboard history")
            .accessibilityIdentifier("clipboard-toggle")
        }
        .padding(.horizontal, 12)
        .frame(height: LauncherLayout.searchHeight)
    }

    private func resultRow(_ application: LauncherApplication) -> some View {
        let selected = store.selectedApplication?.id == application.id
        return Button {
            store.select(application)
            store.launchSelection()
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: store.icon(for: application))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                Text(application.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.82))
                    .lineLimit(1)
                Spacer(minLength: 8)
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
        .onHover { hovered in if hovered { store.select(application) } }
        .accessibilityLabel("Open \(application.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func actionRow(title: String, symbol: String, selected: Bool, onSelect: @escaping () -> Void) -> some View {
        Button { onSelect(); store.launchSelection() } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if selected { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.82))
            .padding(.horizontal, 8).frame(height: LauncherLayout.rowHeight)
            .background(RoundedRectangle(cornerRadius: LauncherLayout.rowCornerRadius, style: .continuous).fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: LauncherLayout.rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain).onHover { if $0 { onSelect() } }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DictionaryDefinitionView: View {
    let result: LauncherDictionaryResult

    var body: some View {
        if case .definition(let term, let text) = result, result.hasDefinition {
            let entry = DictionaryEntry(term: term, text: text)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.word)
                        .font(.system(size: 25, weight: .semibold, design: .serif))
                        .foregroundStyle(.primary)
                    if let pronunciation = entry.pronunciation {
                        Text(pronunciation)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .help(entry.spelling ?? entry.word)
                    }
                }
                ForEach(Array(entry.blocks.enumerated()), id: \.offset) { _, block in
                    switch block.kind {
                    case .partOfSpeech:
                        Text(block.text)
                            .font(.system(size: 11, weight: .medium)).italic()
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.tint.opacity(0.08), in: Capsule())
                    case .section:
                        VStack(alignment: .leading, spacing: 12) {
                            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                            Text(block.text.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1.3)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    case .detail:
                        Text(block.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    case .meaning(let number):
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            if let number {
                                Text(number)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 12, alignment: .leading)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(block.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .lineSpacing(3)
                                if !block.examples.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ForEach(Array(block.examples.enumerated()), id: \.offset) { _, example in
                                            Text(example)
                                                .font(.system(size: 12)).italic()
                                                .foregroundStyle(.secondary)
                                                .lineSpacing(2)
                                        }
                                    }
                                    .padding(.leading, 9)
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(.primary.opacity(0.12)).frame(width: 2)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .tint(Color.accentColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .accessibilityIdentifier("launcher-dictionary-definition")
        }
    }
}

private struct CalculationHistoryRow: View {
    let entry: LauncherCalculation
    let selected: Bool
    let visible: Bool
    let delay: Double
    let onSelect: () -> Void
    let onRecall: () -> Void
    let onDelete: () -> Void
    @State private var displayedResult = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let expressionWidth = (LauncherLayout.width - 2 * LauncherLayout.listInset) * 2 / 3

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onRecall) {
                    Text(entry.expression)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .help("\(entry.expression) — Return to reuse")
                .accessibilityLabel("Reuse \(entry.expression)")
                .accessibilityAddTraits(selected ? .isSelected : [])

                if selected {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: LauncherLayout.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .help("Delete calculation (⌥⌫)")
                    .accessibilityLabel("Delete calculation \(entry.expression)")
                    .accessibilityIdentifier("launcher-delete-calculation")
                }
            }
            .buttonStyle(.plain)
            .frame(width: expressionWidth - 4, height: LauncherLayout.rowHeight)
            .background(RoundedRectangle(cornerRadius: LauncherLayout.rowCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .onHover { if $0 { onSelect() } }
            .padding(.trailing, 4)

            Text(displayedResult)
                .font(.system(size: 12.5, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
                .contentTransition(reduceMotion ? .identity : .numericText(value: entry.numericValue ?? 0))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(entry.result)
                .accessibilityLabel("Result: \(entry.result)")
                .accessibilityIdentifier("launcher-calculation-result")
        }
        .frame(height: LauncherLayout.rowHeight)
        .onChange(of: visible, initial: true) { _, value in
            if value { revealResult(delay: delay) }
        }
        .onChange(of: entry.result) { _, _ in
            if visible { revealResult(delay: 0) }
        }
    }

    private func revealResult(delay: Double) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24).delay(delay)) {
            displayedResult = entry.result
        }
    }
}
