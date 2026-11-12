import AppKit
import XCTest
@testable import seven

final class ClipboardTests: XCTestCase {
    @MainActor private func withHistory(limit: Int = 200, maximumBytes: Int = 1024 * 1024,
                                        _ body: (ClipboardHistory, NSPasteboard) throws -> Void) rethrows {
        let board = NSPasteboard(name: .init("seven-tests-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(storageURL: nil, pasteboard: board, limit: limit,
                                       maximumBytes: maximumBytes, autoStart: false, defaults: nil)
        try body(history, board)
    }

    @MainActor private func copy(_ text: String, to board: NSPasteboard, history: ClipboardHistory) {
        board.clearContents(); board.setString(text, forType: .string)
        history.captureIfChanged(sourceName: "Test Editor", sourceBundleIdentifier: "test.editor")
    }

    @MainActor func testCaptureSearchDeduplicationAndRecency() {
        withHistory { history, board in
            copy("Café first copy", to: board, history: history)
            let firstID = history.entries[0].id
            copy("Another item", to: board, history: history)
            copy("Café first copy", to: board, history: history)
            XCTAssertEqual(history.entries.count, 2)
            XCTAssertEqual(history.entries.first?.id, firstID)
            XCTAssertEqual(history.results(for: "CAFE editor").first?.id, firstID)
            XCTAssertEqual(history.results(for: "test.editor").count, 2)
            XCTAssertTrue(history.results(for: "missing").isEmpty)
            history.captureIfChanged()
            XCTAssertEqual(history.entries.count, 2)
        }
    }

    @MainActor func testConfidentialTemporaryAndEmptyCopiesAreIgnored() {
        withHistory { history, board in
            // The legacy "Pasteboard generator type" cannot be written through
            // modern NSPasteboardItem, which accepts UTI identifiers only.
            for marker in ClipboardHistory.ignoredTypes where !marker.contains(" ") {
                history.clear()
                board.clearContents()
                let item = NSPasteboardItem()
                item.setString("do not record", forType: .string)
                XCTAssertTrue(item.setData(Data(), forType: .init(marker)))
                board.writeObjects([item]); history.captureIfChanged()
                XCTAssertTrue(history.entries.isEmpty, "Captured ignored marker: \(marker)")
            }
            copy("", to: board, history: history)
            XCTAssertTrue(history.entries.isEmpty)
            copy("normal copy", to: board, history: history)
            XCTAssertEqual(history.entries.count, 1)
        }
    }

    @MainActor func testRichContentRestoresFormatsAndCanRestorePlainText() throws {
        try withHistory { history, board in
            let rich = NSAttributedString(string: "Formatted example", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
            let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let item = NSPasteboardItem()
            item.setString(rich.string, forType: .string); item.setData(rtf, forType: .rtf)
            board.clearContents(); board.writeObjects([item]); history.captureIfChanged()
            let entry = try XCTUnwrap(history.entries.first)
            copy("replacement", to: board, history: history)
            XCTAssertTrue(history.restore(entry))
            XCTAssertEqual(board.data(forType: .rtf), rtf)
            XCTAssertEqual(board.string(forType: .string), rich.string)
            history.captureIfChanged()
            XCTAssertEqual(history.entries.count, 2)
            XCTAssertTrue(history.restore(entry, plainText: true))
            XCTAssertEqual(board.string(forType: .string), rich.string)
            XCTAssertNil(board.data(forType: .rtf))
        }
    }

    @MainActor func testImageAndMultipleFileCopiesRoundTrip() throws {
        try withHistory { history, board in
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            board.clearContents(); board.setData(png, forType: .png); history.captureIfChanged()
            let image = try XCTUnwrap(history.entries.first)
            XCTAssertEqual(image.kind, .image)
            XCTAssertNotNil(history.thumbnail(for: image))
            let files = ["/tmp/seven-first.txt", "/tmp/seven-second.png"].map { path -> NSPasteboardItem in
                let item = NSPasteboardItem(); item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL); return item
            }
            board.clearContents(); board.writeObjects(files); history.captureIfChanged()
            let entry = try XCTUnwrap(history.entries.first)
            XCTAssertEqual(entry.kind, .files)
            XCTAssertEqual(entry.items.count, 2)
            XCTAssertEqual(history.results(for: "second.png").first?.id, entry.id)
            XCTAssertTrue(history.restore(image))
            XCTAssertEqual(board.data(forType: .png), png)
            XCTAssertTrue(history.restore(entry))
            XCTAssertEqual(board.pasteboardItems?.count, 2)
            XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .fileURL), "file:///tmp/seven-first.txt")
        }
    }

    @MainActor func testPauseDeleteClearAndRetention() {
        withHistory(limit: 2) { history, board in
            copy("one", to: board, history: history)
            history.isPaused = true
            copy("ignored", to: board, history: history)
            history.isPaused = false
            history.captureIfChanged()
            XCTAssertEqual(history.entries.count, 1)
            copy("two", to: board, history: history)
            copy("three", to: board, history: history)
            XCTAssertEqual(history.entries.map(\.text), ["three", "two"])
            history.delete(history.entries[0])
            XCTAssertEqual(history.entries.first?.text, "two")
            history.clear()
            XCTAssertTrue(history.entries.isEmpty)
        }
        withHistory(maximumBytes: 10) { history, board in
            copy("123456", to: board, history: history)
            copy("abcdef", to: board, history: history)
            XCTAssertEqual(history.entries.map(\.text), ["abcdef"])
        }
    }

    @MainActor func testHistoryPersistsAndClearingSurvivesRestart() throws {
        let board = NSPasteboard(name: .init("seven-tests-" + UUID().uuidString))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let history = ClipboardHistory(storageURL: url, pasteboard: board, autoStart: false, defaults: nil)
        copy("Persistent local history", to: board, history: history)
        history.flush()
        let restored = ClipboardHistory(storageURL: url, pasteboard: board, autoStart: false, defaults: nil)
        XCTAssertEqual(restored.entries, history.entries)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        restored.clear(); restored.flush()
        XCTAssertTrue(ClipboardHistory(storageURL: url, pasteboard: board, autoStart: false, defaults: nil).entries.isEmpty)
    }

    @MainActor func testLauncherHistorySelectionSearchCollapseAndRestore() {
        withHistory { history, board in
            copy("first", to: board, history: history)
            copy("second", to: board, history: history)
            let store = LauncherStore(applications: [], clipboard: history)
            store.toggleClipboard()
            XCTAssertEqual(store.clipboardResults.count, 2)
            XCTAssertTrue(store.hasExpandedResults)
            store.moveSelection(by: 1)
            XCTAssertEqual(store.selectedClipboardEntry?.text, "first")
            copy("third", to: board, history: history)
            XCTAssertEqual(store.selectedClipboardEntry?.text, "first")
            store.query = "zzzz"
            XCTAssertFalse(store.hasExpandedResults)
            XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight + 1 + LauncherLayout.footerHeight)
            store.query = "second"
            var restored: UUID?
            store.onRestore = { entry, paste, plain in restored = entry.id; XCTAssertFalse(paste); XCTAssertTrue(plain) }
            store.launchSelection(plainText: true)
            XCTAssertEqual(restored, store.clipboardResults.first?.id)
            store.deleteSelection()
            XCTAssertFalse(store.hasExpandedResults)
            store.toggleClipboard()
            XCTAssertEqual(store.mode, .applications)
            XCTAssertEqual(store.cardHeight, LauncherLayout.searchHeight)
            XCTAssertNotNil(NSImage(systemSymbolName: LauncherLayout.clipboardSymbol, accessibilityDescription: nil))
        }
    }

    @MainActor func testPlainPasteAndExplicitCopyActionsRespectTheirIntent() {
        withHistory { history, board in
            copy("Clipboard action example", to: board, history: history)
            let store = LauncherStore(applications: [], clipboard: history)
            store.toggleClipboard()
            var requests: [(Bool, Bool)] = []
            store.onRestore = { _, paste, plain in requests.append((paste, plain)) }
            store.launchSelection(paste: true, plainText: true)
            XCTAssertTrue(requests[0].0)
            XCTAssertTrue(requests[0].1)
            history.pasteAutomatically = true
            store.launchSelection(respectAutomaticPaste: false)
            XCTAssertFalse(requests[1].0)
            XCTAssertFalse(requests[1].1)
        }
    }
    @MainActor func testImagesRestorePixelsInsteadOfFileNamesIncludingLegacyEntries() throws {
        try withHistory { history, board in
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try png.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            for includePixels in [true, false] {
                let item = NSPasteboardItem()
                item.setString(file.lastPathComponent, forType: .string)
                item.setString(file.absoluteString, forType: .fileURL)
                if includePixels { item.setData(png, forType: .png) }
                board.clearContents(); board.writeObjects([item]); history.captureIfChanged()
                let entry = try XCTUnwrap(history.entries.first)
                XCTAssertEqual(entry.kind, .image)
                XCTAssertTrue(history.restore(entry))
                XCTAssertNotNil(board.data(forType: .png))
                XCTAssertNil(board.string(forType: .string))
                XCTAssertNil(board.string(forType: .fileURL))
                XCTAssertNotNil(NSImage(pasteboard: board))
            }
            let legacy = ClipboardEntry(id: UUID(), fingerprint: "legacy-file", items: [ClipboardItemSnapshot(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data(file.absoluteString.utf8)),
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(file.lastPathComponent.utf8))
            ])], kind: .files, text: file.lastPathComponent, title: file.lastPathComponent,
               sourceName: nil, sourceBundleIdentifier: nil, copiedAt: Date())
            XCTAssertTrue(history.restore(legacy))
            XCTAssertNotNil(board.data(forType: .png))
            XCTAssertNil(board.string(forType: .string))
        }
    }

    @MainActor func testCustomActionsNavigationAndPlainPasteDispatch() {
        withHistory { history, board in
            copy("An action item", to: board, history: history)
            let launcher = LauncherStore(applications: [], clipboard: history)
            launcher.toggleClipboard()
            let actions = ClipboardActionsStore(launcher: launcher)
            actions.move(by: 1)
            XCTAssertEqual(actions.selected, .paste)
            actions.move(by: 1)
            XCTAssertEqual(actions.selected, .pasteWithoutFormatting)
            var performed: ClipboardAction?
            actions.onPerform = { performed = $0 }
            actions.perform(actions.selected)
            XCTAssertEqual(performed, .pasteWithoutFormatting)
            var pasteRequested = false
            var plainRequested = false
            launcher.onRestore = { _, paste, plain in pasteRequested = paste; plainRequested = plain }
            actions.execute(.pasteWithoutFormatting)
            XCTAssertTrue(pasteRequested)
            XCTAssertTrue(plainRequested)
            history.clear()
            XCTAssertFalse(actions.isEnabled(.pasteWithoutFormatting))
            actions.selected = .copy
            performed = nil
            actions.perform(.copy)
            XCTAssertNil(performed)
            actions.move(by: 1)
            XCTAssertEqual(actions.selected, .pause)
        }
    }

    func testPasteWaitsForFocusAndReleasedInput() {
        let delivery = ClipboardPasteReadiness(destinationPID: 42, ownPID: 7, deadline: 2)
        XCTAssertEqual(delivery.decision(now: 0.01, frontmostPID: 7, destinationAlive: true,
                                        panelHasFocus: false, inputHeld: false), .wait)
        XCTAssertEqual(delivery.decision(now: 0.25, frontmostPID: 42, destinationAlive: true,
                                        panelHasFocus: true, inputHeld: false), .wait)
        XCTAssertEqual(delivery.decision(now: 0.50, frontmostPID: 42, destinationAlive: true,
                                        panelHasFocus: false, inputHeld: true), .wait)
        XCTAssertEqual(delivery.decision(now: 0.75, frontmostPID: 42, destinationAlive: true,
                                        panelHasFocus: false, inputHeld: false), .paste)
    }

    func testPasteCancelsIfTheUserSwitchesToAnotherApp() {
        let delivery = ClipboardPasteReadiness(destinationPID: 42, ownPID: 7, deadline: 2)
        XCTAssertEqual(delivery.decision(now: 0.1, frontmostPID: 99, destinationAlive: true,
                                        panelHasFocus: false, inputHeld: false), .cancel)
        XCTAssertEqual(delivery.decision(now: 0.1, frontmostPID: nil, destinationAlive: true,
                                        panelHasFocus: false, inputHeld: false), .wait)
    }

    func testPasteReportsUnavailableFocusAndHeldInput() {
        let delivery = ClipboardPasteReadiness(destinationPID: 42, ownPID: 7, deadline: 2)
        XCTAssertEqual(delivery.decision(now: 0.1, frontmostPID: 42, destinationAlive: false,
                                        panelHasFocus: false, inputHeld: false), .fail(.destinationUnavailable))
        XCTAssertEqual(delivery.decision(now: 2, frontmostPID: 7, destinationAlive: true,
                                        panelHasFocus: false, inputHeld: false), .fail(.focusTimedOut))
        XCTAssertEqual(delivery.decision(now: 2, frontmostPID: 42, destinationAlive: true,
                                        panelHasFocus: false, inputHeld: true), .fail(.inputStillHeld))
    }

    @MainActor func testBlockedPasteKeepsSelectionAndClipboardUntilPermissionIsGranted() {
        withHistory { history, board in
            copy("The selected history entry", to: board, history: history)
            let store = LauncherStore(applications: [], clipboard: history)
            let controller = LauncherController(store: store, pastePermission: { false })
            withExtendedLifetime(controller) {
                store.toggleClipboard()
                let selectedID = store.selectedClipboardEntry?.id
                board.clearContents(); board.setString("Current clipboard remains untouched", forType: .string)
                store.launchSelection(paste: true)
                XCTAssertTrue(store.needsAccessibilityAccess)
                XCTAssertEqual(store.errorMessage, ClipboardPasteFailure.accessibilityRequired.localizedDescription)
                XCTAssertEqual(store.selectedClipboardEntry?.id, selectedID)
                XCTAssertTrue(store.hasExpandedResults)
                XCTAssertEqual(board.string(forType: .string), "Current clipboard remains untouched")
                XCTAssertEqual(store.cardHeight, LauncherLayout.maximumHeight)
                // Explicit copying continues to work without Accessibility permission.
                store.launchSelection(respectAutomaticPaste: false)
                XCTAssertEqual(board.string(forType: .string), "The selected history entry")
            }
        }
    }

}
