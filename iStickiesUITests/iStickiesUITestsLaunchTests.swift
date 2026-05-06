import XCTest

final class iStickiesUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsUsableInitialState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISTICKIES_STORE_NAMESPACE"] = uniqueStoreNamespace()
        app.launchEnvironment["ISTICKIES_USE_LOCAL_CLOUD"] = "1"
        app.launch()

#if os(macOS)
        XCTAssertTrue(app.textViews["StickyNotes.noteEditor"].firstMatch.waitForExistence(timeout: 6))
#else
        XCTAssertTrue(app.staticTexts["No Notes"].waitForExistence(timeout: 6))
#endif

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func uniqueStoreNamespace() -> String {
        "launch_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }
}
