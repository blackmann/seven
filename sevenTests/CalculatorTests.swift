import AppKit
import Carbon
import XCTest
@testable import seven

final class CalculatorTests: XCTestCase {
    private func withHistoryFile(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seven-calculator-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder.appendingPathComponent("calculator-history.json"))
    }

    func testSoulverArithmeticAndNaturalLanguage() throws {
        let calculator = LauncherCalculator()
        for (expression, expected) in [
            "2 + 3 * 4": "14", "(2 + 3) * 4": "20", "20/4/2": "2.5",
            "0.1 + 0.2": "0.3", "0.1+0.2-0.3": "0", "2^-3": "0.125",
            "sqrt(81)": "9", "6 × 4 ÷ 2 − 1": "11", "20% of 150": "30",
            "2 meters in cm": "200 cm"
        ] {
            XCTAssertEqual(calculator.evaluate(expression)?.result, expected, expression)
        }
        XCTAssertNotNil(calculator.evaluate("3:45pm + 4 hr 10 min"))
        XCTAssertNotNil(calculator.evaluate("January 30 2020 + 3 months"))
    }

    func testInvalidInputAndIncompleteAssignmentsDoNotResolve() {
        let calculator = LauncherCalculator()
        for expression in ["", "=", "2+", "(2+3", "2+3)", "1/0", "0/0", "unknownVariable", String(repeating: "1", count: 513)] {
            XCTAssertNil(calculator.evaluate(expression), expression)
        }
        XCTAssertNil(calculator.assignmentPreview(for: "rate ="))
        XCTAssertNil(calculator.assignmentPreview(for: "rate = 2 +"))
        XCTAssertNil(calculator.evaluate("rate = 25"), "Assignments must be explicitly allowed")
    }

    func testVariablesAreCommittedExplicitlyAndKeepTypedValues() throws {
        let calculator = LauncherCalculator()
        let assignment = try XCTUnwrap(calculator.assignmentPreview(for: "rate = 25"))
        XCTAssertEqual(assignment.result, "25")
        XCTAssertNil(calculator.evaluate("rate"), "Previewing must not save a partial assignment")
        calculator.commit(assignment)
        XCTAssertEqual(calculator.evaluate("rate * 4")?.result, "100")
        _ = calculator.assignmentPreview(for: "rate = 99")
        XCTAssertEqual(calculator.evaluate("rate")?.result, "25")
        calculator.commit(try XCTUnwrap(calculator.assignmentPreview(for: "rate = rate + 5")))
        XCTAssertEqual(calculator.evaluate("rate")?.result, "30")

        calculator.commit(try XCTUnwrap(calculator.assignmentPreview(for: "distance = 2 m")))
        XCTAssertEqual(calculator.evaluate("distance in cm")?.result, "200 cm")
        calculator.commit(try XCTUnwrap(calculator.assignmentPreview(for: "third = 1/3")))
        XCTAssertEqual(calculator.evaluate("third * 3")?.result, "1")
    }

    @MainActor func testEqualsExpandsHistoryAndEditingResolvedInputDoesNotFloodIt() throws {
        let store = LauncherStore(applications: [])
        store.query = "2+2"
        XCTAssertTrue(store.calculationHistory.isEmpty)
        store.query = "2+2="
        XCTAssertEqual(store.calculationResult, "4")
        XCTAssertTrue(store.showsCalculations)
        XCTAssertEqual(store.cardHeight, LauncherLayout.expandedHeight)
        XCTAssertEqual(store.calculationHistory.first?.expression, "2+2")
        let id = try XCTUnwrap(store.calculationHistory.first?.id)
        store.query = "2+3="
        XCTAssertEqual(store.calculationHistory.count, 1)
        XCTAssertEqual(store.calculationHistory.first?.id, id)
        XCTAssertEqual(store.calculationHistory.first?.result, "5")
        store.query = "10 * 3"
        store.query += "="
        XCTAssertEqual(store.calculationHistory.map(\.result), ["30", "5"])
        store.moveSelection(by: 1)
        XCTAssertEqual(store.selectedCalculation?.id, id)
        store.launchSelection()
        XCTAssertEqual(store.query, "2+3", "Return recalls the selected expression for editing")
        XCTAssertEqual(store.calculationHistory.count, 2)
    }

    @MainActor func testAssignmentReturnLookupAndSessionLifetime() {
        let store = LauncherStore(applications: [])
        store.query = "rate = 2"
        XCTAssertTrue(store.hasPendingAssignment)
        XCTAssertTrue(store.calculationHistory.isEmpty)
        store.query = "rate = 25"
        store.launchSelection()
        XCTAssertEqual(store.calculationHistory.count, 1)
        XCTAssertEqual(store.calculationResult, "25")
        store.query = "rate ="
        XCTAssertEqual(store.calculationResult, "25")
        store.query = "rate * 4 ="
        XCTAssertEqual(store.calculationResult, "100")
        store.reset()
        XCTAssertFalse(store.showsCalculations)
        XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight)
        store.query = "rate ="
        XCTAssertEqual(store.calculationResult, "25", "Reopening must retain session variables")
        XCTAssertTrue(store.showsCalculations)
        store.query = "rate = 1/0"
        XCTAssertFalse(store.hasPendingAssignment)
        store.query = "rate ="
        XCTAssertEqual(store.calculationResult, "25", "Invalid assignments must preserve the previous value")
    }

    @MainActor func testNormalSearchAndClipboardRemainIndependentOfCalculations() {
        let app = LauncherApplication(url: URL(fileURLWithPath: "/Applications/Calculator.app"), name: "Calculator")
        let store = LauncherStore(applications: [app])
        store.query = "2+2="
        store.query = "calc"
        XCTAssertEqual(store.selectedApplication, app)
        XCTAssertFalse(store.showsCalculations)
        store.query = ""
        XCTAssertFalse(store.showsCalculations)
        let history = store.calculationHistory
        store.toggleClipboard()
        store.query = "2+2="
        XCTAssertNil(store.calculationResult)
        XCTAssertFalse(store.showsCalculations)
        store.query = "rate = 25"
        XCTAssertFalse(store.hasPendingAssignment)
        XCTAssertEqual(store.calculationHistory, history)
        store.toggleClipboard()
        XCTAssertFalse(store.showsCalculations)
        XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight)
    }

    @MainActor func testSavedHistoryDoesNotAutomaticallyOpenTheCalculator() {
        let store = LauncherStore(applications: [])
        store.query = "2 + 2 ="
        XCTAssertTrue(store.showsCalculations)
        let history = store.calculationHistory

        store.reset()
        XCTAssertEqual(store.calculationHistory, history)
        XCTAssertFalse(store.showsCalculations)
        XCTAssertEqual(store.resultCount, 0)
        XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight)
        store.query = "2 + 3"
        XCTAssertFalse(store.showsCalculations, "A draft must wait for equals")
        store.query += "="
        XCTAssertTrue(store.showsCalculations)
        XCTAssertEqual(store.calculationHistory.count, 2)

        store.query = "   "
        XCTAssertFalse(store.showsCalculations, "Clearing search should collapse history")
        XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight)
        store.query = "rate = 25"
        XCTAssertFalse(store.showsCalculations, "An assignment draft must wait for Return")
        store.launchSelection()
        XCTAssertTrue(store.showsCalculations)
        XCTAssertEqual(store.calculationHistory.count, 3)
    }

    @MainActor func testBareEqualsOpensHistoryWithoutAddingOrChangingEntries() {
        let store = LauncherStore(applications: [])
        store.query = "2+2="
        let history = store.calculationHistory
        store.reset()
        store.query = " = "
        XCTAssertTrue(store.showsCalculations)
        XCTAssertEqual(store.cardHeight, LauncherLayout.expandedHeight)
        XCTAssertEqual(store.calculationHistory, history)
        XCTAssertNil(store.calculationResult)
        XCTAssertEqual(store.selectedCalculation, history.first)
        store.query = "2+3="
        XCTAssertEqual(store.calculationHistory.count, 2, "Opening history must not keep an active entry to overwrite")
        store.query = ""
        XCTAssertFalse(store.showsCalculations)
        store.toggleClipboard()
        store.query = "="
        XCTAssertFalse(store.showsCalculations, "Clipboard searches equals literally")
    }

    @MainActor func testBareEqualsShowsAnEmptyHistoryAndClearingItCollapses() {
        let store = LauncherStore(applications: [])
        store.query = "="
        XCTAssertTrue(store.showsCalculations)
        XCTAssertTrue(store.hasExpandedResults)
        XCTAssertEqual(store.cardHeight, LauncherLayout.expandedHeight)
        XCTAssertTrue(store.calculationHistory.isEmpty)
        XCTAssertNil(store.selectedCalculation)
        store.launchSelection()
        XCTAssertTrue(store.calculationHistory.isEmpty)

        let presentation = LauncherResultsPresentation()
        presentation.update(.calculations([]), reduceMotion: true)
        XCTAssertTrue(presentation.isExpanded)
        XCTAssertTrue(presentation.rowsVisible)
        store.query = ""
        presentation.update(.applications(store.generalResults), reduceMotion: true)
        XCTAssertFalse(store.hasExpandedResults)
        XCTAssertFalse(presentation.isExpanded)
    }

    @MainActor func testRecallingVariableKeepsHistoryInsteadOfFuzzyApplicationMatches() throws {
        let app = LauncherApplication(url: URL(fileURLWithPath: "/Applications/Rate.app"), name: "Rate")
        let store = LauncherStore(applications: [app])
        store.query = "rate = 25"
        store.launchSelection()
        store.query = "rate ="
        let lookup = try XCTUnwrap(store.selectedCalculation)
        store.recallCalculation(lookup)
        XCTAssertEqual(store.query, "rate")
        XCTAssertTrue(store.showsCalculations)
        XCTAssertNil(store.selectedApplication)
        store.query = "rate *"
        XCTAssertTrue(store.showsCalculations)
        store.query = "rate * 4 ="
        XCTAssertEqual(store.calculationResult, "100")
    }

    @MainActor func testHistoryIsBoundedAndOldAnswersDoNotChangeWithVariables() {
        let store = LauncherStore(applications: [])
        store.query = "rate = 25"
        store.launchSelection()
        store.query = "rate * 2 ="
        store.query = "rate = 30"
        store.launchSelection()
        XCTAssertEqual(store.calculationHistory.map(\.result), ["30", "50", "25"])
        for index in 0..<110 {
            store.query = "\(index) + 1"
            store.query += "="
        }
        XCTAssertEqual(store.calculationHistory.count, 100)
        XCTAssertEqual(store.calculationHistory.first?.result, "110")
        XCTAssertEqual(store.resultIDs.count, 100)
    }

    @MainActor func testDeletingHistoryPreservesSelectionAndHandlesTheLastEntry() throws {
        let store = LauncherStore(applications: [])
        for expression in ["2+2=", "2+2=", "3+3="] {
            store.query = ""
            store.query = expression
        }
        let entries = store.calculationHistory
        store.select(index: 2)
        store.deleteCalculation(entries[0])
        XCTAssertEqual(store.calculationHistory, Array(entries.dropFirst()))
        XCTAssertEqual(store.selectedCalculation, entries[2], "Deleting another row should preserve the selected entry")
        XCTAssertEqual(store.selectedIndex, 1)
        XCTAssertEqual(store.query, "3+3=")

        store.deleteSelection()
        XCTAssertEqual(store.calculationHistory, [entries[1]], "Identical expressions must be deleted by identity")
        XCTAssertEqual(store.selectedCalculation, entries[1])
        store.deleteSelection()
        XCTAssertTrue(store.calculationHistory.isEmpty)
        XCTAssertNil(store.selectedCalculation)
        XCTAssertEqual(store.selectedIndex, 0)
        XCTAssertTrue(store.showsCalculations, "The last deletion should show the empty history")
        XCTAssertEqual(store.cardHeight, LauncherLayout.expandedHeight)
        XCTAssertEqual(store.query, "3+3=")
        store.deleteCalculation(entries[0])
        store.reset()
        store.query = "="
        XCTAssertTrue(store.calculationHistory.isEmpty, "Deleted entries must stay deleted when reopening history")
    }

    @MainActor func testHistoryEditsAndDeletionsSurviveNewStoreInstances() throws {
        try withHistoryFile { url in
            let store = LauncherStore(applications: [], calculationHistoryURL: url)
            XCTAssertTrue(store.calculationHistory.isEmpty)
            store.query = "2+2="
            let editedID = try XCTUnwrap(store.calculationHistory.first?.id)
            store.query = "2+3="
            store.query = "rate = 25"
            store.launchSelection()
            store.query = "rate * 2 ="
            store.query = "rate = 30"
            store.launchSelection()
            let expected = store.calculationHistory

            let reopened = LauncherStore(applications: [], calculationHistoryURL: url)
            XCTAssertEqual(reopened.calculationHistory, expected)
            XCTAssertEqual(reopened.calculationHistory.last?.id, editedID)
            XCTAssertEqual(reopened.calculationHistory.map(\.result), ["30", "50", "25", "5"])
            XCTAssertFalse(reopened.hasExpandedResults, "Restoring history must not open it until requested")
            reopened.query = "="
            XCTAssertTrue(reopened.showsCalculations)
            XCTAssertEqual(reopened.calculationHistory, expected, "Loading must preserve recorded answers without reevaluation")

            reopened.deleteCalculation(expected[1])
            let afterDeletion = LauncherStore(applications: [], calculationHistoryURL: url)
            XCTAssertEqual(afterDeletion.calculationHistory, expected.filter { $0.id != expected[1].id })
            for entry in afterDeletion.calculationHistory { afterDeletion.deleteCalculation(entry) }
            XCTAssertTrue(LauncherStore(applications: [], calculationHistoryURL: url).calculationHistory.isEmpty)
        }
    }

    @MainActor func testRestoredHistoryRetainsOnlyTheLatestHundredEntries() throws {
        try withHistoryFile { url in
            let entries = (0..<120).map {
                LauncherCalculation(expression: "\($0)+1", result: "\($0 + 1)", numericValue: Double($0 + 1))
            }
            try JSONEncoder().encode(entries).write(to: url)
            let store = LauncherStore(applications: [], calculationHistoryURL: url)
            XCTAssertEqual(store.calculationHistory, Array(entries.prefix(100)))
            store.query = "200+1="
            let reopened = LauncherStore(applications: [], calculationHistoryURL: url)
            XCTAssertEqual(reopened.calculationHistory, store.calculationHistory)
            XCTAssertEqual(reopened.calculationHistory.count, 100)
            XCTAssertEqual(reopened.calculationHistory.first?.result, "201")
            XCTAssertEqual(reopened.calculationHistory.last?.id, entries[98].id)
            XCTAssertEqual(try JSONDecoder().decode([LauncherCalculation].self, from: Data(contentsOf: url)).count, 100)
        }
    }

    @MainActor func testUnreadableHistoryReportsTheFailureWithoutOverwritingTheFile() throws {
        try withHistoryFile { url in
            let damagedData = Data("incomplete history".utf8)
            try damagedData.write(to: url)
            let store = LauncherStore(applications: [], calculationHistoryURL: url)
            store.query = "="
            XCTAssertNotNil(store.errorMessage)
            store.query = "2+2="
            XCTAssertEqual(store.calculationResult, "4")
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(try Data(contentsOf: url), damagedData)
        }
    }

    @MainActor func testFailedHistorySaveKeepsEntriesAndRetriesOnTheNextChange() throws {
        try withHistoryFile { url in
            let store = LauncherStore(applications: [], calculationHistoryURL: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            store.query = "2+2="
            XCTAssertEqual(store.calculationHistory.first?.result, "4")
            XCTAssertNotNil(store.errorMessage)
            store.reset()
            XCTAssertNil(store.errorMessage, "Storage errors should only appear when viewing the calculator")
            store.query = "="
            XCTAssertNotNil(store.errorMessage)

            try FileManager.default.removeItem(at: url)
            store.query = "2+3="
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(LauncherStore(applications: [], calculationHistoryURL: url).calculationHistory, store.calculationHistory)
            XCTAssertEqual(store.calculationHistory.map(\.result), ["5", "4"])
        }
    }

    @MainActor func testDeletingActiveCalculationKeepsVariablesAndFutureEditsIndependent() throws {
        let store = LauncherStore(applications: [])
        store.query = "rate = 25"
        store.launchSelection()
        let assignment = try XCTUnwrap(store.selectedCalculation)
        store.deleteCalculation(assignment)
        XCTAssertTrue(store.calculationHistory.isEmpty)
        store.query = "rate * 2 ="
        XCTAssertEqual(store.calculationResult, "50", "Removing history must not erase saved variables")
        let deleted = try XCTUnwrap(store.selectedCalculation)
        store.deleteSelection()
        XCTAssertTrue(store.calculationHistory.isEmpty)
        store.query = "rate * 3 ="
        let replacement = try XCTUnwrap(store.selectedCalculation)
        XCTAssertNotEqual(replacement.id, deleted.id)
        XCTAssertEqual(replacement.result, "75")
        XCTAssertEqual(store.calculationHistory.count, 1)
    }

    @MainActor func testKeyboardAndButtonDeleteCalculationsWithoutEditingSearch() async throws {
        let store = LauncherStore(applications: [])
        let launcher = LauncherController(store: store)
        launcher.show(at: NSPoint(x: 300, y: 400))
        defer { launcher.dismiss() }
        store.query = "2+2="
        store.query = ""
        store.query = "3+3="
        store.select(index: 1)
        let remaining = try XCTUnwrap(store.calculationHistory.first)
        try await Task.sleep(for: .milliseconds(300))
        let panel = try XCTUnwrap(launcher.panel)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
                                                  timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                  characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                                  isARepeat: false, keyCode: UInt16(kVK_Delete)))
        NSApp.sendEvent(event)
        XCTAssertEqual(store.calculationHistory, [remaining])
        XCTAssertEqual(store.selectedCalculation, remaining)
        XCTAssertEqual(store.query, "3+3=", "Deleting history must not delete a word from the search field")
        XCTAssertTrue(launcher.isVisible)

        try await Task.sleep(for: .milliseconds(300))
        let expressionWidth = (LauncherLayout.width - 2 * LauncherLayout.listInset) * 2 / 3
        let deletePoint = NSPoint(x: LauncherLayout.inset + LauncherLayout.listInset + expressionWidth - 4 - 13,
                                  y: panel.frame.height - LauncherLayout.inset - LauncherLayout.searchHeight
                                      - 1 - LauncherLayout.listInset - LauncherLayout.rowHeight / 2)
        func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: deletePoint, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // Dispatch directly to the panel: its outside-click monitor reads the
        // physical pointer, which this local test deliberately does not move.
        panel.sendEvent(try mouseEvent(.leftMouseDown))
        panel.sendEvent(try mouseEvent(.leftMouseUp))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.calculationHistory.isEmpty)
        XCTAssertTrue(store.showsCalculations)
        XCTAssertEqual(store.query, "3+3=")
        XCTAssertTrue(launcher.isVisible)
    }

    @MainActor func testLauncherStaysAboveAnAppPopupOrderedLater() async throws {
        let store = LauncherStore(applications: [])
        let launcher = LauncherController(store: store)
        launcher.show(at: NSPoint(x: 300, y: 400))
        let panel = try XCTUnwrap(launcher.panel)
        let modal = NSPanel(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        modal.level = .popUpMenu
        modal.orderFrontRegardless()
        defer { modal.close(); launcher.dismiss() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(panel.level.rawValue, modal.level.rawValue)
        let windows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        let ids = windows.compactMap { $0[kCGWindowNumber as String] as? Int }
        let launcherIndex = try XCTUnwrap(ids.firstIndex(of: panel.windowNumber))
        let modalIndex = try XCTUnwrap(ids.firstIndex(of: modal.windowNumber))
        XCTAssertLessThan(launcherIndex, modalIndex)
    }
}
