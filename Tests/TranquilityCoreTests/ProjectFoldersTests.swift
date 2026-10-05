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
            case let .header(folder, lamp, hollow, lit, _):
                return "[\(folder.name)\(lamp.map { " \(hollow ? "heard-" : "")\($0.trackName) \(lit)" } ?? "")]"
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

    // MARK: - Rule 3: folder order is the user's, and sticky

    func testALitLampNeverMovesAFolder() {
        let order = book([("First", ["q"]), ("Second", ["s"])])
        let secondAsks = SessionRow.quietRowsLast([row("q", .working, at: 5), row("s", .ready, at: 9)])
        XCTAssertEqual(ProjectLayout.lines(secondAsks, book: order).compactMap(\.folder?.name),
                       ["First", "Second"])
        let amber = SessionRow.quietRowsLast([row("q", .running), row("s", .fault, at: 9)])
        XCTAssertEqual(ProjectLayout.lines(amber, book: order).compactMap(\.folder?.name),
                       ["First", "Second"])
    }

    func testADraggedFolderStaysWhereItWasPut() {
        var b = book([("First", ["q"]), ("Second", ["s"])])
        b.move("second", to: "first", after: false)
        let firstAsks = SessionRow.quietRowsLast([row("q", .ready, at: 9), row("s", .working, at: 5)])
        XCTAssertEqual(ProjectLayout.lines(firstAsks, book: b).compactMap(\.folder?.name),
                       ["Second", "First"])
    }

    func testDraggingAHeaderSetsTheOrder() {
        var b = book([("First", ["q"]), ("Second", ["s"]), ("Third", ["t"])])
        b.move("third", to: "first", after: false)
        XCTAssertEqual(b.folders.map(\.name), ["Third", "First", "Second"])
        b.move("third", to: "second", after: true)
        XCTAssertEqual(b.folders.map(\.name), ["First", "Second", "Third"])
    }

    // MARK: - Folders are pins when the grid is full (ruled 2 Oct 2026)

    func testLooseRowsLeaveTheGridBeforeAnyFolderRow() {
        let b = book([("A", ["a1", "a2"]), ("B", ["b1"])])
        // Loose rows are the newest, so a recency cut would keep them.
        let rows = SessionRow.quietRowsLast([row("l1", .ready, at: 99), row("l2", .ready, at: 98),
                                             row("a1", .ready, at: 10), row("a2", .working, at: 9),
                                             row("b1", .ready, at: 8)])
        let kept = ProjectLayout.gridRows(rows, capacity: 3, floor: 1, book: b).map(\.id)
        XCTAssertEqual(Set(kept), ["a1", "a2", "b1"])
    }

    func testTheLowestFolderLosesItsWorkingRowsFirst() {
        let b = book([("Top", ["t1", "t2"]), ("Low", ["g", "w"])])
        let rows = SessionRow.quietRowsLast([row("t1", .ready, at: 1), row("t2", .working, at: 2),
                                             row("g", .ready, at: 50), row("w", .working, at: 60)])
        XCTAssertEqual(Set(ProjectLayout.gridRows(rows, capacity: 3, floor: 1, book: b).map(\.id)),
                       ["t1", "t2", "g"], "the low folder's blue row goes first")
        XCTAssertEqual(Set(ProjectLayout.gridRows(rows, capacity: 2, floor: 1, book: b).map(\.id)),
                       ["t1", "t2"], "then its green one")
    }

    func testPinningNeverShowsAnIdleRowOverALitOne() {
        let b = book([("F", ["idle"])])
        let rows = SessionRow.quietRowsLast([row("lit", .ready, at: 5), row("idle", .running)])
        XCTAssertEqual(ProjectLayout.gridRows(rows, capacity: 1, floor: 1, book: b).map(\.id), ["lit"],
                       "the grid is for lit lamps (18 Aug); a folder pins among them")
    }

    func testWithNoFoldersMembershipIsExactlyAsBefore() {
        let rows = SessionRow.quietRowsLast([row("a", .ready, at: 3), row("b", .working, at: 2),
                                             row("c", .running), row("d", .unlit)])
        XCTAssertEqual(ProjectLayout.gridRows(rows, capacity: 3, floor: 2, book: .empty).map(\.id),
                       SessionRow.gridRows(rows, capacity: 3, floor: 2).map(\.id))
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

    // 1 Oct 2026: a collapsed folder of heard greens showed a solid green.
    func testCollapsedFolderIsSolidOnlyWhenAMemberIsSolid() {
        let b = book([("Apartment", ["a", "b"])], collapsed: ["Apartment"])
        func ready(_ id: String, _ read: ReadState) -> SessionRow {
            SessionRow(id: id, name: id, aux: id, lamp: .ready, read: read, hasRecordedTurn: true)
        }
        XCTAssertEqual(shape(ProjectLayout.lines([ready("a", .opened), ready("b", .opened)], book: b)),
                       ["[Apartment heard-ready 2]"])
        XCTAssertEqual(shape(ProjectLayout.lines([ready("a", .opened), ready("b", .unread)], book: b)),
                       ["[Apartment ready 2]"])
        // Blue carries no read state, on the row or the header.
        let blue = SessionRow(id: "a", name: "a", aux: "a", lamp: .working, read: .opened, hasRecordedTurn: true)
        XCTAssertEqual(shape(ProjectLayout.lines([blue], book: b)), ["[Apartment working 1]"])
    }

    func testAnOpenHeaderWearsNoLamp() {
        let lines = ProjectLayout.lines([row("g", .ready, at: 1)], book: book([("F", ["g"])]))
        guard case let .header(_, lamp, _, _, _) = lines[0] else { return XCTFail("no header") }
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
