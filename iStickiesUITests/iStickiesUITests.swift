import XCTest

final class iStickiesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateEditPersistDeleteFlow() throws {
        let namespace = uniqueStoreNamespace()
        var app = launchApp(storeNamespace: namespace)
        let noteText = "UI test note \(UUID().uuidString.prefix(8))"

        let editor = waitForEditor(in: app)
        focus(editor)
        editor.typeText(noteText)
        XCTAssertTrue(waitForEditorText(noteText, in: app))

        waitForSnapshotPersistence()
        app.terminate()

        app = launchApp(storeNamespace: namespace)
        _ = waitForEditor(in: app)
        XCTAssertTrue(waitForEditorText(noteText, in: app))

        deleteCurrentNote(in: app)
        waitForSnapshotPersistence()
        app.terminate()

        app = launchApp(storeNamespace: namespace)
#if os(macOS)
        _ = waitForEditor(in: app)
        XCTAssertFalse(waitForEditorText(noteText, in: app, timeout: 1))
#else
        XCTAssertTrue(app.staticTexts["No Notes"].waitForExistence(timeout: 5))
#endif
    }

    @MainActor
    func testLocalSnapshotRecoveryCanStartFresh() throws {
        let app = launchApp(
            storeNamespace: uniqueStoreNamespace(),
            seedCorruptSnapshot: true
        )

        let recoveryView = app.otherElements["StickyNotes.localRecoveryView"].firstMatch
        XCTAssertTrue(recoveryView.waitForExistence(timeout: 6))

        let startFreshButton = app.buttons["StickyNotes.startFreshRecoveryButton"].firstMatch
        XCTAssertTrue(startFreshButton.waitForExistence(timeout: 2))
        activate(startFreshButton)

        XCTAssertFalse(recoveryView.waitForExistence(timeout: 2))
#if os(macOS)
        _ = waitForEditor(in: app)
#else
        XCTAssertTrue(app.staticTexts["No Notes"].waitForExistence(timeout: 5))
#endif
    }

#if os(macOS)
    @MainActor
    func testMacOSCreatesMultipleStickyWindowsAndDeletesFocusedWindow() throws {
        let app = launchApp(storeNamespace: uniqueStoreNamespace())
        _ = waitForEditor(in: app)
        XCTAssertTrue(waitForWindowCount(in: app, atLeast: 1))

        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(waitForWindowCount(in: app, atLeast: 2))

        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(waitForWindowCount(in: app, atLeast: 3))

        let windowCountBeforeDelete = app.windows.count
        deleteCurrentNote(in: app)
        XCTAssertTrue(waitForWindowCount(in: app, atMost: max(windowCountBeforeDelete - 1, 0)))
    }
#endif

    private func launchApp(
        storeNamespace: String,
        seedCorruptSnapshot: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ISTICKIES_STORE_NAMESPACE"] = storeNamespace
        app.launchEnvironment["ISTICKIES_USE_LOCAL_CLOUD"] = "1"
        if seedCorruptSnapshot {
            app.launchEnvironment["ISTICKIES_SEED_CORRUPT_STORE"] = "1"
        }
        app.launch()
        return app
    }

    private func uniqueStoreNamespace() -> String {
        "ui_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

    private func waitForEditor(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
#if !os(macOS)
        let existingEditor = app.textViews["StickyNotes.noteEditor"].firstMatch
        if !existingEditor.waitForExistence(timeout: 2) {
            let addButton = app.buttons["StickyNotes.addNoteButton"].firstMatch
            XCTAssertTrue(addButton.waitForExistence(timeout: 5), file: file, line: line)
            activate(addButton)
        }
#endif

        let editor = app.textViews["StickyNotes.noteEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 6), file: file, line: line)
        return editor
    }

    private func focus(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }

    private func waitForEditorText(
        _ text: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            let editor = app.textViews["StickyNotes.noteEditor"].firstMatch
            guard editor.exists else { return false }
            return (editor.value as? String)?.contains(text) == true
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func deleteCurrentNote(in app: XCUIApplication) {
#if os(macOS)
        let stickiesMenu = app.menuBars.menuBarItems["Stickies"]
        if stickiesMenu.waitForExistence(timeout: 2) {
            stickiesMenu.click()
            let deleteMenuItem = app.menuItems["Delete Current Note"].firstMatch
            XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 2))
            deleteMenuItem.click()
        } else {
            app.typeKey(.delete, modifierFlags: [.command])
        }

        let deleteButton = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 4))
        deleteButton.click()
#else
        let doneButton = app.buttons["StickyNotes.doneEditingButton"].firstMatch
        if doneButton.waitForExistence(timeout: 2) {
            doneButton.tap()
        }

        let card = app.otherElements["StickyNotes.noteCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 4))
        card.press(forDuration: 1.0)

        let deleteButton = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 4))
        deleteButton.tap()
#endif
    }

    private func waitForSnapshotPersistence() {
        Thread.sleep(forTimeInterval: 0.8)
    }

#if os(macOS)
    private func waitForWindowCount(
        in app: XCUIApplication,
        atLeast count: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        waitForWindowCount(in: app, timeout: timeout) { $0 >= count }
    }

    private func waitForWindowCount(
        in app: XCUIApplication,
        atMost count: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        waitForWindowCount(in: app, timeout: timeout) { $0 <= count }
    }

    private func waitForWindowCount(
        in app: XCUIApplication,
        timeout: TimeInterval,
        matches predicate: @escaping (Int) -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate(app.windows.count) },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
#endif
}
