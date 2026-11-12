import XCTest
@testable import seven

private actor DictionaryLookupProbe {
    private(set) var terms: [String] = []
    private var pending: [String: CheckedContinuation<String?, Never>] = [:]

    func lookup(_ term: String) async -> String? {
        terms.append(term)
        return await withCheckedContinuation { pending[term] = $0 }
    }

    func complete(_ term: String, with definition: String?) {
        pending.removeValue(forKey: term)?.resume(returning: definition)
    }
}

final class DictionaryTests: XCTestCase {
    func testEntrySeparatesPronunciationSensesExamplesAndOrigin() {
        let entry = DictionaryEntry(term: "rampant", text: "rampant ramp·ant | ˈramp(ə)nt | adjective 1 flourishing unchecked: rampant inflation. • lush in growth: rampant weeds. 2 Heraldry standing on one hind foot. ORIGIN Middle English: from Old French.")
        XCTAssertEqual(entry.word, "rampant")
        XCTAssertEqual(entry.pronunciation, "ˈramp(ə)nt")
        XCTAssertEqual(entry.spelling, "ramp·ant")
        XCTAssertEqual(entry.blocks.map(\.text), ["adjective", "flourishing unchecked", "lush in growth", "Heraldry standing on one hind foot.", "Origin", "Middle English: from Old French."])
        XCTAssertEqual(entry.blocks[1].examples, ["rampant inflation."])
        XCTAssertEqual(entry.blocks[2].examples, ["rampant weeds."])
        let numbers = entry.blocks.compactMap { block -> String? in
            if case .meaning(let number) = block.kind { return number }
            return nil
        }
        XCTAssertEqual(numbers, ["1", "•", "2"])
    }

    func testEntryPreservesQuantitiesInflectionsAndUnfamiliarFormats() {
        let entry = DictionaryEntry(term: "run", text: "run | rən | verb (runs) (running) 1 move quickly: Dave has run 42 marathons | run 2 miles. 2 flow. ORIGIN 1754: a date.")
        XCTAssertEqual(entry.blocks[2].examples, ["Dave has run 42 marathons", "run 2 miles."])
        XCTAssertEqual(entry.blocks.last?.text, "1754: a date.")
        XCTAssertEqual(entry.blocks[1].text, "(runs) (running)")
        let original = "単語：意味。\n別の意味。"
        let fallback = DictionaryEntry(term: "単語", text: original)
        XCTAssertNil(fallback.pronunciation)
        XCTAssertEqual(fallback.blocks.map(\.text), [original])
    }

    @MainActor func testSuccessfulLookupExpandsAndNextPendingQueryCollapses() async throws {
        let probe = DictionaryLookupProbe()
        let store = LauncherStore(applications: [], dictionaryLookup: { await probe.lookup($0) })
        var layoutChanges = 0
        store.onLayoutChange = { layoutChanges += 1 }
        store.query = "define rampant"
        XCTAssertFalse(store.hasExpandedResults)
        try await waitUntil { await probe.terms == ["rampant"] }
        await probe.complete("rampant", with: "flourishing unchecked")
        try await waitUntil { store.hasExpandedResults }
        XCTAssertEqual(store.cardHeight, LauncherLayout.expandedHeight)
        XCTAssertEqual(layoutChanges, 1)
        store.query = "define unknown"
        XCTAssertFalse(store.hasExpandedResults)
        XCTAssertEqual(layoutChanges, 2)
        try await waitUntil { await probe.terms == ["rampant", "unknown"] }
        await probe.complete("unknown", with: nil)
        try await waitUntil { store.dictionaryResult == .notFound("unknown") }
        XCTAssertFalse(store.hasExpandedResults)
        XCTAssertEqual(layoutChanges, 2)
    }

    func testCommandRequiresAWholeWordAndPreservesUnicodeAndPhrases() {
        XCTAssertEqual(LauncherDictionary.term(in: "define"), "")
        XCTAssertEqual(LauncherDictionary.term(in: "  DEFINE \t café  \n"), "café")
        XCTAssertEqual(LauncherDictionary.term(in: "define déjà vu"), "déjà vu")
        XCTAssertEqual(LauncherDictionary.term(in: "define 👩🏽‍💻"), "👩🏽‍💻")
        for query in ["", "def", "defined", "defineSomething", "redefine rampant"] {
            XCTAssertNil(LauncherDictionary.term(in: query))
        }
    }

    @MainActor func testTypingShowsDefinitionWithoutReturnAndDebouncesPartialWords() async throws {
        let probe = DictionaryLookupProbe()
        let store = LauncherStore(applications: [], dictionaryLookup: { await probe.lookup($0) })
        store.query = "define"
        XCTAssertEqual(store.dictionaryResult, .prompt)
        XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight)
        store.query = "define ram"
        store.query = "define rampant"
        XCTAssertEqual(store.dictionaryResult, .loading("rampant"))
        XCTAssertFalse(store.hasExpandedResults)
        try await waitUntil { await probe.terms == ["rampant"] }
        await probe.complete("rampant", with: "rampant — flourishing or spreading unchecked")
        try await waitUntil { store.dictionaryResult == .definition(term: "rampant", text: "rampant — flourishing or spreading unchecked") }
        XCTAssertNil(store.selectedApplication)
        XCTAssertNil(store.selectedCommand)
        store.launchSelection()
        XCTAssertEqual(store.query, "define rampant")
        XCTAssertTrue(store.hasExpandedResults)
    }

    @MainActor func testStaleLookupCannotReplaceANewerDefinition() async throws {
        let probe = DictionaryLookupProbe()
        let store = LauncherStore(applications: [], dictionaryLookup: { await probe.lookup($0) })
        store.query = "define old"
        try await waitUntil { await probe.terms == ["old"] }
        store.query = "define new"
        try await waitUntil { await probe.terms == ["old", "new"] }
        await probe.complete("new", with: "new definition")
        try await waitUntil { store.dictionaryResult == .definition(term: "new", text: "new definition") }
        await probe.complete("old", with: "old definition")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.dictionaryResult, .definition(term: "new", text: "new definition"))
    }

    @MainActor func testMissingWordAndReturningToOtherLauncherModes() async throws {
        let app = LauncherApplication(url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari")
        let store = LauncherStore(applications: [app], dictionaryLookup: { _ in nil })
        store.query = "2+2="
        let history = store.calculationHistory
        store.query = "define missingword"
        XCTAssertFalse(store.showsCalculations)
        try await waitUntil { store.dictionaryResult == .notFound("missingword") }
        XCTAssertFalse(store.hasExpandedResults)
        store.query = "saf"
        XCTAssertNil(store.dictionaryResult)
        XCTAssertEqual(store.selectedApplication, app)
        store.query = "define rampant"
        store.toggleClipboard()
        store.query = "define rampant"
        XCTAssertNil(store.dictionaryResult, "Clipboard queries remain literal searches")
        store.toggleClipboard()
        store.query = "define rampant"
        store.reset()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.dictionaryResult)
        XCTAssertFalse(store.hasExpandedResults)
        XCTAssertEqual(store.calculationHistory, history)
        store.query = "3+3="
        XCTAssertTrue(store.showsCalculations)
        XCTAssertEqual(store.calculationResult, "6")
    }

    @MainActor func testInFlightLookupCannotReopenClearedOrSwitchedLauncher() async throws {
        for destination in ["clear", "reset", "clipboard"] {
            let probe = DictionaryLookupProbe()
            let store = LauncherStore(applications: [], dictionaryLookup: { await probe.lookup($0) })
            store.query = "define rampant"
            try await waitUntil { await probe.terms == ["rampant"] }
            switch destination {
            case "reset": store.reset()
            case "clipboard": store.toggleClipboard()
            default: store.query = ""
            }
            await probe.complete("rampant", with: "late definition")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(store.dictionaryResult, destination)
            XCTAssertFalse(store.hasExpandedResults, destination)
        }
    }

    @MainActor func testDictionaryPresentationOnlyExpandsForDefinitions() {
        let presentation = LauncherResultsPresentation()
        for state: LauncherDictionaryResult in [.prompt, .loading("rampant"), .definition(term: "rampant", text: "definition"), .notFound("missing")] {
            presentation.update(.dictionary(state), reduceMotion: true)
            XCTAssertEqual(presentation.isExpanded, state.hasDefinition)
            XCTAssertEqual(presentation.rowsVisible, state.hasDefinition)
        }
        presentation.update(.applications([]), reduceMotion: true)
        XCTAssertFalse(presentation.isExpanded)
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for dictionary lookup")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
