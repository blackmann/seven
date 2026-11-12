import AppKit
import Combine
import SwiftUI

enum LauncherLayout {
    static let width: CGFloat = 300
    static let searchHeight: CGFloat = 40
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 1
    static let listInset: CGFloat = 4
    static let inset: CGFloat = 12
    static let visibleRowCount = 6
    static let resultsHeight: CGFloat = 2 * listInset + CGFloat(visibleRowCount) * rowHeight + CGFloat(visibleRowCount - 1) * rowSpacing
    static let footerHeight: CGFloat = 36
    static let errorHeight: CGFloat = 64
    static let expandedHeight: CGFloat = searchHeight + 1 + resultsHeight
    static let maximumHeight: CGFloat = expandedHeight + 1 + footerHeight + errorHeight
    static let cornerRadius: CGFloat = 20
    static let rowCornerRadius: CGFloat = cornerRadius - listInset
    static let clipboardSymbol = "document.on.clipboard.fill"

    static func belowNotchTopLeft(screenFrame: NSRect, visibleFrame: NSRect, topSafeAreaInset: CGFloat) -> NSPoint {
        let unobscuredTop = min(visibleFrame.maxY, screenFrame.maxY - topSafeAreaInset)
        return NSPoint(x: screenFrame.midX - width / 2, y: unobscuredTop - 8)
    }
}

enum LauncherContent { case applications, clipboard }

struct ClipboardActivationGesture {
    private var optionWasDown = false
    private var armed = false

    mutating func reset(optionIsDown: Bool = false) {
        optionWasDown = optionIsDown
        armed = false
    }

    mutating func cancel() { armed = false }

    mutating func flagsChanged(_ flags: NSEvent.ModifierFlags) -> Bool {
        let optionIsDown = flags.contains(.option)
        let otherModifiers = flags.intersection([.command, .shift, .control])
        if !otherModifiers.isEmpty { armed = false }
        if optionIsDown && !optionWasDown { armed = otherModifiers.isEmpty }
        let activate = !optionIsDown && optionWasDown && armed && otherModifiers.isEmpty
        if !optionIsDown { armed = false }
        optionWasDown = optionIsDown
        return activate
    }
}

@MainActor
final class LauncherStore: ObservableObject {
    static var defaultCalculationHistoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("seven", isDirectory: true).appendingPathComponent("calculator-history.json")
    }
    private static let calculationHistoryLimit = 100

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            resolveDictionaryQuery()
            if mode == .applications {
                if !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("=") { activeCalculationID = nil }
                resolveCalculationQuery()
            }
            updateResults()
        }
    }
    @Published private(set) var mode: LauncherContent = .applications
    @Published private(set) var results: [LauncherApplication] = []
    @Published private(set) var generalResults: [LauncherSearchResult] = []
    @Published private(set) var clipboardResults: [ClipboardEntry] = []
    @Published private(set) var calculationResult: String?
    @Published private(set) var calculationHistory: [LauncherCalculation] = []
    @Published private(set) var showsCalculations = false
    @Published private(set) var hasPendingAssignment = false
    @Published private(set) var dictionaryResult: LauncherDictionaryResult?
    @Published private(set) var selectedIndex = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasExpandedResults = false
    @Published var isLaunching = false
    @Published var errorMessage: String?
    @Published private(set) var needsAccessibilityAccess = false
    @Published private(set) var searchFocusRequest = 0
    let clipboard: ClipboardHistory
    var onLaunch: ((LauncherApplication) -> Void)?
    var onCommand: ((LauncherCommand) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onRestore: ((ClipboardEntry, Bool, Bool) -> Void)?
    var onDismiss: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var onShowActions: (() -> Void)?
    private var applications: [LauncherApplication] = []
    private var icons: [String: NSImage] = [:]
    private let applicationSearchRoots: [URL]
    private let automaticallyRefreshApplications: Bool
    private var catalogMonitor: ApplicationCatalogMonitor?
    private var scheduledApplicationRefresh: DispatchWorkItem?
    private var loadTask: Task<Void, Never>?
    private var historySubscription: AnyCancellable?
    private let calculator = LauncherCalculator()
    private let calculationHistoryURL: URL?
    private var calculationStorageError: String?
    private var calculationHistoryLoaded = true
    private var activeCalculationID: UUID?
    private var calculationSession = false
    private var dictionaryTask: Task<Void, Never>?
    private let dictionaryLookup: @Sendable (String) async -> String?

    init(applications: [LauncherApplication]? = nil, clipboard: ClipboardHistory? = nil, applicationSearchRoots: [URL]? = nil,
         calculationHistoryURL: URL? = nil,
         dictionaryLookup: @escaping @Sendable (String) async -> String? = { await SystemDictionary.shared.definition(for: $0) }) {
        self.dictionaryLookup = dictionaryLookup
        self.applicationSearchRoots = applicationSearchRoots ?? ApplicationCatalog.searchRoots
        self.automaticallyRefreshApplications = applications == nil
        self.clipboard = clipboard ?? ClipboardHistory(storageURL: nil, autoStart: false, defaults: nil)
        self.calculationHistoryURL = calculationHistoryURL
        if let calculationHistoryURL, FileManager.default.fileExists(atPath: calculationHistoryURL.path) {
            do {
                let data = try Data(contentsOf: calculationHistoryURL)
                calculationHistory = Array(try JSONDecoder().decode([LauncherCalculation].self, from: data)
                    .prefix(Self.calculationHistoryLimit))
            } catch {
                calculationHistoryLoaded = false
                calculationStorageError = "Couldn’t load calculator history. New changes won’t be saved; the existing file is unchanged."
            }
        }
        if let applications { self.applications = applications }
        else {
            catalogMonitor = ApplicationCatalogMonitor(roots: self.applicationSearchRoots) { [weak self] in
                self?.scheduleApplicationRefresh()
            }
            reloadApplications()
        }
        historySubscription = self.clipboard.$entries.sink { [weak self] entries in
            guard let self, self.mode == .clipboard else { return }
            self.updateResults(preservingSelection: true, history: entries)
        }
    }

    var queryIsEmpty: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var showsList: Bool { resultCount > 0 }
    var resultCount: Int { showsCalculations ? calculationHistory.count : (mode == .applications ? generalResults.count : clipboardResults.count) }
    var resultIDs: [String] {
        if showsCalculations { return calculationHistory.map { $0.id.uuidString } }
        return mode == .applications ? generalResults.map(\.id) : clipboardResults.map { $0.id.uuidString }
    }
    var selectedItemID: String? { resultIDs.indices.contains(selectedIndex) ? resultIDs[selectedIndex] : nil }
    var cardHeight: CGFloat {
        (hasExpandedResults ? LauncherLayout.expandedHeight : LauncherLayout.searchHeight)
            + (mode == .clipboard ? 1 + LauncherLayout.footerHeight : 0)
            + (errorMessage == nil ? 0 : LauncherLayout.errorHeight)
    }
    var selectedApplication: LauncherApplication? {
        if mode == .applications, generalResults.indices.contains(selectedIndex), case .application(let app) = generalResults[selectedIndex] { return app }
        return nil
    }
    var selectedCommand: LauncherCommand? {
        if mode == .applications, generalResults.indices.contains(selectedIndex), case .command(let command) = generalResults[selectedIndex] { return command }
        return nil
    }
    var selectedGoogleSearch: LauncherGoogleSearch? {
        if mode == .applications, generalResults.indices.contains(selectedIndex),
           case .googleSearch(let search) = generalResults[selectedIndex] { return search }
        return nil
    }
    var selectedClipboardEntry: ClipboardEntry? {
        mode == .clipboard && clipboardResults.indices.contains(selectedIndex) ? clipboardResults[selectedIndex] : nil
    }
    var selectedCalculation: LauncherCalculation? {
        showsCalculations && calculationHistory.indices.contains(selectedIndex) ? calculationHistory[selectedIndex] : nil
    }

    func refreshApplicationsForPresentation() {
        guard automaticallyRefreshApplications else { return }
        scheduledApplicationRefresh?.cancel()
        scheduledApplicationRefresh = nil
        catalogMonitor?.refreshWatchedDirectories()
        reloadApplications()
    }

    private func scheduleApplicationRefresh() {
        scheduledApplicationRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in self?.reloadApplications() }
        scheduledApplicationRefresh = refresh
        // Coalesce the many file changes produced while an installer copies a bundle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: refresh)
    }

    func reloadApplications() {
        loadTask?.cancel()
        if applications.isEmpty { isLoading = true }
        let roots = applicationSearchRoots
        loadTask = Task { [weak self] in
            let applications = await Task.detached(priority: .userInitiated) { ApplicationCatalog.discover(in: roots) }.value
            guard !Task.isCancelled, let self else { return }
            self.loadTask = nil
            self.isLoading = false
            guard self.applications != applications else { return }
            self.applications = applications
            self.icons.removeAll()
            if self.mode == .applications { self.updateResults(preservingSelection: true) }
        }
    }

    deinit {
        scheduledApplicationRefresh?.cancel()
        loadTask?.cancel()
        dictionaryTask?.cancel()
    }

    func reset() {
        mode = .applications
        calculationSession = false
        query = ""
        results = []
        generalResults = []
        clipboardResults = []
        calculationResult = nil
        activeCalculationID = nil
        hasPendingAssignment = false
        selectedIndex = 0
        errorMessage = nil
        needsAccessibilityAccess = false
        isLaunching = false
        updateResults()
        onLayoutChange?()
    }

    func focusSearch() { searchFocusRequest += 1 }

    func toggleClipboard() {
        mode = mode == .applications ? .clipboard : .applications
        calculationSession = false
        activeCalculationID = nil
        calculationResult = nil
        hasPendingAssignment = false
        query = ""
        updateResults()
        onLayoutChange?()
    }

    private func updateResults(preservingSelection: Bool = false, history: [ClipboardEntry]? = nil) {
        let hadError = errorMessage != nil
        let oldID = selectedItemID
        let oldIndex = selectedIndex
        errorMessage = nil
        needsAccessibilityAccess = false
        if dictionaryResult != nil {
            calculationResult = nil
            hasPendingAssignment = false
            calculationSession = false
            showsCalculations = false
            results = []
            generalResults = []
            clipboardResults = []
        } else if mode == .applications {
            let historyRequested = query.trimmingCharacters(in: .whitespacesAndNewlines) == "="
            let variableDraft = calculationSession && calculator.referencesSavedVariable(in: query)
            generalResults = calculationResult == nil && !hasPendingAssignment && !variableDraft && !historyRequested
                ? LauncherSearch.results(for: query, applications: applications) : []
            results = generalResults.compactMap { if case .application(let app) = $0 { return app }; return nil }
            clipboardResults = []
            if !generalResults.isEmpty { calculationSession = false }
            showsCalculations = calculationSession && generalResults.isEmpty
        } else {
            calculationResult = nil
            showsCalculations = false
            results = []
            generalResults = []
            clipboardResults = clipboard.results(for: query, in: history)
        }
        selectedIndex = preservingSelection ? (resultIDs.firstIndex(of: oldID ?? "") ?? min(oldIndex, max(0, resultCount - 1))) : 0
        if showsCalculations { errorMessage = calculationStorageError }
        updateExpansion()
        if hadError || errorMessage != nil { onLayoutChange?() }
    }

    private func updateExpansion() {
        let expanded = dictionaryResult?.hasDefinition == true || showsCalculations || resultCount > 0
        guard hasExpandedResults != expanded else { return }
        hasExpandedResults = expanded
        onLayoutChange?()
    }

    func moveSelection(by offset: Int) {
        guard resultCount > 0 else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), resultCount - 1)
    }

    func select(_ application: LauncherApplication) {
        if let index = generalResults.firstIndex(where: { $0.id == application.id }) { selectedIndex = index }
    }
    func select(_ command: LauncherCommand) { if let index = generalResults.firstIndex(where: { $0.id == command.id }) { selectedIndex = index } }
    func select(_ search: LauncherGoogleSearch) { if let index = generalResults.firstIndex(where: { $0.id == search.id }) { selectedIndex = index } }

    func select(_ entry: ClipboardEntry) {
        if let index = clipboardResults.firstIndex(where: { $0.id == entry.id }) { selectedIndex = index }
    }

    func select(index: Int) { if (0..<resultCount).contains(index) { selectedIndex = index } }

    func launchSelection(paste: Bool = false, plainText: Bool = false, respectAutomaticPaste: Bool = true) {
        guard !isLaunching else { return }
        if mode == .applications, hasPendingAssignment, let evaluation = calculator.evaluate(query, allowingAssignment: true) {
            saveCalculation(evaluation)
            hasPendingAssignment = false
            updateResults()
        }
        else if let calculation = selectedCalculation { recallCalculation(calculation) }
        else if let entry = selectedClipboardEntry { onRestore?(entry, paste || (respectAutomaticPaste && clipboard.pasteAutomatically), plainText) }
        else if let application = selectedApplication { onLaunch?(application) }
        else if let command = selectedCommand { onCommand?(command) }
        else if let search = selectedGoogleSearch { onOpenURL?(search.url) }
    }

    private func resolveCalculationQuery() {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        calculationResult = nil
        hasPendingAssignment = false
        guard dictionaryResult == nil else { return }
        if LauncherGoogleSearch.term(in: query) != nil {
            calculationSession = false
            activeCalculationID = nil
            return
        }
        if input.isEmpty { calculationSession = false }
        if input == "=" {
            calculationSession = true
            activeCalculationID = nil
            return
        }
        if input.hasSuffix("=") {
            if let evaluation = calculator.evaluate(String(input.dropLast()), allowingAssignment: true) {
                saveCalculation(evaluation)
            } else {
                activeCalculationID = nil
            }
        } else {
            activeCalculationID = nil
            hasPendingAssignment = calculator.assignmentPreview(for: input) != nil
        }
    }

    private func resolveDictionaryQuery() {
        dictionaryTask?.cancel()
        dictionaryTask = nil
        guard mode == .applications, let term = LauncherDictionary.term(in: query) else {
            dictionaryResult = nil
            return
        }
        guard !term.isEmpty else {
            dictionaryResult = .prompt
            return
        }
        dictionaryResult = .loading(term)
        let lookup = dictionaryLookup
        dictionaryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            let definition = await lookup(term)
            guard !Task.isCancelled, let self, self.mode == .applications,
                  LauncherDictionary.term(in: self.query) == term else { return }
            self.dictionaryResult = definition.map { .definition(term: term, text: $0) } ?? .notFound(term)
            self.dictionaryTask = nil
            self.updateExpansion()
        }
    }

    private func saveCalculation(_ evaluation: LauncherCalculator.Evaluation) {
        calculator.commit(evaluation)
        calculationResult = evaluation.result
        calculationSession = true
        if let id = activeCalculationID, let index = calculationHistory.firstIndex(where: { $0.id == id }) {
            calculationHistory[index] = LauncherCalculation(id: id, expression: evaluation.expression, result: evaluation.result, numericValue: evaluation.numericValue)
        } else {
            let entry = LauncherCalculation(expression: evaluation.expression, result: evaluation.result, numericValue: evaluation.numericValue)
            calculationHistory.insert(entry, at: 0)
            activeCalculationID = entry.id
            if calculationHistory.count > Self.calculationHistoryLimit {
                calculationHistory.removeLast(calculationHistory.count - Self.calculationHistoryLimit)
            }
        }
        persistCalculationHistory()
    }

    private func persistCalculationHistory() {
        guard let calculationHistoryURL, calculationHistoryLoaded else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: calculationHistoryURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(calculationHistory)
            // The bounded history is saved immediately, including deletions,
            // so quitting never depends on a delayed write or shutdown callback.
            try data.write(to: calculationHistoryURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: calculationHistoryURL.path)
            calculationStorageError = nil
        } catch {
            calculationStorageError = "Calculator history couldn’t be saved. Recent changes may be lost when Seven quits."
        }
    }

    func recallCalculation(_ calculation: LauncherCalculation) {
        calculationSession = true
        query = calculation.expression
        if let index = calculationHistory.firstIndex(where: { $0.id == calculation.id }) { selectedIndex = index }
        focusSearch()
    }

    func deleteCalculation(_ calculation: LauncherCalculation) {
        guard let index = calculationHistory.firstIndex(where: { $0.id == calculation.id }) else { return }
        let selectedID = selectedCalculation?.id
        calculationHistory.remove(at: index)
        if activeCalculationID == calculation.id { activeCalculationID = nil }
        persistCalculationHistory()
        if showsCalculations {
            selectedIndex = calculationHistory.firstIndex(where: { $0.id == selectedID })
                ?? min(selectedIndex, max(0, calculationHistory.count - 1))
        }
        // Refresh the list without evaluating the input and recreating the deleted entry.
        updateResults(preservingSelection: true)
        focusSearch()
    }

    func deleteSelection() {
        if let calculation = selectedCalculation { deleteCalculation(calculation) }
        else if let entry = selectedClipboardEntry { clipboard.delete(entry) }
    }

    func reportClipboardError(_ error: ClipboardPasteFailure) {
        errorMessage = error.localizedDescription
        needsAccessibilityAccess = error == .accessibilityRequired
        onLayoutChange?()
    }

    func reportLaunchError(_ message: String) {
        dictionaryTask?.cancel()
        dictionaryTask = nil
        dictionaryResult = nil
        needsAccessibilityAccess = false
        calculationResult = nil
        showsCalculations = false
        hasPendingAssignment = false
        results = []
        generalResults = []
        clipboardResults = []
        selectedIndex = 0
        errorMessage = message
        updateExpansion()
        onLayoutChange?()
    }

    func icon(for application: LauncherApplication) -> NSImage {
        if let icon = icons[application.id] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: application.url.path)
        icons[application.id] = icon
        return icon
    }
}
