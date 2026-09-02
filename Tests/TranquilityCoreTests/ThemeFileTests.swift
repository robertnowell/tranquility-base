import XCTest
@testable import TranquilityCore

/// The table moved out of this binary and into ~/.claude/hq-themes.json so that
/// a page author, the indexer and the app can all ask the same question and get
/// the same answer. Two things have to hold for that to be worth anything:
/// the file must actually be read, and it must be impossible for a bad file to
/// leave a hub with no theme.
///
/// The first test is the one that earns its keep. It asserts the shipped file
/// and the compiled fallback agree field by field, which is the only way to know
/// the extraction was faithful rather than approximately faithful.
final class ThemeFileTests: XCTestCase {

    private var dir: String = ""

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "tb-theme-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        unsetenv("HQ_THEMES")
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func write(_ json: String) {
        let p = dir + "/themes.json"
        try? json.write(toFile: p, atomically: true, encoding: .utf8)
        setenv("HQ_THEMES", p, 1)
    }

    /// A file that is not there is the common case on any machine but this one.
    func testNoFileMeansTheCompiledTable() {
        setenv("HQ_THEMES", dir + "/does-not-exist.json", 1)
        XCTAssertEqual(HomeBase.Theme.editorial, HomeBase.Theme.builtInEditorial)
        XCTAssertEqual(HomeBase.Theme.kopi, HomeBase.Theme.builtInKopi)
        XCTAssertEqual(HomeBase.Theme.agentInks, HomeBase.Theme.builtInAgentInks)
    }

    /// Half a file is worse than none, so it is treated as none.
    func testMalformedFileMeansTheCompiledTable() {
        write("{ this is not json")
        XCTAssertEqual(HomeBase.Theme.editorial, HomeBase.Theme.builtInEditorial)
        XCTAssertEqual(HomeBase.Theme.agentInks, HomeBase.Theme.builtInAgentInks)
    }

    /// The file wins, and only for what it actually says.
    func testTheFileOverridesFieldByField() {
        write("{\"themes\":{\"editorial\":{\"accent\":\"#000fff\"}}}")
        XCTAssertEqual(HomeBase.Theme.editorial.accent, "#000fff")
        XCTAssertEqual(HomeBase.Theme.editorial.serif,
                       HomeBase.Theme.builtInEditorial.serif,
                       "a key the file does not mention keeps its compiled value")
        XCTAssertEqual(HomeBase.Theme.editorial.nameplate,
                       HomeBase.Theme.builtInEditorial.nameplate)
    }

    /// A colour that is not a string is not a colour.
    func testWrongTypesFallBackRatherThanCrash() {
        write("{\"themes\":{\"editorial\":{\"accent\":42,\"bg\":\"\"}}}")
        XCTAssertEqual(HomeBase.Theme.editorial.accent,
                       HomeBase.Theme.builtInEditorial.accent)
        XCTAssertEqual(HomeBase.Theme.editorial.bg, HomeBase.Theme.builtInEditorial.bg)
    }

    /// A palette with a hole in it would give some agents a colour and others
    /// nothing, and which agents depends on a hash. Refuse the whole list.
    func testAPartialPaletteIsRefusedWhole() {
        write("{\"agent_inks\":[\"#111111\", 7, \"#222222\"]}")
        XCTAssertEqual(HomeBase.Theme.agentInks, HomeBase.Theme.builtInAgentInks)
        write("{\"agent_inks\":[\"#111111\",\"#222222\"]}")
        XCTAssertEqual(HomeBase.Theme.agentInks, ["#111111", "#222222"])
    }

    /// The ink is still derived, and still from the palette in force.
    func testTheInkStillComesFromTheDerivation() {
        write("{\"agent_inks\":[\"#111111\",\"#222222\"]}")
        let a = HomeBase.Theme.editorial.forAgent(sessionId: "abc").accent
        let b = HomeBase.Theme.editorial.forAgent(sessionId: "abc").accent
        XCTAssertEqual(a, b, "the same agent is the same colour, always")
        XCTAssertTrue(["#111111", "#222222"].contains(a))
    }

    /// A brand keeps its own accent: an agent is not an identity.
    func testABrandThemeIgnoresTheAgentInk() {
        XCTAssertEqual(HomeBase.Theme.kopi.forAgent(sessionId: "abc").accent,
                       HomeBase.Theme.kopi.accent)
    }

    /// THE ONE THAT MATTERS: the shipped file says exactly what the binary says.
    /// If this fails, the extraction was wrong and every page an author styles
    /// from the file disagrees with the hub the app renders.
    func testTheShippedFileMatchesTheCompiledTable() throws {
        let shipped = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hq-themes.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shipped.path),
                          "no hq-themes.json on this machine")
        setenv("HQ_THEMES", shipped.path, 1)
        XCTAssertEqual(HomeBase.Theme.editorial, HomeBase.Theme.builtInEditorial)
        XCTAssertEqual(HomeBase.Theme.kopi, HomeBase.Theme.builtInKopi)
        XCTAssertEqual(HomeBase.Theme.mirai, HomeBase.Theme.builtInMirai)
        XCTAssertEqual(HomeBase.Theme.agentInks, HomeBase.Theme.builtInAgentInks)
    }
}
