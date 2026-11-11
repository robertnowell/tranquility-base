import XCTest
@testable import TranquilityCore

/// The table moved out of this binary and into ~/.claude/hq-themes.json so that
/// a page author, the indexer and the app can all ask the same question and get
/// the same answer. Two things have to hold for that to be worth anything:
/// the file must actually be read, and it must be impossible for a bad file to
/// leave a hub with no theme.
///
/// Fixtures verify both the compiled fallback and intentional file overrides.
/// The operator's personal theme file is never a test input.
final class ThemeFileTests: XCTestCase {

    private var dir: String = ""
    private var previousThemePath: String?

    override func setUp() {
        super.setUp()
        previousThemePath = ProcessInfo.processInfo.environment["HQ_THEMES"]
        dir = NSTemporaryDirectory() + "tb-theme-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        setenv("HQ_THEMES", dir + "/does-not-exist.json", 1)
    }

    override func tearDown() {
        if let previousThemePath { setenv("HQ_THEMES", previousThemePath, 1) }
        else { unsetenv("HQ_THEMES") }
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

    /// User configuration is an override, not an immutable shipped fixture.
    /// Exercise real file parsing for every theme without reading the operator's file.
    func testConfiguredThemesAndPaletteOverrideTheCompiledDefaults() throws {
        write("""
        {"themes":{
          "editorial":{"nameplate":"Fixture House","accent":"#102030","has_dark":false},
          "kopi":{"heading":"#AABBCC","serif":"Fixture Serif","sans":"Fixture Sans","font_sheet":"fixture.css"},
          "mirai":{"nameplate":"Fixture Mirai","bg":"#eeeeee"}
        },"agent_inks":["#112233","#445566"]}
        """)
        XCTAssertEqual(HomeBase.Theme.editorial.nameplate, "Fixture House")
        XCTAssertEqual(HomeBase.Theme.editorial.accent, "#102030")
        XCTAssertFalse(HomeBase.Theme.editorial.hasDark)
        XCTAssertEqual(HomeBase.Theme.kopi.heading, "#AABBCC")
        XCTAssertEqual(HomeBase.Theme.kopi.serif, "Fixture Serif")
        XCTAssertEqual(HomeBase.Theme.kopi.sans, "Fixture Sans")
        XCTAssertEqual(HomeBase.Theme.kopi.fontSheet, "fixture.css")
        XCTAssertEqual(HomeBase.Theme.mirai.nameplate, "Fixture Mirai")
        XCTAssertEqual(HomeBase.Theme.mirai.bg, "#eeeeee")
        XCTAssertEqual(HomeBase.Theme.agentInks, ["#112233", "#445566"])
        XCTAssertEqual(HomeBase.Theme.editorial.paper, HomeBase.Theme.builtInEditorial.paper)
    }
}
