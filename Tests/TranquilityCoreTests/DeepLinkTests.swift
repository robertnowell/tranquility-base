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
        XCTAssertEqual(DeepLink.subject(from: "/tmp/plan.html", exists: always),
                       .file("/tmp/plan.html"))
    }

    /// The load-bearing check: a page can write any string into a URL, but it
    /// cannot put a file on your disk.
    func testAPathThatIsNotOnDiskIsRefused() {
        XCTAssertNil(DeepLink.subject(from: "/tmp/nope.html", exists: never))
    }

    func testQuotesAndEscapesAreRefusedEvenWhenTheFileExists() {
        for hostile in ["/tmp/a';rm -rf ~;'.html",
                        "/tmp/a\".html",
                        "/tmp/a\\.html",
                        "/tmp/`whoami`.html",
                        "/tmp/$HOME.html"] {
            XCTAssertNil(DeepLink.subject(from: hostile, exists: always),
                         "accepted \(hostile)")
        }
    }

    /// The only forbidden character that can arrive invisibly, and the one that
    /// would end the command and start another.
    func testANewlineIsRefused() {
        XCTAssertNil(DeepLink.subject(from: "/tmp/a\nrm -rf ~\n.html", exists: always))
    }

    /// The app's working directory is wherever it was launched from, which is
    /// not where the page lives — a relative path names something else.
    func testRelativePathsAreRefused() {
        XCTAssertNil(DeepLink.subject(from: "../../etc/passwd", exists: always))
        XCTAssertNil(DeepLink.subject(from: "plan.html", exists: always))
    }

    func testTildeExpandsAgainstHome() {
        XCTAssertEqual(
            DeepLink.subject(from: "~/Documents/p.html", home: "/Users/x", exists: always),
            .file("/Users/x/Documents/p.html"))
    }

    func testNothingNamedIsRefused() {
        XCTAssertNil(DeepLink.subject(from: nil, exists: always))
        XCTAssertNil(DeepLink.subject(from: "", exists: always))
    }

    /// A space is ordinary in a macOS path and must NOT be refused — the
    /// negative case for the refusal rules above. It is safe because the whole
    /// prompt is single-quoted.
    func testAnOrdinaryPathWithSpacesIsAccepted() {
        XCTAssertEqual(
            DeepLink.subject(from: "/Users/x/Deep Research/plan.html", exists: always),
            .file("/Users/x/Deep Research/plan.html"))
        let prompt = DeepLink.openingPrompt(for: .file("/Users/x/Deep Research/plan.html"))
        XCTAssertNotNil(DeepLink.openingCommand(base: "claude", prompt: prompt))
    }

    // MARK: - The command

    func testTheCommandQuotesTheWholePrompt() {
        let prompt = DeepLink.openingPrompt(for: .file("/tmp/plan.html"))
        let command = DeepLink.openingCommand(base: "claude --x", prompt: prompt)
        XCTAssertEqual(command, "claude --x '\(prompt)'")
        XCTAssertTrue(command!.contains("/tmp/plan.html"))
    }

    /// Belt to the artifact check's braces: even if a hostile string reached
    /// the prompt by some other route, no command is built from it.
    func testNoCommandIsBuiltFromAHostilePrompt() {
        XCTAssertNil(DeepLink.openingCommand(base: "claude", prompt: "go '; rm -rf ~; '"))
    }

    // MARK: - The hosted case

    /// A page someone else published names its own address, because its footer
    /// has been stripped of any local path. This is the whole public loop.
    func testAHostedPageNamesItsOwnURL() {
        XCTAssertEqual(
            DeepLink.subject(from: "https://hq-rendition.vercel.app/2026-08-10-plan/",
                             exists: never),
            .page("https://hq-rendition.vercel.app/2026-08-10-plan/"))
    }

    /// A URL cannot be checked for existence, so it is constrained by shape.
    func testOnlyHttpsAndOnlyWithAHost() {
        for bad in ["http://example.com/p",           // plaintext
                    "https://",                        // no host
                    "file:///etc/passwd",
                    "javascript:alert(1)",
                    "data:text/html,<script>",
                    "ftp://example.com/x"] {
            XCTAssertNil(DeepLink.subject(from: bad, exists: always), "accepted \(bad)")
        }
    }

    /// A URL carrying a password does not belong in a card, a command line, or
    /// the clipboard — and the invitation puts it in all three.
    func testCredentialsInAURLAreRefused() {
        XCTAssertNil(DeepLink.subject(from: "https://user:pw@example.com/p", exists: never))
    }

    func testAnAbsurdlyLongURLIsRefused() {
        let long = "https://example.com/" + String(repeating: "a", count: 4000)
        XCTAssertNil(DeepLink.subject(from: long, exists: never))
    }

    /// The hosted case opens at home: the page belongs to no directory here.
    func testAHostedPageStartsAtHome() {
        let subject = DeepLink.subject(from: "https://example.com/a/plan/", exists: never)
        XCTAssertEqual(subject?.directory, NSHomeDirectory())
        XCTAssertEqual(subject?.name, "example.com/plan")
    }

    func testTheHostedCommandIsStillQuoted() {
        let prompt = DeepLink.openingPrompt(for: .page("https://example.com/p/"))
        let command = DeepLink.openingCommand(base: "claude", prompt: prompt)
        XCTAssertEqual(command, "claude '\(prompt)'")
    }
}
