import XCTest
@testable import TranquilityCore

final class AgentNamesTests: XCTestCase {

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-agent-names-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("agent-names.json")
    }

    // MARK: - The book

    func testAGivenNameIsFoundUnderTheIdAndUnderItsOrigin() {
        var book = AgentNameBook()
        let origin: (String) -> String = { $0 == "continuation" ? "first" : $0 }
        XCTAssertTrue(book.give("Folder namer", to: "continuation", source: .user, origin: origin))
        XCTAssertEqual(book.names.keys.sorted(), ["first"])
        XCTAssertEqual(book.name(for: "continuation", origin: origin), "Folder namer")
        XCTAssertEqual(book.name(for: "first", origin: origin), "Folder namer")
        XCTAssertNil(book.name(for: "somebody-else", origin: origin))
    }

    func testAnAutomaticNameNeverReplacesOneTheUserTyped() {
        var book = AgentNameBook()
        book.give("Mine", to: "a", source: .user)
        XCTAssertFalse(book.give("The model's", to: "a", source: .auto))
        XCTAssertEqual(book.name(for: "a"), "Mine")
        // The other three directions are all allowed.
        book.give("First guess", to: "b", source: .auto)
        XCTAssertTrue(book.give("Second guess", to: "b", source: .auto))
        XCTAssertTrue(book.give("Typed", to: "b", source: .user))
        XCTAssertTrue(book.give("Typed again", to: "b", source: .user))
        XCTAssertEqual(book.entry(for: "b"), .init(name: "Typed again", source: .user))
    }

    func testAnEmptyNameIsRefusedAndClearGoesBackToTheHarness() {
        var book = AgentNameBook()
        XCTAssertFalse(book.give("  \n ", to: "a", source: .user))
        XCTAssertNil(book.name(for: "a"))
        book.give("Kept", to: "a", source: .user)
        book.clear("a")
        XCTAssertNil(book.name(for: "a"))
    }

    func testANameIsOneShortLine() {
        XCTAssertEqual(AgentNameBook.tidy("  Rename\nfrom\tthe   grid "), "Rename from the grid")
        XCTAssertEqual(AgentNameBook.tidy(String(repeating: "x", count: 200)).count, AgentNameBook.maxLength)
    }

    func testRekeyFollowsAFork() {
        var book = AgentNameBook()
        book.give("Forked work", to: "old", source: .user)
        book.rekey(from: "old", to: "new")
        XCTAssertNil(book.name(for: "old"))
        XCTAssertEqual(book.name(for: "new"), "Forked work")
    }

    // MARK: - The store

    func testTheStoreSurvivesARelaunch() {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        AgentNameStore(url: url).update { $0.give("Survives", to: "s1", source: .user) }
        XCTAssertEqual(AgentNameStore(url: url).current.name(for: "s1"), "Survives")
        XCTAssertNotEqual(url, AgentNameStore.url)
    }

    // MARK: - The grid asks for it first

    func testAGivenNameOutranksTheHarnessTitleOnEverySurface() {
        let was = GridAssembler.givenNames
        defer { GridAssembler.givenNames = was }
        GridAssembler.givenNames = { $0 == "s1" ? "Typed on the grid" : nil }

        let live = LiveSession(pid: 1, sessionId: "s1", cwd: "/tmp/p", status: "idle",
                               name: "The harness title", waitingFor: nil)
        let other = LiveSession(pid: 2, sessionId: "s2", cwd: "/tmp/p", status: "idle",
                                name: "The harness title", waitingFor: nil)
        XCTAssertEqual(GridAssembler.tabDisplayName(live: live, callsign: "callsign"), "Typed on the grid")
        XCTAssertEqual(GridAssembler.tabDisplayName(discovered: "Disk title", sessionId: "s1",
                                                    callsign: nil, cwd: "/tmp/p"), "Typed on the grid")
        XCTAssertEqual(GridAssembler.harnessTitle(sessionId: "s1", transcriptPath: nil, live: live),
                       "Typed on the grid")
        // And only for the session it was given to.
        XCTAssertEqual(GridAssembler.tabDisplayName(live: other, callsign: "callsign"), "The harness title")
    }

    // MARK: - The handoff, read back

    func testAHandoffMessageIsReadBackIntoItsSourceAndTheInstruction() {
        let fragment = AgentHandoff.fragment(
            sourceName: "Summarize Mirai Clinical meeting", sourceHarness: "claude",
            sourceSessionId: "3b73608d-aaaa", directory: "/Users/x/Projects",
            logLocation: "/Users/x/.claude/projects/p/3b73608d.jsonl", reportsDirectory: "/Users/x/agents/3b")
        let sent = AttachmentTray.compose(transcript: "Make the renames after cloning better.",
                                          fragments: [fragment])
        let read = AgentHandoff.continuation(in: sent)
        XCTAssertEqual(read?.sourceName, "Summarize Mirai Clinical meeting")
        XCTAssertEqual(read?.sourceSessionId, "3b73608d-aaaa")
        XCTAssertEqual(read?.instruction, "Make the renames after cloning better.")
    }

    func testAHandoffSentAloneHasNoInstructionAndAnOrdinaryMessageIsNotOne() {
        let fragment = AgentHandoff.fragment(
            sourceName: "A \u{201C}quoted\u{201D} name", sourceHarness: "codex",
            sourceSessionId: "abc", logLocation: "/log", reportsDirectory: nil)
        let read = AgentHandoff.continuation(in: fragment)
        XCTAssertEqual(read?.sourceName, "A \u{201C}quoted\u{201D} name")
        XCTAssertEqual(read?.instruction, "")
        XCTAssertNil(AgentHandoff.continuation(in: "Please look at the folder namer."))
        XCTAssertNil(AgentHandoff.continuation(in: "First, a file.\n\n" + fragment))
    }

    // MARK: - The continued agent's name

    func testAReplyThatRepeatsANameInUseIsRefused() {
        let taken = ["YouVape email flows", "Mirai hero CTA font color"]
        XCTAssertNil(AgentNamer.clean("YouVape email flows", taken: taken))
        XCTAssertNil(AgentNamer.clean("youvape-email flows.", taken: taken))
        XCTAssertEqual(AgentNamer.clean("\"YouVape flow revenue by month\"", taken: taken),
                       "YouVape flow revenue by month")
        XCTAssertNil(AgentNamer.clean("Here is a name:\nYouVape flow revenue", taken: taken))
        XCTAssertNil(AgentNamer.clean("", taken: taken))
    }

    func testTheFallbackIsTheSourceNameWithTheLowestFreeNumber() {
        XCTAssertEqual(AgentNamer.fallback(sourceName: "Mirai flows", taken: ["Mirai flows"]), "Mirai flows 2")
        XCTAssertEqual(AgentNamer.fallback(sourceName: "Mirai flows", taken: ["Mirai flows", "mirai flows 2"]),
                       "Mirai flows 3")
        // A continuation of a continuation counts on, and does not stutter.
        XCTAssertEqual(AgentNamer.fallback(sourceName: "Mirai flows 2", taken: ["Mirai flows", "Mirai flows 2"]),
                       "Mirai flows 3")
    }

    func testThePromptSeparatesTheInstructionFromTheSourceName() {
        let text = AgentNamer.prompt(sourceName: "YouVape email flows",
                                     instruction: "Now work out the revenue per flow.",
                                     taken: ["YouVape email flows", "Mirai hero CTA font color"])
        XCTAssertTrue(text.contains("The earlier session is named: YouVape email flows"))
        XCTAssertTrue(text.contains("Other names in use: Mirai hero CTA font color"))
        XCTAssertTrue(text.hasSuffix("Now work out the revenue per flow."))
    }
}
