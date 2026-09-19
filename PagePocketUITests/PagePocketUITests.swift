import XCTest
import UIKit

/// End-to-end tests that prove PagePocket really renders and runs local HTML.
///
/// These deliberately assert on things that only hold if the whole pipeline
/// works — the loopback server bound a port, the file was served with a
/// JavaScript MIME type, and WebKit executed the page's scripts. A viewer that
/// merely shoved the file into the web view would fail several of these.
///
/// Query style: predicates with `waitForExistence`, never
/// `allElementsBoundByIndex`. The Playground page animates continuously, so an
/// index-based snapshot goes stale between the query and the read.
final class PagePocketUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Launches the app, optionally opening a bundled document by name.
    @discardableResult
    private func launchApp(opening document: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        // Tells the app to disable animations, which keeps accessibility
        // snapshots stable while a page is drawing.
        app.launchArguments += ["-UITests"]
        if let document {
            app.launchArguments += ["-AutoOpenDocument", document]
        }
        app.launch()
        return app
    }

    /// Waits for the web view to finish loading into the hierarchy.
    @discardableResult
    private func awaitWebView(_ app: XCUIApplication, timeout: TimeInterval = 60) -> XCUIElement {
        let webView = app.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: timeout),
            "A web view should appear after opening a document."
        )
        return webView
    }

    /// Waits for any element inside the web view whose label contains `text`.
    ///
    /// Uses a lazily-evaluated predicate query so the element is re-resolved on
    /// every poll, which keeps working while the page is still animating.
    private func waitForWebText(
        _ text: String,
        in webView: XCUIElement,
        timeout: TimeInterval = 45,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)

        // Try the common element types first, then fall back to a broad search.
        let candidates: [XCUIElementQuery] = [
            webView.staticTexts.matching(predicate),
            webView.buttons.matching(predicate),
            webView.descendants(matching: .any).matching(predicate)
        ]

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for query in candidates where query.firstMatch.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        // One last check so the failure message is accurate.
        return candidates.contains { $0.firstMatch.exists }
    }

    /// Everything the page currently exposes, used only to build failure messages.
    private func visibleWebText(_ webView: XCUIElement) -> String {
        let labels = webView.descendants(matching: .staticText)
            .allElementsBoundByIndex
            .compactMap { $0.exists ? $0.label : nil }
            .filter { !$0.isEmpty }
        return labels.prefix(40).joined(separator: " | ")
    }

    // MARK: - Library

    func testLibraryImportsBundledSamples() throws {
        let app = launchApp()

        XCTAssertTrue(
            app.staticTexts["PagePocket"].waitForExistence(timeout: 30),
            "The library screen should appear on launch."
        )

        // Both samples ship in the bundle and are seeded on first run.
        for name in ["Welcome", "Playground"] {
            let row = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS[c] %@", name))
                .firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: 30),
                "The bundled \(name) sample should be imported into the library."
            )
        }
    }

    // MARK: - Rendering

    func testDocumentRendersHTML() throws {
        let app = launchApp(opening: "Welcome")
        let webView = awaitWebView(app)

        // This copy comes straight from the sample's markup, so it only appears
        // if the file was located, served and parsed.
        XCTAssertTrue(
            waitForWebText("Your HTML, running natively", in: webView),
            "The document's own text should be rendered. Saw: \(visibleWebText(webView))"
        )
    }

    /// The capability list is built by JavaScript, and one of its entries is the
    /// result of a `fetch()` against the local server. Both must pass.
    func testJavaScriptAndFetchWorkAgainstLocalServer() throws {
        let app = launchApp(opening: "Welcome")
        let webView = awaitWebView(app)

        XCTAssertTrue(
            waitForWebText("JavaScript", in: webView),
            "JavaScript should be executing in the page. Saw: \(visibleWebText(webView))"
        )

        XCTAssertTrue(
            waitForWebText("fetch() same-origin", in: webView),
            """
            fetch() against the local server should run. A file:// document \
            cannot do this. Saw: \(visibleWebText(webView))
            """
        )

        // The check reports either "ok" or a failure reason; require success.
        XCTAssertTrue(
            waitForWebText("data.json ok", in: webView),
            """
            fetch('data.json') should have succeeded against the loopback \
            server. Saw: \(visibleWebText(webView))
            """
        )
    }

    // MARK: - Interaction

    /// The real proof of interactivity: tap a button inside the page and assert
    /// the DOM updated in response.
    func testTappingInPageUpdatesTheDOM() throws {
        let app = launchApp(opening: "Welcome")
        let webView = awaitWebView(app)

        let initial = webView.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Tapped 0 times"))
            .firstMatch

        XCTAssertTrue(
            initial.waitForExistence(timeout: 45),
            "The counter button should be present in its initial state. Saw: \(visibleWebText(webView))"
        )

        initial.tap()

        XCTAssertTrue(
            waitForWebText("Tapped 1 time", in: webView, timeout: 20),
            """
            Tapping the page's button should run its JavaScript and update the \
            label. Saw: \(visibleWebText(webView))
            """
        )
    }

    /// The Playground sample imports real ES modules, which only load if the
    /// server sends a JavaScript MIME type.
    func testESModulesLoadFromLocalServer() throws {
        let app = launchApp(opening: "Playground")
        let webView = awaitWebView(app)

        XCTAssertTrue(
            waitForWebText("geometry module loaded", in: webView),
            """
            ES modules should load. file:// blocks module loading entirely, so \
            this passing means the server is sending a JS MIME type. \
            Saw: \(visibleWebText(webView))
            """
        )
    }

    /// Web Workers are blocked under file://, so running one proves the page has
    /// a proper origin — and that the worker script is served correctly.
    func testWebWorkerRuns() throws {
        let app = launchApp(opening: "Playground")
        let webView = awaitWebView(app)

        let runButton = webView.buttons["Run worker"]
        XCTAssertTrue(
            runButton.waitForExistence(timeout: 45),
            "The worker button should be present. Saw: \(visibleWebText(webView))"
        )
        runButton.tap()

        // The worker counts primes below 300,000 and reports the total, so this
        // text only appears if the worker actually executed to completion.
        XCTAssertTrue(
            waitForWebText("Worker finished", in: webView, timeout: 60),
            """
            The Web Worker should run to completion. Saw: \(visibleWebText(webView))
            """
        )
        XCTAssertTrue(
            waitForWebText("largest", in: webView, timeout: 20),
            "The worker should report its result. Saw: \(visibleWebText(webView))"
        )
    }

    /// The canvas is drawn by the imported render module. Scrolling to it and
    /// sampling pixels is the only way to prove it actually painted, since a
    /// canvas exposes no accessibility text.
    func testCanvasRendersVisiblePixels() throws {
        let app = launchApp(opening: "Playground")
        let webView = awaitWebView(app)

        XCTAssertTrue(
            waitForWebText("Canvas animation", in: webView, timeout: 45),
            "The canvas section should exist. Saw: \(visibleWebText(webView))"
        )

        // Bring the canvas into view.
        webView.swipeUp()
        webView.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "playground-canvas"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Assert on the pixels: a rendered canvas contains far more distinct
        // colours than the flat panel background around it.
        let image = screenshot.image
        XCTAssertGreaterThan(image.size.width, 0, "Screenshot should have content.")

        // Sample the centre band of the screen, where the canvas now sits.
        let distinctColours = Self.countDistinctColours(in: image, verticalRange: 0.30...0.75)
        XCTAssertGreaterThan(
            distinctColours, 40,
            """
            The canvas should have painted a multi-colour rose curve. Only \
            \(distinctColours) distinct colours were found, which suggests the \
            canvas is blank.
            """
        )
    }

    /// Counts unique colours in a horizontal band of a screenshot.
    private static func countDistinctColours(
        in image: UIImage,
        verticalRange: ClosedRange<Double>
    ) -> Int {
        guard let cgImage = image.cgImage else { return 0 }

        let width = cgImage.width
        let height = cgImage.height
        let y0 = Int(Double(height) * verticalRange.lowerBound)
        let y1 = Int(Double(height) * verticalRange.upperBound)
        let bandHeight = max(1, y1 - y0)

        // Downsample to keep this fast: one pixel every few, across the band.
        let sampleWidth = min(width, 200)
        let sampleHeight = min(bandHeight, 200)

        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }

        // Crop the band and draw it scaled down into the sample buffer.
        guard let band = cgImage.cropping(to: CGRect(x: 0, y: y0, width: width, height: bandHeight)) else {
            return 0
        }
        context.draw(band, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var seen = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = UInt32(pixels[index])
            let g = UInt32(pixels[index + 1])
            let b = UInt32(pixels[index + 2])
            seen.insert((r << 16) | (g << 8) | b)
        }
        return seen.count
    }

    // MARK: - Chrome

    func testConsoleCapturesPageOutput() throws {
        let app = launchApp(opening: "Welcome")
        let webView = awaitWebView(app)

        // Let the sample finish its startup logging before opening the console.
        XCTAssertTrue(
            waitForWebText("Your HTML, running natively", in: webView),
            "The page should render before the console is opened."
        )

        let consoleButton = app.buttons["browser.console"]
        XCTAssertTrue(
            consoleButton.waitForExistence(timeout: 20),
            "The console button should exist in the browser toolbar."
        )
        consoleButton.tap()

        XCTAssertTrue(
            app.staticTexts["Console"].waitForExistence(timeout: 20),
            "The console sheet should open."
        )

        // The sample logs this from JavaScript during startup; it can only be
        // here if the console bridge relayed it to native.
        let logged = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Welcome sample ready"))
            .firstMatch

        XCTAssertTrue(
            logged.waitForExistence(timeout: 30),
            "The console should show output logged by the page's JavaScript."
        )
    }
}
