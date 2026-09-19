import XCTest

/// End-to-end tests that prove PagePocket really renders and runs local HTML.
///
/// These deliberately assert on things that only hold if the whole pipeline
/// works — the loopback server bound a port, the file was served with a
/// JavaScript MIME type, and WebKit executed the page's scripts. A viewer that
/// merely shoved the file into the web view would fail several of these.
final class PagePocketUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Launches the app, optionally opening a bundled document by name.
    @discardableResult
    private func launchApp(opening document: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let document {
            app.launchArguments += ["-AutoOpenDocument", document]
        }
        app.launch()
        return app
    }

    /// Waits for the web view to exist and return its accessibility labels.
    private func webViewLabels(_ app: XCUIApplication, timeout: TimeInterval = 45) -> [String] {
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: timeout) else { return [] }
        return webView.descendants(matching: .any)
            .allElementsBoundByIndex
            .compactMap { $0.label.isEmpty ? nil : $0.label }
    }

    /// Polls until `condition` holds, so tests do not depend on fixed sleeps.
    private func waitUntil(
        timeout: TimeInterval = 30,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return condition()
    }

    // MARK: - Library

    func testLibraryImportsBundledSamples() throws {
        let app = launchApp()

        XCTAssertTrue(
            app.staticTexts["PagePocket"].waitForExistence(timeout: 20),
            "The library screen should appear on launch."
        )

        // Both samples ship in the bundle and should be seeded on first run.
        let welcome = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Welcome")
        ).firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout: 20),
                      "The bundled Welcome sample should be imported.")

        let playground = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Playground")
        ).firstMatch
        XCTAssertTrue(playground.waitForExistence(timeout: 20),
                      "The bundled Playground sample should be imported.")
    }

    // MARK: - Rendering

    func testDocumentRendersHTML() throws {
        let app = launchApp(opening: "Welcome")

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 45),
                      "A web view should appear after opening a document.")

        // This copy comes straight from the sample's markup, so it only appears
        // if the file was located, served and parsed.
        XCTAssertTrue(
            waitUntil { self.webViewLabels(app).contains { $0.contains("Your HTML, running natively.") } },
            "The document's own text should be rendered. Labels: \(webViewLabels(app))"
        )
    }

    /// The capability list is built by JavaScript, and one of its entries is the
    /// result of a `fetch()` against the local server. Both must pass.
    func testJavaScriptAndFetchWorkAgainstLocalServer() throws {
        let app = launchApp(opening: "Welcome")

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 45))

        XCTAssertTrue(
            waitUntil(timeout: 40) {
                self.webViewLabels(app).contains { $0.contains("JavaScript") && $0.contains("running") }
            },
            "JavaScript should be executing in the page."
        )

        XCTAssertTrue(
            waitUntil(timeout: 40) {
                self.webViewLabels(app).contains { $0.contains("fetch() same-origin") && $0.contains("ok") }
            },
            """
            fetch() against the local server should succeed. This is the core \
            claim of the app: a file:// document cannot do this. \
            Labels: \(webViewLabels(app))
            """
        )
    }

    // MARK: - Interaction

    /// The real proof of interactivity: tap a button inside the page and assert
    /// the DOM updated in response.
    func testTappingInPageUpdatesTheDOM() throws {
        let app = launchApp(opening: "Welcome")

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 45))

        // Give the page a moment to finish wiring up its listeners.
        XCTAssertTrue(
            waitUntil(timeout: 40) {
                self.webViewLabels(app).contains { $0.contains("Tapped 0 times") }
            },
            "The counter button should be present in its initial state. Labels: \(webViewLabels(app))"
        )

        let button = webView.buttons["Tapped 0 times"]
        XCTAssertTrue(button.waitForExistence(timeout: 20),
                      "The counter button should be reachable as a web button.")
        button.tap()

        XCTAssertTrue(
            waitUntil(timeout: 20) {
                self.webViewLabels(app).contains { $0.contains("Tapped 1 time") }
            },
            """
            Tapping the page's button should run its JavaScript and update the label. \
            Labels: \(webViewLabels(app))
            """
        )
    }

    /// The Playground sample imports real ES modules, which only load if the
    /// server sends a JavaScript MIME type.
    func testESModulesLoadFromLocalServer() throws {
        let app = launchApp(opening: "Playground")

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 45))

        XCTAssertTrue(
            waitUntil(timeout: 40) {
                let labels = self.webViewLabels(app)
                return labels.contains { $0.contains("geometry module loaded") }
            },
            """
            ES modules should load. `file://` blocks module loading entirely, so \
            this passing means the local server is sending a JS MIME type. \
            Labels: \(webViewLabels(app))
            """
        )
    }

    // MARK: - Chrome

    func testConsoleCapturesPageOutput() throws {
        let app = launchApp(opening: "Welcome")

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 45))

        // The sample logs on startup; give it a moment to arrive over the bridge.
        XCTAssertTrue(
            waitUntil(timeout: 30) {
                self.webViewLabels(app).contains { $0.contains("Live capability check") }
            },
            "The page should finish loading before opening the console."
        )

        let consoleButton = app.buttons["browser.console"]
        XCTAssertTrue(consoleButton.waitForExistence(timeout: 20),
                      "The console button should exist in the browser toolbar.")
        consoleButton.tap()

        XCTAssertTrue(
            app.staticTexts["Console"].waitForExistence(timeout: 20),
            "The console sheet should open."
        )

        // The sample calls console.log during startup.
        XCTAssertTrue(
            waitUntil(timeout: 25) {
                app.staticTexts.allElementsBoundByIndex.contains {
                    $0.label.contains("Browser")
                }
            },
            "The console should show output logged by the page."
        )
    }
}
