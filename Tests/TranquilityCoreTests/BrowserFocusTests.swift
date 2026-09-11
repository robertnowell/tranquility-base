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

    // MARK: - Staleness

    func testTheRaisedTabIsReloaded() {
        // "If the report has been updated since it was originally opened, it
        // opens the original tab" — raising the tab is right, showing the old
        // render of it is not. `openHub` rewrites the file immediately before
        // this runs, so the tab it raises is stale by construction.
        let page = URL(fileURLWithPath: "/tmp/agents/abc/index.html")
        let script = BrowserFocus.script(for: page)
        XCTAssertTrue(script.contains("reload tab t of window w"))
        // And the reload happens on the tab that MATCHED, after it has been
        // selected — not on whatever tab happened to be active.
        let selected = script.range(of: "set active tab index of window w to t")
        let reloaded = script.range(of: "reload tab t of window w")
        XCTAssertNotNil(selected)
        XCTAssertNotNil(reloaded)
        XCTAssertTrue(selected!.upperBound <= reloaded!.lowerBound)
    }

    func testAFinderCanStillDeclineToReload() {
        let page = URL(fileURLWithPath: "/tmp/agents/abc/index.html")
        XCTAssertFalse(BrowserFocus.script(for: page, reloading: false).contains("reload"))
    }

    // MARK: - The hub app's one tab

    private let app = URL(string: "https://hq.example.test")!
    private let door = URL(string: "https://hq.example.test/open?session=abc&slug=plan")!

    /// The door's address is never a tab's address (it redirects), so the
    /// match is on the app, not the page: any tab on the app is sent there.
    func testAnAppAddressReusesWhateverTabIsOnTheApp() {
        let script = BrowserFocus.navigateScript(to: door, within: app)
        XCTAssertTrue(script.contains("if u starts with \"https://hq.example.test/\""))
        XCTAssertTrue(script.contains("set URL of tab t of window w to \"https://hq.example.test/open?session=abc&slug=plan\""))
        XCTAssertFalse(script.contains("reload"), "the navigation is the reload")
        XCTAssertTrue(script.hasPrefix("if application \"Google Chrome\" is running"))
    }

    /// The prefix carries its slash so "https://hq.example.test.evil" is not the app.
    func testThePrefixEndsAtTheOrigin() {
        let script = BrowserFocus.navigateScript(to: door, within: app)
        XCTAssertTrue(script.contains("starts with \"https://hq.example.test/\""))
    }

    func testRevealRoutesAppAddressesToTheAppTabAndFilesToTheirOwn() {
        var seen: [String] = []
        let run: (String) -> Result<String, ScriptError> = { seen.append($0); return .success("true") }
        XCTAssertEqual(BrowserFocus.reveal(door, app: app, run: run), .focused)
        XCTAssertTrue(seen[0].contains("set URL of tab"))
        XCTAssertEqual(BrowserFocus.reveal(page, app: app, run: run), .focused)
        XCTAssertTrue(seen[1].contains("reload tab t of window w"))
        XCTAssertFalse(seen[1].contains("set URL of tab"))
    }

    func testNoAppTabFallsBack() {
        XCTAssertEqual(BrowserFocus.reveal(door, app: app) { _ in .success("false") }, .notFound)
        XCTAssertEqual(BrowserFocus.reveal(door, app: nil) { _ in .success("false") }, .notFound)
    }
}
