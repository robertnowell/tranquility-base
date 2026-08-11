import XCTest
@testable import TranquilityCore

/// The app's only inbound surface from the open web.
///
/// Every case here is about which way it fails. A false NEGATIVE costs a
/// clipboard fallback or a card that says "nothing to open" — a shrug. A false
/// POSITIVE hands a string a stranger wrote to a shell, or opens a microphone
/// because a page asked. So the refusals are the tests; the happy path gets
/// one case and the refusals get eleven.
final class DeepLinkTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }
    private let always: (String) -> Bool = { _ in true }
    private let never: (String) -> Bool = { _ in false }

    // MARK: - Parsing

    func testDiscussCarriesSessionAndRef() {
        XCTAssertEqual(
            DeepLink.parse(url("tranquilitybase://discuss?session=abc&ref=/tmp/p.html")),
            .discuss(session: "abc", ref: "/tmp/p.html"))
    }

    /// The rename must not strand pages already on disk.
    func testBothSchemesMeanTheSameThing() {
        XCTAssertEqual(DeepLink.parse(url("voicedispatch://discuss?session=abc")),
                       DeepLink.parse(url("tranquilitybase://discuss?session=abc")))
    }

    func testTheOtherActionsStillParse() {
        XCTAssertEqual(DeepLink.parse(url("tranquilitybase://hear?session=a")), .hear(session: "a"))
        XCTAssertEqual(DeepLink.parse(url("tranquilitybase://reply?session=a")), .reply(session: "a"))
        XCTAssertEqual(DeepLink.parse(url("tranquilitybase://show")), .show)
        XCTAssertEqual(DeepLink.parse(url("tranquilitybase://launch?cmd=x")), .unknown("launch"))
    }

    /// An empty value is the same as no value: `?session=` must not resolve to
    /// a session named "".
    func testEmptyParametersAreAbsent() {
        XCTAssertEqual(DeepLink.parse(url("tranquilitybase://discuss?session=&ref=")),
                       .discuss(session: nil, ref: nil))
    }

    // MARK: - The artifact, which is where a shell is downstream

    func testAnExistingAbsolutePathSurvives() {
        XCTAssertEqual(DeepLink.artifact(from: "/tmp/plan.html", exists: always),
                       "/tmp/plan.html")
    }

    /// The load-bearing check: a page can write any string into a URL, but it
    /// cannot put a file on your disk.
    func testAPathThatIsNotOnDiskIsRefused() {
        XCTAssertNil(DeepLink.artifact(from: "/tmp/nope.html", exists: never))
    }

    func testQuotesAndEscapesAreRefusedEvenWhenTheFileExists() {
        for hostile in ["/tmp/a';rm -rf ~;'.html",
                        "/tmp/a\".html",
                        "/tmp/a\\.html",
                        "/tmp/`whoami`.html",
                        "/tmp/$HOME.html"] {
            XCTAssertNil(DeepLink.artifact(from: hostile, exists: always),
                         "accepted \(hostile)")
        }
    }

    /// The only forbidden character that can arrive invisibly, and the one that
    /// would end the command and start another.
    func testANewlineIsRefused() {
        XCTAssertNil(DeepLink.artifact(from: "/tmp/a\nrm -rf ~\n.html", exists: always))
    }

    /// The app's working directory is wherever it was launched from, which is
    /// not where the page lives — a relative path names something else.
    func testRelativePathsAreRefused() {
        XCTAssertNil(DeepLink.artifact(from: "../../etc/passwd", exists: always))
        XCTAssertNil(DeepLink.artifact(from: "plan.html", exists: always))
    }

    func testTildeExpandsAgainstHome() {
        XCTAssertEqual(
            DeepLink.artifact(from: "~/Documents/p.html", home: "/Users/x", exists: always),
            "/Users/x/Documents/p.html")
    }

    func testNothingNamedIsRefused() {
        XCTAssertNil(DeepLink.artifact(from: nil, exists: always))
        XCTAssertNil(DeepLink.artifact(from: "", exists: always))
    }

    /// A space is ordinary in a macOS path and must NOT be refused — the
    /// negative case for the refusal rules above. It is safe because the whole
    /// prompt is single-quoted.
    func testAnOrdinaryPathWithSpacesIsAccepted() {
        XCTAssertEqual(
            DeepLink.artifact(from: "/Users/x/Deep Research/plan.html", exists: always),
            "/Users/x/Deep Research/plan.html")
        let prompt = DeepLink.openingPrompt(for: "/Users/x/Deep Research/plan.html")
        XCTAssertNotNil(DeepLink.openingCommand(base: "claude", prompt: prompt))
    }

    // MARK: - The command

    func testTheCommandQuotesTheWholePrompt() {
        let prompt = DeepLink.openingPrompt(for: "/tmp/plan.html")
        let command = DeepLink.openingCommand(base: "claude --x", prompt: prompt)
        XCTAssertEqual(command, "claude --x '\(prompt)'")
        XCTAssertTrue(command!.contains("/tmp/plan.html"))
    }

    /// Belt to the artifact check's braces: even if a hostile string reached
    /// the prompt by some other route, no command is built from it.
    func testNoCommandIsBuiltFromAHostilePrompt() {
        XCTAssertNil(DeepLink.openingCommand(base: "claude", prompt: "go '; rm -rf ~; '"))
    }
}
