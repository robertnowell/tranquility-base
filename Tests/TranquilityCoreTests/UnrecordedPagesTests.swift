import XCTest
@testable import TranquilityCore

/// The direction nothing checked: a page that exists and was never recorded.
///
/// `HubIntegrity.check` asks whether every RECORD reaches a hub. On 13 Sep a
/// page written eleven minutes after a Codex fork sat in the child's directory,
/// recorded nowhere, listed on no hub — and every existing check passed.
final class UnrecordedPagesTests: XCTestCase {

    private var agents: URL!
    private var support: URL!
    private let session = "01a09b8d-c39b-7111-815c-6a09d382b46a"

    override func setUpWithError() throws {
        // The caches directory, not /tmp: ArtifactStore refuses to record a
        // path under a scratchpad, so a fixture there tests the refusal.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tranquility-tests/unrecorded-\(UUID().uuidString)")
        agents = base.appendingPathComponent("agents")
        support = base.appendingPathComponent("support")
        try FileManager.default.createDirectory(
            at: agents.appendingPathComponent(session), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: agents.deletingLastPathComponent())
    }

    @discardableResult
    private func page(_ name: String, declaring owner: String? = nil) throws -> URL {
        let url = agents.appendingPathComponent(session).appendingPathComponent(name)
        let meta = owner.map { "<meta name=\"intranet:session\" content=\"\($0)\">" } ?? ""
        try "<html><head>\(meta)</head><body>x</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func found() -> [HubIntegrity.Problem] {
        HubIntegrity.unrecordedPages(artifactRoot: support.path, agentsRoot: agents)
    }

    func testAPageNobodyRecordedIsReported() throws {
        try page("credits-launch-plan.html", declaring: session)
        XCTAssertEqual(found().count, 1)
        XCTAssertTrue(found()[0].detail.contains("credits-launch-plan.html"))
    }

    func testARecordedPageIsNotReported() throws {
        let url = try page("credits-launch-plan.html", declaring: session)
        XCTAssertTrue(ArtifactStore.record(url.path, session: session, root: support.path))
        XCTAssertTrue(found().isEmpty)
    }

    /// The hub is the index over pages, never one of them.
    func testTheHubItselfIsNotAMissingPage() throws {
        try page("index.html", declaring: session)
        XCTAssertTrue(found().isEmpty)
    }

    /// A build input is recorded as the page built from it, so reporting the
    /// fragment would be reporting a page that IS on its hub under another
    /// name — the false positive this check hit on its first run.
    func testAFragmentBesideItsBuiltPageIsNotReported() throws {
        let built = try page("report.html", declaring: session)
        try page("report.fragment.html", declaring: session)
        XCTAssertTrue(ArtifactStore.record(built.path, session: session, root: support.path))
        XCTAssertTrue(found().isEmpty)
    }

    /// Somebody else's page in this directory is a different fault, with its
    /// own report in `check`. Claiming it here would say this agent made it.
    func testAForeignPageIsNotThisCheckToMake() throws {
        try page("somebody-elses.html", declaring: "0d04e845-65ff-488f-983c-58f371d661ed")
        XCTAssertTrue(found().isEmpty)
    }
}

/// One conversation, one hub — but the pages still live in the directory of
/// the member that wrote them, and somebody has to scan there.
final class FamilyReconcileTests: XCTestCase {

    private var agents: URL!
    private var support: URL!
    private let origin = "01a07eba-fa51-79a2-ade7-d416cb916dd0"
    private let fork = "01a09b8d-c39b-7111-815c-6a09d382b46a"

    override func setUpWithError() throws {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tranquility-tests/family-\(UUID().uuidString)")
        agents = base.appendingPathComponent("agents")
        support = base.appendingPathComponent("support")
        for d in [agents!, support!] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: agents.deletingLastPathComponent())
    }

    private func page(_ name: String, in session: String) throws -> URL {
        let dir = agents.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "<html><head><meta name=\"intranet:session\" content=\"\(session)\"></head><body>x</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The bug: the fork's page was in the fork's directory, the hub was the
    /// origin's, and nothing scanned where the page actually was.
    func testAForksOwnPageIsRecordedUnderTheFork() throws {
        let written = try page("credits-launch-plan.html", in: fork)
        try FileManager.default.createDirectory(
            at: agents.appendingPathComponent(origin), withIntermediateDirectories: true)

        XCTAssertEqual(HomeBase.reconcileMembers([origin, fork], origin: origin,
                                                 title: "Summarize AssemblyAI onboarding",
                                                 root: agents, support: support.path), 1)

        let recorded = ArtifactStore.history(for: fork, root: support.path).map(\.path)
        XCTAssertEqual(recorded, [written.resolvingSymlinksInPath().path])
    }

    /// A member already folded into the origin's directory is the origin's
    /// directory. Scanning it again under the member's id would record every
    /// page in the conversation twice.
    func testASymlinkedMemberIsNotScannedTwice() throws {
        try page("shared.html", in: origin)
        try FileManager.default.createSymbolicLink(
            at: agents.appendingPathComponent(fork),
            withDestinationURL: agents.appendingPathComponent(origin))

        XCTAssertEqual(HomeBase.reconcileMembers([origin, fork], origin: origin,
                                                 title: "t", root: agents,
                                                 support: support.path), 0)
        XCTAssertTrue(ArtifactStore.history(for: fork, root: support.path).isEmpty)
    }

    /// A family of one costs nothing.
    func testAnUnforkedSessionScansNothingExtra() {
        XCTAssertEqual(HomeBase.reconcileMembers([origin], origin: origin, title: "t",
                                                 root: agents, support: support.path), 0)
    }
}
