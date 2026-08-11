import XCTest
@testable import TranquilityCore

/// Focusing a tab is a convenience; opening one is the contract. So every case
/// here is about the fallback being taken — a wrong `.focused` means the user
/// clicked and nothing appeared.
final class BrowserFocusTests: XCTestCase {

    private let page = URL(fileURLWithPath: "/Users/x/Documents/agents/489b4804/index.html")

    func testAMatchFocuses() {
        XCTAssertEqual(BrowserFocus.focusExistingTab(page) { _ in .success("true") },
                       .focused)
    }

    func testNoMatchFallsBack() {
        XCTAssertEqual(BrowserFocus.focusExistingTab(page) { _ in .success("false") },
                       .notFound)
    }

    /// Automation denied (-1743), Chrome quit mid-script, osascript missing —
    /// all one answer, and never an error the user has to dismiss.
    func testAnyScriptFailureFallsBack() {
        XCTAssertEqual(
            BrowserFocus.focusExistingTab(page) { _ in
                .failure(ScriptError(message: "Not authorized to send Apple events"))
            }, .notFound)
    }

    /// The script asks whether Chrome is running rather than telling it
    /// anything, because `tell application` would launch a browser the user had
    /// closed just to look for a tab.
    func testTheScriptNeverLaunchesChrome() {
        let script = BrowserFocus.script(for: page)
        XCTAssertTrue(script.hasPrefix("if application \"Google Chrome\" is running"))
    }

    /// A file URL can carry a quote or a backslash; an AppleScript literal
    /// cannot. Unescaped, the script does not fail — it fails to compile, which
    /// reads as "no tab found" forever.
    func testQuotesAndBackslashesAreEscaped() {
        let hostile = URL(fileURLWithPath: "/tmp/a\"b\\c/index.html")
        let script = BrowserFocus.script(for: hostile)
        XCTAssertFalse(script.contains("a\"b"))
        XCTAssertTrue(script.contains("\\\""))
    }

    /// Chrome reports a percent-encoded URL for a path with spaces; a page
    /// opened by hand may not. Both forms are compared.
    func testBothEncodedAndDecodedFormsAreMatched() {
        let spaced = URL(fileURLWithPath: "/Users/x/Deep Research/plan/index.html")
        let script = BrowserFocus.script(for: spaced)
        XCTAssertTrue(script.contains("Deep%20Research"))
        XCTAssertTrue(script.contains("Deep Research"))
    }
}
