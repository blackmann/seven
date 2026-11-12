import AppKit
import Carbon
import XCTest
@testable import seven

@MainActor
final class NotesTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("seven-notes-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaultsName = "seven.notes.tests.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: folder)
    }

    func testVaultLifecycleAutosaveRenameAndReopen() throws {
        let store = VaultStore(defaults: defaults)
        try store.add(folder)
        XCTAssertTrue(store.createNote())
        XCTAssertEqual(store.selectedFile?.name, "Untitled.md")
        store.updateDraft("# Café\n\n- [ ] Ship notes\n[[Another|Another.md]]")
        XCTAssertFalse(store.hasUnsavedFileChanges)
        XCTAssertTrue(store.renameSelectedFile(to: "Plans.md"))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Plans.md"), encoding: .utf8), store.draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Untitled.md").path))
        let reopened = VaultStore(defaults: defaults)
        XCTAssertEqual(reopened.selectedID, store.selectedID)
        XCTAssertTrue(reopened.open(try XCTUnwrap(reopened.files.first)))
        XCTAssertEqual(reopened.draft, store.draft)
        XCTAssertTrue(reopened.createNote())
        XCTAssertTrue(reopened.createNote())
        XCTAssertEqual(reopened.selectedFile?.name, "Untitled 2.md")
    }

    func testVaultScratchpadsPersistIndependently() throws {
        let second = folder.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = VaultStore(defaults: defaults)
        try store.add(folder)
        let firstID = try XCTUnwrap(store.selectedID)
        store.updateDraft("first scratchpad")
        try store.add(second)
        store.updateDraft("second scratchpad")
        store.select(firstID)
        XCTAssertEqual(store.draft, "first scratchpad")
        XCTAssertTrue(store.createNote())
        store.updateDraft("saved note")
        XCTAssertTrue(store.openDraft())
        XCTAssertNil(store.selectedFile)
        XCTAssertEqual(store.draft, "first scratchpad")
        try store.add(folder)
        XCTAssertEqual(store.vaults.count, 2)
    }

    func testFailedSaveKeepsDraftAndBlocksNavigation() throws {
        let store = VaultStore(defaults: defaults)
        try store.add(folder)
        XCTAssertTrue(store.createNote())
        let file = try XCTUnwrap(store.selectedFile)
        // A directory at the destination reliably fails an atomic text save.
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
        store.updateDraft("keep this text")
        XCTAssertTrue(store.hasUnsavedFileChanges)
        XCTAssertFalse(store.createNote())
        XCTAssertFalse(store.openDraft())
        store.select(nil)
        XCTAssertNotNil(store.selectedID)
        XCTAssertEqual(store.draft, "keep this text")
        try FileManager.default.removeItem(at: file.url)
        store.updateDraft(store.draft)
        XCTAssertFalse(store.hasUnsavedFileChanges)
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "keep this text")
    }

    func testRenameRejectsTraversalAndExistingDestinations() throws {
        let store = VaultStore(defaults: defaults)
        try store.add(folder)
        XCTAssertTrue(store.createNote())
        let first = try XCTUnwrap(store.selectedFile)
        XCTAssertTrue(store.createNote())
        XCTAssertFalse(store.renameSelectedFile(to: "../outside.md"))
        XCTAssertFalse(store.renameSelectedFile(to: first.name))
        XCTAssertEqual(store.selectedFile?.name, "Untitled 2.md")
        let forged = VaultFile(relativePath: first.id, url: folder.appendingPathComponent("outside.md"), createdAt: nil, modifiedAt: nil)
        XCTAssertFalse(store.open(forged))
        XCTAssertFalse(store.delete(forged))
    }

    func testSearchFindsNestedPathsAndDeduplicatedContentLines() throws {
        let nested = folder.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# Plan\n\nCafé launch\n  Café launch\nNext café\n".write(to: nested.appendingPathComponent("Plan.md"), atomically: true, encoding: .utf8)
        try Data([0, 255, 1]).write(to: folder.appendingPathComponent("binary.bin"))
        try "hidden".write(to: folder.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        let store = VaultStore(defaults: defaults)
        try store.add(folder)
        XCTAssertEqual(store.files.count, 2)
        let results = VaultSearch.results(for: "CAFÉ", files: store.files)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.matches.map(\.lineNumber), [3, 5])
        XCTAssertEqual(VaultSearch.results(for: "projects/plan", files: store.files).first?.file.relativePath, "Projects/Plan.md")
        XCTAssertFalse(store.open(try XCTUnwrap(store.files.first { $0.name == "binary.bin" })))
    }

    func testWImportCopiesOnlyVaultsAndDraftsAndDoesNotOverwriteSeven() throws {
        let id = UUID()
        let data = try JSONEncoder().encode([Vault(id: id, bookmark: folder.bookmarkData(options: .minimalBookmark))])
        let legacy: [String: Any] = ["vaults": data, "selectedVaultID": id.uuidString,
                                   "vaultDraft.\(id)": "from W", "editorTheme": "sepia", "editorFontSize": 24]
        NotesPreferencesMigration.importWIfNeeded(into: defaults, legacy: legacy)
        let store = VaultStore(defaults: defaults)
        XCTAssertEqual(store.selectedID, id)
        XCTAssertEqual(store.draft, "from W")
        XCTAssertNil(defaults.object(forKey: "notes.editorTheme"))
        XCTAssertNil(defaults.object(forKey: "notes.editorFontSize"))
        store.updateDraft("from Seven")
        NotesPreferencesMigration.importWIfNeeded(into: defaults, legacy: legacy)
        XCTAssertEqual(VaultStore(defaults: defaults).draft, "from Seven")
    }

    func testWikiLinksPreferExactPathsAndNearbyDuplicateNames() {
        let resolver = VaultLinkResolver(paths: ["Other/Plan.md", "Work/Plan.md", "Café.md"], currentFolder: "Work")
        XCTAssertEqual(resolver.matchingPath(for: "Plan"), "Work/Plan.md")
        XCTAssertEqual(resolver.matchingPath(for: "Other/plan"), "Other/Plan.md")
        XCTAssertEqual(resolver.matchingPath(for: "CAFÉ"), "Café.md")
        XCTAssertNil(resolver.matchingPath(for: "Missing"))
        XCTAssertEqual(resolver.name(forID: "Work/Plan.md"), "Plan")
    }

    func testNotesPanelReusesEditorAndHasTransparentWindow() async throws {
        let store = VaultStore(defaults: defaults)
        try store.add(folder)
        let controller = NotesController(store: store)
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let leftAnchor = NSPoint(x: visible.minX + 60, y: visible.maxY - 100)
        controller.show(at: leftAnchor)
        defer { controller.close() }
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertEqual(panel.frame.minX + LauncherLayout.inset, leftAnchor.x + 20, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY - LauncherLayout.inset, leftAnchor.y + 28, accuracy: 0.5)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        try await Task.sleep(for: .milliseconds(200))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                  timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                  characters: "n", charactersIgnoringModifiers: "n", isARepeat: false,
                                                  keyCode: UInt16(kVK_ANSI_N)))
        NSApp.sendEvent(event)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(store.selectedFile, "Command–N should create a note from the panel")
        func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        let editor = try XCTUnwrap(textViews(in: try XCTUnwrap(panel.contentView)).first { !$0.isFieldEditor })
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(panel.firstResponder === editor, "A newly created note should be ready to type into")
        panel.makeFirstResponder(editor)
        editor.insertText("# A clear place to think\n\nNotes live in your vault and save as you type.\n\n- [ ] Review the plan\n- [x] Bring notes into Seven\n\n## Next steps\n\nWrite, link, and find your ideas.", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(store.draft.contains("A clear place to think"))
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(store.selectedFile).url, encoding: .utf8), store.draft)
        if let content = panel.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                          uniformTypeIdentifier: "public.png")
            attachment.name = "Notes editor"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let rightAnchor = NSPoint(x: visible.maxX - 30, y: visible.maxY - 80)
        panel.setContentSize(NSSize(width: 440, height: 460))
        let resizedSize = panel.frame.size
        controller.show(at: rightAnchor)
        XCTAssertEqual(panel.frame.size, resizedSize, "Reactivation should preserve the user's window size")
        XCTAssertEqual(panel.frame.maxX - LauncherLayout.inset, rightAnchor.x - 20, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY - LauncherLayout.inset, rightAnchor.y + 28, accuracy: 0.5)
        XCTAssertTrue(panel.firstResponder === editor)
        controller.close()
        XCTAssertFalse(panel.isVisible)
        controller.show(at: leftAnchor)
        XCTAssertTrue(controller.panel === panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.size, resizedSize)
        XCTAssertEqual(panel.frame.minX + LauncherLayout.inset, leftAnchor.x + 20, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY - LauncherLayout.inset, leftAnchor.y + 28, accuracy: 0.5)
        let browse = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                   timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                   characters: "F", charactersIgnoringModifiers: "f", isARepeat: false,
                                                   keyCode: UInt16(kVK_ANSI_F)))
        NSApp.sendEvent(browse)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(editor.isEditable, "Command–Shift–F should return to the browser")
        XCTAssertTrue((panel.firstResponder as? NSTextView)?.isFieldEditor == true)
    }

    func testNotesUsesNormalWindowLevelAndActivatesWhenOpenedOrReopened() async throws {
        let controller = NotesController(store: VaultStore(defaults: defaults))
        defer { controller.close() }

        for _ in 0..<2 {
            NSApp.hide(nil)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(NSApp.isActive)

            controller.show(at: NSPoint(x: 500, y: 500))
            try await Task.sleep(for: .milliseconds(200))
            let panel = try XCTUnwrap(controller.panel)
            XCTAssertEqual(panel.level, .normal, "Other apps' windows should be able to cover Notes")
            XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(NSApp.isActive, "Notes must activate Seven so modifier gestures cannot reach the previous app")
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
            XCTAssertTrue(panel.isKeyWindow)
            XCTAssertTrue(panel.isMainWindow)
            controller.close()
        }
    }

    func testAlertKeepsTheNotesWindowMarginTransparent() async throws {
        let store = VaultStore(defaults: defaults)
        let controller = NotesController(store: store)
        controller.show(at: NSPoint(x: 500, y: 500))
        defer { store.error = nil; controller.close() }
        try await Task.sleep(for: .milliseconds(150))
        store.error = "Choose the vault folder again to restore access."
        try await Task.sleep(for: .milliseconds(350))
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertNotNil(panel.attachedSheet)
        func verifyMargin(name: String) throws {
            let frame = try XCTUnwrap(panel.contentView?.superview)
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            for (x, y) in [(2, 2), (bitmap.pixelsWide - 3, 2), (2, bitmap.pixelsHigh - 3),
                           (bitmap.pixelsWide - 3, bitmap.pixelsHigh - 3), (2, bitmap.pixelsHigh / 2)] {
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0.01)
            }
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent, 0.5)
        }
        try verifyMargin(name: "Notes with alert")
        panel.setContentSize(NSSize(width: 440, height: 460))
        try await Task.sleep(for: .milliseconds(200))
        try verifyMargin(name: "Resized notes with alert")
        store.error = nil
        try await Task.sleep(for: .milliseconds(150))
    }
}
