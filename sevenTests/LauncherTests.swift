import AppKit
import Carbon
import XCTest
@testable import seven

@MainActor
private final class CopyRecordingTextView: NSTextView {
    var copiedSelections: [NSRange] = []

    override func copy(_ sender: Any?) {
        // Observe the native action without changing the user's clipboard.
        copiedSelections.append(selectedRange())
    }
}

final class LauncherTests: XCTestCase {
    @MainActor func testGlobalShortcutsRouteOnlyTheirOwnHotKeyEvents() throws {
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let first = GlobalShortcut(keyCode: UInt32(kVK_F18), modifiers: modifiers, id: 101)
        let second = GlobalShortcut(keyCode: UInt32(kVK_F19), modifiers: modifiers, id: 102)
        var presses: [Int] = []
        first.onPress = { presses.append(1) }
        second.onPress = { presses.append(2) }
        first.register()
        second.register()
        defer { first.unregister(); second.unregister() }
        XCTAssertEqual(first.registrationStatus, noErr)
        XCTAssertEqual(second.registrationStatus, noErr)

        func send(id: UInt32, signature: OSType = 0x4D4F4445) throws -> OSStatus {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                       0, EventAttributes(kEventAttributeUserEvent), &event), noErr)
            let hotKeyEvent = try XCTUnwrap(event)
            defer { ReleaseEvent(hotKeyEvent) }
            var identifier = EventHotKeyID(signature: signature, id: id)
            XCTAssertEqual(SetEventParameter(hotKeyEvent, EventParamName(kEventParamDirectObject),
                                             EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size,
                                             &identifier), noErr)
            return SendEventToEventTarget(hotKeyEvent, GetApplicationEventTarget())
        }

        XCTAssertEqual(try send(id: 101), noErr)
        XCTAssertEqual(try send(id: 102), noErr)
        XCTAssertEqual(try send(id: 101), noErr)
        XCTAssertEqual(presses, [1, 2, 1], "The most recently installed handler must not swallow another shortcut")
        _ = try send(id: 102, signature: 0x54455354)
        second.unregister()
        _ = try send(id: 102)
        XCTAssertEqual(try send(id: 101), noErr)
        XCTAssertEqual(presses, [1, 2, 1, 1], "Unregistering one shortcut must leave the other working")
    }

    func testNotchPlacementRespectsHiddenMenuBarsAndExternalDisplayOrigins() {
        let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let belowNotch = LauncherLayout.belowNotchTopLeft(screenFrame: builtIn, visibleFrame: builtIn,
                                                         topSafeAreaInset: 38)
        XCTAssertEqual(belowNotch, NSPoint(x: 606, y: 936), "A hidden menu bar must not move the launcher into the notch")

        let external = NSRect(x: -1920, y: 180, width: 1920, height: 1080)
        let usable = NSRect(x: -1840, y: 180, width: 1840, height: 1056)
        let belowMenu = LauncherLayout.belowNotchTopLeft(screenFrame: external, visibleFrame: usable,
                                                        topSafeAreaInset: 0)
        XCTAssertEqual(belowMenu, NSPoint(x: -1110, y: 1228), "A side Dock must not shift the launcher away from screen center")
    }

    @MainActor func testNotchLauncherFocusesSearchAndExpandsDownward() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let store = LauncherStore(applications: (0..<8).map { app("Application \($0)") })
        let controller = LauncherController(store: store)
        controller.showBelowNotch(on: screen)
        defer { controller.dismiss() }
        try await Task.sleep(for: .milliseconds(400))
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(panel.isKeyWindow)
        let search = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertEqual(panel.frame.midX, screen.frame.midX, accuracy: 0.5)
        let cardTop = panel.frame.maxY - LauncherLayout.inset
        XCTAssertLessThanOrEqual(cardTop, screen.visibleFrame.maxY - 8)
        XCTAssertLessThanOrEqual(cardTop, screen.frame.maxY - screen.safeAreaInsets.top - 8)
        let originalTop = panel.frame.maxY
        let originalBottom = panel.frame.minY

        search.insertText("app", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(store.query, "app")
        XCTAssertEqual(store.results.count, 8)
        XCTAssertEqual(panel.frame.midX, screen.frame.midX, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, originalTop, accuracy: 0.5)
        XCTAssertLessThan(panel.frame.minY, originalBottom)
        XCTAssertTrue(panel.firstResponder === search)
    }

    @MainActor func testStandardEditMenuRoutesThroughTheNativeResponderChain() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let editMenu = try XCTUnwrap(menu.item(withTitle: "Edit")?.submenu)
        let copyItem = try XCTUnwrap(editMenu.item(withTitle: "Copy"))
        XCTAssertNil(copyItem.target, "AppKit must resolve the focused editor itself")
        let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let editor = CopyRecordingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        defer { panel.close() }
        panel.contentView = editor
        editor.string = "copy Café + 42 only"
        editor.allowsUndo = true
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        XCTAssertTrue(panel.isKeyWindow)
        let selection = (editor.string as NSString).range(of: "Café + 42")
        editor.setSelectedRange(selection)

        func key(_ character: String, code: Int, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                          characters: character, charactersIgnoringModifiers: character,
                                          isARepeat: false, keyCode: UInt16(code)))
        }

        NSApp.sendEvent(try key("c", code: kVK_ANSI_C))
        XCTAssertEqual(editor.copiedSelections, [selection])
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.string, "copy Café + 42 only")

        NSApp.sendEvent(try key("a", code: kVK_ANSI_A))
        NSApp.sendEvent(try key("c", code: kVK_ANSI_C))
        XCTAssertEqual(editor.copiedSelections, [selection, NSRange(location: 0, length: (editor.string as NSString).length)])

        XCTAssertFalse(menu.performKeyEquivalent(with: try key("C", code: kVK_ANSI_C, modifiers: [.command, .shift])))
        XCTAssertEqual(editor.copiedSelections.count, 2, "The clipboard history shortcut must not copy search text")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editMenu.update()
        XCTAssertFalse(copyItem.isEnabled, "AppKit disables Copy when there is no selection")

        let original = editor.string
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        editor.insertText("new ", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "new " + original)
        NSApp.sendEvent(try key("z", code: kVK_ANSI_Z))
        XCTAssertEqual(editor.string, original)
        XCTAssertTrue(undo.canRedo)
        // Direct sendEvent calls bypass the main loop's menu refresh.
        editMenu.update()
        NSApp.sendEvent(try key("Z", code: kVK_ANSI_Z, modifiers: [.command, .shift]))
        XCTAssertEqual(editor.string, "new " + original)
    }

    @MainActor func testNativeEditingUpdatesTheSwiftUISearchField() async throws {
        let store = LauncherStore(applications: [])
        let controller = LauncherController(store: store)
        controller.show(at: NSPoint(x: 400, y: 600))
        defer { controller.dismiss() }
        try await Task.sleep(for: .milliseconds(100))
        let panel = try XCTUnwrap(controller.panel)
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.beginUndoGrouping()
        editor.insertText("native editing", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        XCTAssertEqual(store.query, "native editing")
        func sendKey(_ character: String, code: Int, modifiers: NSEvent.ModifierFlags = .command) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                      timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                      characters: character, charactersIgnoringModifiers: character,
                                                      isARepeat: false, keyCode: UInt16(code)))
            NSApp.sendEvent(event)
        }
        try sendKey("a", code: kVK_ANSI_A)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 14))
        try sendKey("z", code: kVK_ANSI_Z)
        XCTAssertEqual(store.query, "")
        XCTAssertTrue(undo.canRedo)
        let editMenu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Edit")?.submenu)
        // Refresh as AppKit does between real keyboard events.
        editMenu.update()
        let redoItem = try XCTUnwrap(editMenu.items.first { $0.action == Selector(("redo:")) })
        XCTAssertTrue(redoItem.isEnabled)
        try sendKey("Z", code: kVK_ANSI_Z, modifiers: [.command, .shift])
        XCTAssertEqual(store.query, "native editing")
    }

    func testOptionTapOpensClipboardButHeldOptionAndOtherShortcutsDoNot() {
        var gesture = ClipboardActivationGesture()
        gesture.reset(optionIsDown: true)
        XCTAssertFalse(gesture.flagsChanged([]), "Releasing Option–Tab must only open the launcher")
        XCTAssertFalse(gesture.flagsChanged(.option))
        XCTAssertTrue(gesture.flagsChanged([]))
        XCTAssertFalse(gesture.flagsChanged([]))
        XCTAssertFalse(gesture.flagsChanged(.option))
        gesture.cancel()
        XCTAssertFalse(gesture.flagsChanged([]), "Option with a key or click must keep its normal behavior")
        XCTAssertFalse(gesture.flagsChanged(.option))
        XCTAssertFalse(gesture.flagsChanged([.option, .shift]))
        XCTAssertFalse(gesture.flagsChanged(.option))
        XCTAssertFalse(gesture.flagsChanged([]))
    }
    private func app(_ name: String) -> LauncherApplication {
        LauncherApplication(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name)
    }

    func testExactAndPrefixMatchesRankBeforeSubsequences() {
        let applications = [app("Visual Studio Code"), app("Code Editor"), app("Code"), app("Xcode")]
        let results = ApplicationSearch.results(for: "code", in: applications)
        XCTAssertEqual(results.first?.name, "Code")
        XCTAssertEqual(results.dropFirst().first?.name, "Code Editor")
    }

    func testAbbreviationsAndDiacritics() {
        XCTAssertEqual(ApplicationSearch.results(for: "gc", in: [app("Google Chrome"), app("Safari")]).map(\.name), ["Google Chrome"])
        XCTAssertEqual(ApplicationSearch.results(for: " CAFE ", in: [app("Café")]).first?.name, "Café")
        XCTAssertTrue(ApplicationSearch.results(for: "zzzz", in: [app("Calendar")]).isEmpty)
    }

    func testEmptyQueriesAndResultLimit() {
        let applications = (0..<12).map { app("Application \($0)") }
        XCTAssertTrue(ApplicationSearch.results(for: "  ", in: applications).isEmpty)
        XCTAssertTrue(ApplicationSearch.results(for: "app", in: applications, limit: 0).isEmpty)
        XCTAssertEqual(ApplicationSearch.results(for: "app", in: applications).count, 12)
        XCTAssertEqual(ApplicationSearch.results(for: "app", in: applications, limit: 6).count, 6)
        XCTAssertTrue(ApplicationSearch.results(for: "applicationxxxxxxxx", in: applications).isEmpty)
    }

    @MainActor func testKeyboardSelectionAndQueryReset() {
        let store = LauncherStore(applications: [app("Calendar"), app("Calculator")])
        store.query = "cal"
        XCTAssertEqual(store.results.count, 2)
        store.moveSelection(by: 100)
        XCTAssertEqual(store.selectedIndex, 1)
        store.moveSelection(by: -100)
        XCTAssertEqual(store.selectedIndex, 0)
        store.query = "calendar"
        XCTAssertEqual(store.selectedApplication?.name, "Calendar")
        store.query = ""
        XCTAssertFalse(store.showsList)
        XCTAssertNil(store.selectedApplication)
        XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight)
        store.reset()
        XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight)
    }

    func testPackageNamesAndBundleIdentifiersAreSearchable() {
        let application = LauncherApplication(
            url: URL(fileURLWithPath: "/Applications/Code.app"), name: "Visual Studio Code",
            bundleIdentifier: "com.microsoft.VSCode", alternateNames: ["Electron"])
        for query in ["code", "vscode", "com.microsoft.vs", "electron"] {
            XCTAssertEqual(ApplicationSearch.results(for: query, in: [application]), [application], query)
        }
    }

    func testCatalogFollowsApplicationLinksAndDeduplicatesBundles() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        let applications = temporary.appendingPathComponent("Applications")
        let bundle = temporary.appendingPathComponent("SystemVolume/Safari.app")
        try manager.createDirectory(at: applications, withIntermediateDirectories: true)
        try manager.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundlePackageType": "APPL", "CFBundleDisplayName": "Safari",
                    "CFBundleName": "Web Browser", "CFBundleExecutable": "Safari",
                    "CFBundleIdentifier": "com.apple.Safari"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try manager.createSymbolicLink(at: applications.appendingPathComponent("Safari.app"), withDestinationURL: bundle)
        try manager.createSymbolicLink(at: applications.appendingPathComponent("Browser.app"), withDestinationURL: bundle)
        try manager.createSymbolicLink(at: applications.appendingPathComponent("Missing.app"), withDestinationURL: temporary.appendingPathComponent("Missing"))

        let catalog = ApplicationCatalog.discover(in: [applications, bundle.deletingLastPathComponent()])
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog.first?.bundleIdentifier, "com.apple.Safari")
        for query in ["saf", "com.apple.safari", "web browser"] {
            XCTAssertEqual(ApplicationSearch.results(for: query, in: catalog).first?.name, "Safari", query)
        }
    }

    func testCatalogIncludesFinderAsAnIndividualBundle() throws {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        XCTAssertTrue(ApplicationCatalog.searchRoots.contains(finder))
        let catalog = ApplicationCatalog.discover(in: [finder, finder])
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog.first?.bundleIdentifier, "com.apple.finder")
        for query in ["finder", "find", "com.apple.finder"] {
            XCTAssertEqual(ApplicationSearch.results(for: query, in: catalog).first?.url, finder)
        }
    }

    @MainActor func testResultsKeepTheirHeightAndCollapseWhenEmpty() {
        let store = LauncherStore(applications: (0..<20).map { app("Application \($0)") })
        var layoutChanges = 0
        store.onLayoutChange = { layoutChanges += 1 }
        store.query = "app"
        XCTAssertEqual(store.results.count, 20)
        XCTAssertEqual(layoutChanges, 1)
        store.moveSelection(by: 12)
        XCTAssertEqual(store.selectedIndex, 12)
        store.query = "application 19"
        XCTAssertEqual(store.cardHeight, LauncherLayout.expandedHeight)
        XCTAssertEqual(layoutChanges, 1)
        store.query = "zzzz"
        XCTAssertFalse(store.hasExpandedResults)
        XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight)
        XCTAssertEqual(layoutChanges, 2)
        store.query = "app"
        XCTAssertTrue(store.hasExpandedResults)
        XCTAssertEqual(layoutChanges, 3)
        store.query = ""
        XCTAssertFalse(store.hasExpandedResults)
        XCTAssertEqual(layoutChanges, 4)
    }

    @MainActor func testResultsAnimateAfterExpansionAndSurviveInterruptedExits() async throws {
        let presentation = LauncherResultsPresentation()
        let results = LauncherDisplayedResults.applications((0..<8).map { .application(app("Application \($0)")) })
        let empty = LauncherDisplayedResults.applications([])
        presentation.update(results, reduceMotion: false)
        XCTAssertTrue(presentation.isExpanded)
        XCTAssertFalse(presentation.rowsVisible, "Rows must wait for the list to expand")
        // Reverse twice within the same expansion. The original wait still applies.
        presentation.update(empty, reduceMotion: false)
        presentation.update(results, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(presentation.rowsVisible)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(presentation.rowsVisible)
        XCTAssertLessThan(presentation.rowDelay(at: 0), presentation.rowDelay(at: 5))

        presentation.update(empty, reduceMotion: false)
        XCTAssertEqual(presentation.results, results, "Outgoing rows must remain mounted for their exit")
        XCTAssertTrue(presentation.isExpanded, "The list must stay open while rows exit")
        XCTAssertFalse(presentation.rowsVisible)
        XCTAssertGreaterThan(presentation.rowDelay(at: 0), presentation.rowDelay(at: 5))
        try await Task.sleep(for: .milliseconds(60))
        let replacement = LauncherDisplayedResults.applications([.application(app("Safari"))])
        presentation.update(replacement, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(presentation.results, replacement)
        XCTAssertTrue(presentation.isExpanded, "A cancelled exit must not collapse new results")
        XCTAssertTrue(presentation.rowsVisible)

        presentation.update(empty, reduceMotion: true)
        XCTAssertFalse(presentation.isExpanded)
        XCTAssertFalse(presentation.rowsVisible)
        XCTAssertEqual(presentation.results, empty)
    }

    @MainActor func testAnimatedWindowKeepsSearchFieldAnchored() async throws {
        let store = LauncherStore(applications: (0..<8).map { app("Application \($0)") })
        let controller = LauncherController(store: store)
        controller.show(at: NSPoint(x: 400, y: 600))
        defer { controller.dismiss() }
        try await Task.sleep(for: .milliseconds(400))
        let panel = try XCTUnwrap(controller.panel)
        let search = try XCTUnwrap(panel.firstResponder as? NSTextView)
        let top = panel.frame.maxY
        let searchFrame = panel.convertToScreen(search.convert(search.bounds, to: nil))
        let collapsedHeight = LauncherLayout.searchHeight + 2 * LauncherLayout.inset
        let expandedHeight = LauncherLayout.expandedHeight + 2 * LauncherLayout.inset

        for query in ["app", "no-matching-result"] {
            store.query = query
            var heights: [CGFloat] = []
            for _ in 0..<35 {
                try await Task.sleep(for: .milliseconds(20))
                heights.append(panel.frame.height)
                XCTAssertEqual(panel.frame.maxY, top, accuracy: 0.5)
                let current = panel.convertToScreen(search.convert(search.bounds, to: nil))
                XCTAssertEqual(current.minY, searchFrame.minY, accuracy: 0.5, "Search must not jump during resizing")
            }
            XCTAssertEqual(panel.frame.height, query == "app" ? expandedHeight : collapsedHeight, accuracy: 1)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertTrue(heights.contains { $0 > collapsedHeight + 1 && $0 < expandedHeight - 1 },
                              "The window must follow the intermediate card heights")
                for (previous, next) in zip(heights, heights.dropFirst()) {
                    if query == "app" { XCTAssertGreaterThanOrEqual(next + 0.5, previous) }
                    else { XCTAssertLessThanOrEqual(next - 0.5, previous) }
                }
            }
        }
    }

    @MainActor func testOnlyValidSelectionCanLaunch() {
        let store = LauncherStore(applications: [app("Safari")])
        var opened: [String] = []
        store.onLaunch = { opened.append($0.name) }
        store.launchSelection()
        XCTAssertTrue(opened.isEmpty)
        store.query = "saf"
        store.launchSelection()
        XCTAssertEqual(opened, ["Safari"])
        store.isLaunching = true
        store.launchSelection()
        XCTAssertEqual(opened, ["Safari"])
    }
    @MainActor func testOptionTapsToggleBothDirections() {
        var gesture = ClipboardActivationGesture()
        let store = LauncherStore(applications: [])
        for mode in [LauncherContent.clipboard, .applications] {
            XCTAssertFalse(gesture.flagsChanged(.option))
            if gesture.flagsChanged([]) { store.toggleClipboard() }
            XCTAssertEqual(store.mode, mode)
        }
    }

    @MainActor func testSystemCommandsAreSearchableAndDispatchWithoutOpeningAnApp() {
        let store = LauncherStore(applications: [app("Clock"), app("Safari")])
        var commands: [LauncherCommand] = []
        var openedApp = false
        let controller = LauncherController(store: store, commandExecutor: { command, completion in
            commands.append(command); completion(nil)
        }, opener: { _, completion in openedApp = true; completion(nil) })
        withExtendedLifetime(controller) {
            for query in ["dark mode", "light mode", "theme", "appearance"] {
                store.query = query
                XCTAssertEqual(store.selectedCommand, .toggleAppearance, query)
            }
            store.launchSelection()
            store.query = "lock"
            XCTAssertEqual(store.selectedCommand, .lockScreen)
            store.launchSelection()
            XCTAssertEqual(commands, [.toggleAppearance, .lockScreen])
            XCTAssertFalse(openedApp)
            store.query = "saf"
            XCTAssertEqual(store.selectedApplication?.name, "Safari")
        }
    }

    @MainActor func testCommandFailureHasAVisibleRecoverableMessage() {
        let store = LauncherStore(applications: [])
        let controller = LauncherController(store: store, commandExecutor: { _, completion in
            completion(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission needed"]))
        })
        withExtendedLifetime(controller) {
            store.query = "lock"
            store.launchSelection()
            XCTAssertEqual(store.errorMessage, "Permission needed")
            XCTAssertFalse(store.isLaunching)
            XCTAssertFalse(store.hasExpandedResults)
            XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight + LauncherLayout.errorHeight)
            store.query = "theme"
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.selectedCommand, .toggleAppearance)
        }
    }

    func testGoogleKeywordParsingAndSearchURLEncoding() throws {
        XCTAssertEqual(LauncherGoogleSearch.term(in: "google"), "")
        XCTAssertEqual(LauncherGoogleSearch.term(in: "  GOOGLE \t café recipes  \n"), "café recipes")
        for query in ["", "goog", "googlechrome", "googled helm", "search google helm"] {
            XCTAssertNil(LauncherGoogleSearch.term(in: query), query)
        }
        for term in ["helm", "helm chart values", "C++ & C# = 100%", "café 👩🏽‍💻", "helm?x=1&safe=off#fragment"] {
            let url = LauncherGoogleSearch(term: term).url
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "www.google.com")
            XCTAssertEqual(components.path, "/search")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: term)])
            XCTAssertNil(components.fragment)
            XCTAssertFalse(try XCTUnwrap(components.percentEncodedQuery).contains("+"), "Literal plus signs must not become spaces in Google")
        }
    }

    @MainActor func testGoogleKeywordWaitsForReturnAndOpensTheSearchURL() async throws {
        let store = LauncherStore(applications: [app("Google Helm")])
        var opened: [URL] = []
        let launcher = LauncherController(store: store, urlOpener: { opened.append($0); return true },
                                          opener: { _, _ in XCTFail("Web searches must use the default URL handler") })
        launcher.show(at: NSPoint(x: 400, y: 600))
        defer { launcher.dismiss() }
        store.query = "google"
        store.launchSelection()
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(store.hasExpandedResults)
        store.query = "google helm"
        XCTAssertEqual(store.selectedGoogleSearch?.term, "helm")
        XCTAssertEqual(store.resultCount, 1)
        XCTAssertNil(store.selectedApplication)
        XCTAssertNil(store.selectedCommand)
        XCTAssertTrue(opened.isEmpty, "Typing must not launch the browser")
        try await Task.sleep(for: .milliseconds(100))
        let panel = try XCTUnwrap(launcher.panel)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                  characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                                                  keyCode: UInt16(kVK_Return)))
        NSApp.sendEvent(event)
        XCTAssertEqual(opened, [URL(string: "https://www.google.com/search?q=helm")!])
        XCTAssertFalse(launcher.isVisible)
    }

    @MainActor func testGoogleKeywordStaysSeparateFromCalculationsDictionaryAndClipboard() {
        let store = LauncherStore(applications: [app("Google Chrome")])
        store.query = "2+2="
        let history = store.calculationHistory
        for query in ["google", "google 2+3=", "google rate = 25"] {
            store.query = query
            XCTAssertFalse(store.showsCalculations)
            XCTAssertNil(store.calculationResult)
            XCTAssertFalse(store.hasPendingAssignment)
            XCTAssertEqual(store.calculationHistory, history)
        }
        store.query = "define helm"
        XCTAssertEqual(store.dictionaryResult, .loading("helm"))
        store.query = "google helm"
        XCTAssertNil(store.dictionaryResult)
        XCTAssertEqual(store.selectedGoogleSearch?.term, "helm")
        var opened = false
        store.onOpenURL = { _ in opened = true }
        store.toggleClipboard()
        store.query = "google helm"
        XCTAssertNil(store.selectedGoogleSearch)
        store.launchSelection()
        XCTAssertFalse(opened)
        store.toggleClipboard()
        store.query = "googlechrome"
        XCTAssertEqual(store.selectedApplication?.name, "Google Chrome")
    }

    @MainActor func testGoogleBrowserFailureKeepsTheLauncherOpenAndCanBeRetried() {
        let store = LauncherStore(applications: [])
        var succeeds = false
        let launcher = LauncherController(store: store, urlOpener: { _ in succeeds })
        launcher.show(at: NSPoint(x: 400, y: 600))
        defer { launcher.dismiss() }
        store.query = "google helm"
        store.launchSelection()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isLaunching)
        XCTAssertTrue(launcher.isVisible)
        succeeds = true
        store.query = "google helm charts"
        XCTAssertNil(store.errorMessage)
        store.launchSelection()
        XCTAssertFalse(launcher.isVisible)
    }

    private func catalogTestDirectory() -> URL {
        // FSEvents excludes some system temporary directories from notifications.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".catalog-test-" + UUID().uuidString, isDirectory: true)
    }

    private func makeApplication(named name: String, in root: URL) throws -> URL {
        let app = root.appendingPathComponent(name + ".app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundlePackageType": "APPL", "CFBundleName": name,
                    "CFBundleIdentifier": "test.seven." + name.lowercased()]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @MainActor private func waitForCatalog(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("The application catalog did not refresh")
                throw NSError(domain: "sevenTests.CatalogTimeout", code: 1)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor func testNewApplicationsAppearWithoutRestartingOrChangingTheSearch() async throws {
        let root = catalogTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let zulu = try makeApplication(named: "RefreshSuiteZulu", in: root)
        let store = LauncherStore(applicationSearchRoots: [root])
        store.query = "refreshsuite"
        try await waitForCatalog { !store.isLoading && store.results.count == 1 }
        store.select(store.results[0])
        var layoutChanges = 0
        store.onLayoutChange = { layoutChanges += 1 }
        let alpha = try makeApplication(named: "RefreshSuiteA", in: root)
        try await waitForCatalog { store.results.count == 2 }
        XCTAssertEqual(store.results.first?.id, alpha.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(store.selectedApplication?.id, zulu.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(store.query, "refreshsuite")
        XCTAssertEqual(layoutChanges, 0, "A background refresh must not expand the existing list again")
    }

    @MainActor func testMovedAndRemovedApplicationsRefreshInsideNestedFolders() async throws {
        let root = catalogTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeApplication(named: "RefreshSuiteOriginal", in: root)
        let nested = root.appendingPathComponent("Utilities")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let store = LauncherStore(applicationSearchRoots: [root])
        store.query = "refreshsuite"
        try await waitForCatalog { !store.isLoading && store.results.count == 1 }
        let moved = nested.appendingPathComponent("RefreshSuiteMoved.app")
        try FileManager.default.moveItem(at: original, to: moved)
        try await waitForCatalog { store.results.first?.id == moved.resolvingSymlinksInPath().standardizedFileURL.path }
        store.query = "refreshsuitemoved"
        XCTAssertEqual(store.results.first?.id, moved.resolvingSymlinksInPath().standardizedFileURL.path)
        try FileManager.default.removeItem(at: moved)
        try await waitForCatalog { store.results.isEmpty }
        XCTAssertFalse(store.hasExpandedResults)
        XCTAssertEqual(store.query, "refreshsuitemoved")
    }

    @MainActor func testApplicationsFolderCanBeCreatedAfterMonitoringStarts() async throws {
        let parent = catalogTestDirectory()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Applications")
        let store = LauncherStore(applicationSearchRoots: [root])
        store.query = "refreshsuite"
        try await waitForCatalog { !store.isLoading }
        XCTAssertTrue(store.results.isEmpty)
        let added = try makeApplication(named: "RefreshSuiteNewFolder", in: root)
        try await waitForCatalog { store.results.first?.id == added.resolvingSymlinksInPath().standardizedFileURL.path }
    }

    @MainActor func testOpeningTheLauncherAlsoRefreshesTheCatalog() async throws {
        let root = catalogTestDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LauncherStore(applicationSearchRoots: [root])
        store.query = "refreshsuite"
        try await waitForCatalog { !store.isLoading }
        let added = try makeApplication(named: "RefreshSuiteOnOpen", in: root)
        store.refreshApplicationsForPresentation()
        XCTAssertTrue(store.isLoading)
        try await waitForCatalog { store.results.first?.id == added.resolvingSymlinksInPath().standardizedFileURL.path }
        XCTAssertEqual(store.query, "refreshsuite")
    }

}
