import XCTest

/// Drives the paste flow through the real UI, so the feature is proven
/// end-to-end rather than only at the model layer.
final class PasteFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPastingMarkupRunsIt() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITests"]
        app.launch()

        XCTAssertTrue(app.staticTexts["PagePocket"].waitForExistence(timeout: 40),
                      "Library should appear.")

        // Add -> Paste HTML
        app.buttons["library.add"].tap()
        let pasteItem = app.buttons["Paste HTML"]
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 15), "The Add menu should offer Paste HTML.")
        pasteItem.tap()

        XCTAssertTrue(app.staticTexts["Paste HTML"].waitForExistence(timeout: 15),
                      "The paste sheet should open.")

        // Type markup into the editor. Type slowly enough for the editor to keep up.
        let editor = app.textViews["paste.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "The editor should be present.")
        editor.tap()

        let marker = "PASTED-MARKER-\(Int(Date().timeIntervalSince1970) % 100000)"
        editor.typeText("<html><body><h1>\(marker)</h1></body></html>")

        // Run it.
        app.buttons["Run"].tap()

        // The library should navigate into the rendered page.
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 60),
                      "Running a paste should open the rendered document.")

        // The marker must appear as rendered text, proving the markup executed.
        let rendered = webView.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", marker))
            .firstMatch
        XCTAssertTrue(rendered.waitForExistence(timeout: 40),
                      "The pasted markup should be rendered. Saw: \(webView.staticTexts.allElementsBoundByIndex.filter { $0.exists }.map(\.label).prefix(12))")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "pasted-render"; shot.lifetime = .keepAlways; add(shot)
    }

    /// The document created by a paste must be a normal library entry that can be
    /// reopened later, not a transient preview.
    func testPastedDocumentPersistsInLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITests"]
        app.launch()
        XCTAssertTrue(app.staticTexts["PagePocket"].waitForExistence(timeout: 40))

        app.buttons["library.add"].tap()
        app.buttons["Paste HTML"].tap()
        XCTAssertTrue(app.staticTexts["Paste HTML"].waitForExistence(timeout: 15))

        let editor = app.textViews["paste.editor"]
        editor.tap()
        editor.typeText("<html><head><title>Persisted Paste</title></head><body>p</body></html>")

        // Give it a name so the assertion is unambiguous.
        let nameField = app.textFields.firstMatch
        if nameField.exists {
            nameField.tap()
            nameField.typeText("Persisted Paste")
        }

        app.buttons["Run"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60))

        // Back to the library and confirm the entry is listed.
        app.navigationBars.buttons.firstMatch.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        let row = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Persisted Paste"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "A pasted document should persist as a library entry.")
    }
}
