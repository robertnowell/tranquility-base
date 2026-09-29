import XCTest
@testable import TranquilityCore

/// Project folders, ruled 29 Sep 2026 (`docs/rulings/ruling-project-folders.md`).
/// Each test names the rule it pins.
final class ProjectFoldersTests: XCTestCase {

    private func row(_ id: String, _ lamp: Lamp, at seconds: TimeInterval? = nil) -> SessionRow {
        SessionRow(id: id, name: id, aux: id, lamp: lamp,
                   read: lamp == .ready ? .unread : .none, hasRecordedTurn: true,
                   lastActivity: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    private func book(_ folders: [(String, [String])], collapsed: Set<String> = []) -> ProjectBook {
        var book = ProjectBook()
        for (name, ids) in folders {
            book.create(name: name, with: ids, id: name.lowercased())
            if collapsed.contains(name) { book.setCollapsed(name.lowercased(), true) }
        }
        return book
    }

    private func shape(_ lines: [ProjectLayout.Line]) -> [String] {
        lines.map { line in
            switch line {
            case let .header(folder, lamp, lit, _):
                return "[\(folder.name)\(lamp.map { " \($0.trackName) \(lit)" } ?? "")]"
            case let .row(row, folder): return folder == nil ? row.id : "  " + row.id
            }
        }
    }

    // MARK: - Rules 1 and 2: folders on top, lamps inside

    func testFoldersSitAboveLooseRows() {
        let shown = SessionRow.quietRowsLast([row("loose1", .ready, at: 50), row("m1", .working, at: 10),
                                              row("loose2", .working, at: 40)])
        let lines = ProjectLayout.lines(shown, book: book([("Mirai", ["m1"])]))
        XCTAssertEqual(shape(lines), ["[Mirai]", "  m1", "loose1", "loose2"])
    }

    func testBlueDropsToTheBottomOfItsFolderNotOutOfIt() {
        let shown = SessionRow.quietRowsLast([row("a", .working, at: 90), row("b", .ready, at: 20),
                                              row("c", .ready, at: 30), row("x", .ready, at: 10)])
        let lines = ProjectLayout.lines(shown, book: book([("Kopi", ["a", "b", "c"])]))
        XCTAssertEqual(shape(lines), ["[Kopi]", "  c", "  b", "  a", "x"])
    }

    func testHearingARowStillDoesNotMoveItInsideAFolder() {
        let shown = [SessionRow(id: "read", name: "", aux: "", lamp: .ready, read: .opened, hasRecordedTurn: true),
                     SessionRow(id: "unread", name: "", aux: "", lamp: .ready, read: .unread, hasRecordedTurn: true)]
        let lines = ProjectLayout.lines(shown, book: book([("F", ["read", "unread"])]))
        XCTAssertEqual(lines.compactMap(\.row?.id), ["read", "unread"])
    }

    // MARK: - Rule 3: a folder with an ask rises

    func testAFolderWithAGreenLampRisesAboveTheUsersOrder() {
        let quiet = book([("First", ["q"]), ("Second", ["s"])])
        let bothWorking = SessionRow.quietRowsLast([row("q", .working, at: 5), row("s", .working, at: 9)])
        XCTAssertEqual(ProjectLayout.lines(bothWorking, book: quiet).compactMap(\.folder?.name),
                       ["First", "Second"], "no ask: the user's order")

        let secondAsks = SessionRow.quietRowsLast([row("q", .working, at: 5), row("s", .ready, at: 9)])
        XCTAssertEqual(ProjectLayout.lines(secondAsks, book: quiet).compactMap(\.folder?.name),
                       ["Second", "First"])
    }

    func testAmberAsksTooAndNewestAskerLeads() {
        let quiet = book([("A", ["a"]), ("B", ["b"]), ("C", ["c"])])
        let shown = SessionRow.quietRowsLast([row("a", .ready, at: 10), row("b", .fault, at: 30),
                                              row("c", .working, at: 99)])
        XCTAssertEqual(ProjectLayout.lines(shown, book: quiet).compactMap(\.folder?.name), ["B", "A", "C"])
    }

    func testAnsweredFolderFallsBackToItsPlace() {
        let quiet = book([("First", ["q"]), ("Second", ["s"])])
        let answered = SessionRow.quietRowsLast([row("q", .working, at: 5), row("s", .working, at: 9)])
        XCTAssertEqual(ProjectLayout.lines(answered, book: quiet).compactMap(\.folder?.name), ["First", "Second"])
    }

    func testDraggingAHeaderSetsTheOrderBeneathTheAskers() {
        var b = book([("First", ["q"]), ("Second", ["s"]), ("Third", ["t"])])
        b.move("third", to: "first", after: false)
        XCTAssertEqual(b.folders.map(\.name), ["Third", "First", "Second"])
        b.move("third", to: "second", after: true)
        XCTAssertEqual(b.folders.map(\.name), ["First", "Second", "Third"])
    }

    // MARK: - Rule 4: collapsed is one lamp and a count

    func testCollapsedFolderShowsItsMostUrgentLampAndLitCount() {
        let b = book([("TB", ["w", "g", "i"])], collapsed: ["TB"])
        let shown = SessionRow.quietRowsLast([row("w", .working, at: 50), row("g", .ready, at: 10),
                                              row("i", .running)])
        XCTAssertEqual(shape(ProjectLayout.lines(shown, book: b)), ["[TB ready 2]"])
    }

    func testCollapsedFolderWithOnlyBlueWearsBlue() {
        let b = book([("TB", ["w"])], collapsed: ["TB"])
        XCTAssertEqual(shape(ProjectLayout.lines([row("w", .working, at: 1)], book: b)), ["[TB working 1]"])
    }

    func testAnOpenHeaderWearsNoLamp() {
        let lines = ProjectLayout.lines([row("g", .ready, at: 1)], book: book([("F", ["g"])]))
        guard case let .header(_, lamp, _, _) = lines[0] else { return XCTFail("no header") }
        XCTAssertNil(lamp)
    }

    // MARK: - Rule 5: hide and wait

    func testAFolderWithNothingOnTheGridIsNotDrawnButSurvives() {
        let b = book([("Kopi", ["gone"])])
        XCTAssertEqual(shape(ProjectLayout.lines([row("x", .ready, at: 1)], book: b)), ["x"])
        XCTAssertNotNil(b.folder(id: "kopi"))
    }

    func testARevivedAgentLandsBackInItsFolder() {
        let b = book([("Kopi", ["k"])])
        XCTAssertEqual(shape(ProjectLayout.lines([row("k", .ready, at: 1)], book: b)), ["[Kopi]", "  k"])
    }

    func testMembershipFollowsAContinuationToItsOrigin() {
        var b = ProjectBook()
        let origin: (String) -> String = { $0 == "continued" ? "first" : $0 }
        b.create(name: "Mirai", with: ["first"], id: "m")
        XCTAssertEqual(b.folder(of: "continued", origin: origin)?.name, "Mirai")
    }

    func testDraggingTheLastAgentOutDeletesTheFolder() {
        var b = book([("Pair", ["a", "b"])])
        XCTAssertNil(b.leave("a"))
        XCTAssertNotNil(b.folder(id: "pair"))
        XCTAssertEqual(b.leave("b")?.name, "Pair")
        XCTAssertNil(b.folder(id: "pair"))
    }

    func testMovingTheLastAgentToAnotherFolderDeletesTheOldOne() {
        var b = book([("Old", ["a"]), ("New", ["n"])])
        b.join("a", folder: "new")
        XCTAssertNil(b.folder(id: "old"))
        XCTAssertEqual(b.folder(of: "a")?.name, "New")
    }

    func testDeletingAFolderLeavesItsAgentsLoose() {
        var b = book([("F", ["a", "b"])])
        b.delete("f")
        XCTAssertTrue(b.members.isEmpty)
        XCTAssertTrue(b.folders.isEmpty)
    }

    // MARK: - Identity and persistence

    func testRekeyFollowsAForkAndARecordedDestinationWins() {
        var b = book([("A", ["old"]), ("B", ["new"])])
        XCTAssertTrue(b.rekey(from: "old", to: "new"))
        XCTAssertEqual(b.folder(of: "new")?.name, "B")
        var c = book([("A", ["old"])])
        c.rekey(from: "old", to: "fork")
        XCTAssertEqual(c.folder(of: "fork")?.name, "A")
        XCTAssertNil(c.members["old"])
    }

    func testStoreRoundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("projects-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("projects.json")
        let store = ProjectStore(url: url)
        let id = store.update { $0.create(name: "Mirai", with: ["a", "b"]) }
        store.update { $0.setCollapsed(id, true); $0.rename(id, to: "Mirai BFCM") }
        let reread = ProjectStore(url: url).current
        XCTAssertEqual(reread.folder(of: "b")?.name, "Mirai BFCM")
        XCTAssertEqual(reread.folder(id: id)?.collapsed, true)
        XCTAssertEqual(reread.names, ["Mirai BFCM"])
    }

    func testAMissingOrCorruptFileIsAnEmptyBook() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).json")
        XCTAssertEqual(ProjectStore.load(from: url), .empty)
        try Data("{not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ProjectStore.load(from: url), .empty)
    }

    func testTheSharedStoreIsNotWhatTestsWrite() {
        // A fixture must never land in the user's real projects.json (the
        // class of bug in "swift test wrote real hubs").
        XCTAssertNotEqual(ProjectStore(url: URL(fileURLWithPath: "/tmp/x.json")).url, ProjectStore.url)
    }

    // MARK: - Namer

    func testNamerReplyIsCleanedToTwoWords() {
        XCTAssertEqual(ProjectNamer.clean("\"Mirai\"\n"), "Mirai")
        XCTAssertEqual(ProjectNamer.clean("Name: U Vape Checkout."), "U Vape")
        XCTAssertEqual(ProjectNamer.clean("Tranquility Base"), "Tranquility Base")
    }

    func testNamerRefusesGenericNames() {
        XCTAssertNil(ProjectNamer.clean("Misc"))
        XCTAssertNil(ProjectNamer.clean("  "))
        XCTAssertNil(ProjectNamer.clean("Miscellaneous"))
    }

    func testFallbackPrefersTheSharedDirectory() {
        let agents = [ProjectNamer.Agent(title: "Flows for BFCM", folder: "mirai-klaviyo"),
                      ProjectNamer.Agent(title: "Segment audit", folder: "mirai-klaviyo")]
        XCTAssertEqual(ProjectNamer.fallback(agents), "Mirai Klaviyo")
    }

    func testFallbackUsesASharedTitleWord() {
        let agents = [ProjectNamer.Agent(title: "Kopi hero generator defects", folder: nil),
                      ProjectNamer.Agent(title: "Fill the Kopi calendar", folder: "other")]
        XCTAssertEqual(ProjectNamer.fallback(agents), "Kopi")
    }

    func testFallbackKeepsASharedOpeningIncludingOneLetterWords() {
        let agents = [ProjectNamer.Agent(title: "U Vape checkout flow", folder: nil),
                      ProjectNamer.Agent(title: "U Vape newsletter drafts", folder: nil)]
        XCTAssertEqual(ProjectNamer.fallback(agents), "U Vape")
    }

    func testFallbackKeepsTheUsersCapitals() {
        let agents = [ProjectNamer.Agent(title: "BlankShirts order sync", folder: nil),
                      ProjectNamer.Agent(title: "Weekly report", folder: nil)]
        XCTAssertEqual(ProjectNamer.fallback(agents), "BlankShirts")
    }

    func testPromptCarriesTheUsersVocabularyAndBothTitles() {
        let text = ProjectNamer.prompt([.init(title: "Flows for BFCM", folder: "mirai"),
                                        .init(title: "Segment audit", folder: nil)],
                                       vocabulary: ["Mirai", "Kopi"])
        XCTAssertTrue(text.contains("Mirai, Kopi"))
        XCTAssertTrue(text.contains("Session A: Flows for BFCM  (directory: mirai)"))
        XCTAssertTrue(text.contains("Session B: Segment audit"))
    }
}
