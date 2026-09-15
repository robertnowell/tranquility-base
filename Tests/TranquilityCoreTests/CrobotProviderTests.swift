import XCTest
@testable import TranquilityCore

/// crobot's lifecycle, and the four places it differs from a bare OpenCode
/// server in ways that bite.
final class CrobotProviderTests: XCTestCase {

    final class Gateway: CrobotTransport, @unchecked Sendable {
        var list: [CrobotTask] = []
        var detail: [String: CrobotTask] = [:]
        var promptResult: SendOutcome = .accepted
        var openCodeRoutes: [String: (Int, String)] = [:]
        private(set) var listLimits: [Int] = []
        private(set) var prompts: [(String, String)] = []
        private(set) var created: [(String, String, String?)] = []

        struct Missing: Error {}
        var who: String? = "robert@coframe.com"
        private(set) var identityCalls = 0

        func identity() async throws -> String? {
            identityCalls += 1
            return who
        }

        func tasks(limit: Int) async throws -> [CrobotTask] {
            listLimits.append(limit)
            return list
        }
        func task(_ id: String) async throws -> CrobotTask {
            guard let hit = detail[id] else { throw Missing() }
            return hit
        }
        func prompt(_ id: String, text: String) async throws -> SendOutcome {
            prompts.append((id, text))
            return promptResult
        }
        func create(repo: String, prompt: String, baseBranch: String?) async throws -> String {
            created.append((repo, prompt, baseBranch))
            return "0de592c1-382e-4760-8e39-b95206cec31c"
        }
        var repoList: [String] = ["Coframe/crobot", "Coframe/jarvis"]
        var repoDefault: String? = "Coframe/jarvis"
        func repos() async throws -> (repos: [String], preselect: String?) {
            (repoList, repoDefault)
        }
        func taskURL(_ id: String) -> URL? {
            URL(string: "https://crobot.coframe.com/tasks/\(id)")
        }
        func opencode(_ id: String) -> any OpenCodeClient.Transport {
            let fake = OpenCodeClientTests.Fake()
            fake.routes = openCodeRoutes
            return fake
        }
    }

    private func task(_ id: String, status: String = "running", detail statusDetail: String? = nil,
                      by: String = "robert@coframe.com", repo: String = "acme/importer",
                      pr: String? = nil) -> CrobotTask {
        var t = CrobotTask(id: id)
        t.status = status
        t.statusDetail = statusDetail
        t.createdBy = by
        t.repo = repo
        t.prUrl = pr
        t.title = "port the importer"
        return t
    }

    private let a = "8f14e45f-ceea-467a-9eef-2b9c1b2dc9f0"
    private let b = "c4ca4238-a0b9-4382-8dcc-509a6f75849b"

    private func provider(_ g: Gateway, me: String? = "robert@coframe.com") -> CrobotProvider {
        CrobotProvider(transport: g, me: me)
    }

    // MARK: - The list has no creator filter

    /// **`listIsCallerScoped` is false and this is why.** Without the
    /// client-side filter a row appears for an agent this user cannot answer.
    func testSomebodyElsesTasksAreFilteredOut() async throws {
        let g = Gateway()
        g.list = [task(a), task(b, by: "someone@else.com")]
        let mine = try await provider(g).mine()
        XCTAssertEqual(mine.map(\.providerID), [a])
        XCTAssertFalse(provider(g).can.listIsCallerScoped,
                       "declaring this true would make the filter look optional")
    }

    /// **Measured against the live gateway, 14 Sep: 115 tasks visible, 7 mine.**
    /// A nil identity used to mean "show everything", so the wiring that passed
    /// nil would have put 108 other people's agents on the panel. Refusing is
    /// the safe direction: an empty list reads as nothing to show, a full one
    /// reads as somebody else's work being yours.
    func testWithNoIdentityItShowsNothingRatherThanEverything() async throws {
        let g = Gateway()
        g.who = nil
        g.list = [task(a), task(b, by: "someone@else.com")]
        let mine = try await CrobotProvider(transport: g, me: nil).mine()
        XCTAssertTrue(mine.isEmpty, "a nil identity must not mean show everybody")
    }

    /// The identity is asked of the gateway when the caller does not supply
    /// one, which is what the app does.
    func testTheIdentityComesFromTheGatewayWhenNotSupplied() async throws {
        let g = Gateway()
        g.list = [task(a), task(b, by: "someone@else.com")]
        let mine = try await CrobotProvider(transport: g, me: nil).mine()
        XCTAssertEqual(mine.map(\.providerID), [a])
        XCTAssertGreaterThanOrEqual(g.identityCalls, 1)
    }

    /// Archived means the disk was released and the record stays so a
    /// follow-up can recreate the sandbox. 112 of the 115 were archived, and
    /// listing them would bury three live agents under a hundred tombstones.
    func testArchivedTasksAreHistoryRatherThanRows() async throws {
        let g = Gateway()
        g.list = [task(a, status: "idle"), task(b, status: "archived")]
        let mine = try await provider(g).mine()
        XCTAssertEqual(mine.map(\.providerID), [a])
    }

    /// `limit` slices newest-first, so a small page silently drops the
    /// caller's older tasks while returning somebody else's newer ones.
    func testTheListIsReadGenerouslyBecauseItSlicesNewestFirst() async throws {
        let g = Gateway()
        _ = try await provider(g).mine()
        XCTAssertGreaterThanOrEqual(g.listLimits.first ?? 0, 200)
    }

    // MARK: - The waiting state crobot does not have

    /// crobot has no waiting status: a blocked task still reads `running`, and
    /// the only evidence is a prefix on a free-text field.
    func testABlockedTaskIsFoundByThePrefixAndNotTheStatus() async throws {
        let g = Gateway()
        g.list = [task(a, status: "running",
                       detail: "Waiting for your answer: which branch?")]
        let session = try await provider(g).mine().first
        XCTAssertEqual(session?.state, .inputRequired,
                       "the status said running; only the prefix knew better")
    }

    /// **Prefix, never equality.** That field also carries rate-limit and
    /// pod-loss text, and equality would miss every real case.
    func testTheWaitingPrefixMatchesRatherThanEquals() {
        var t = CrobotTask(id: a)
        t.statusDetail = "Waiting for your answer: merge to main?"
        XCTAssertTrue(t.isWaiting)
        t.statusDetail = "Waiting for your answer"
        XCTAssertTrue(t.isWaiting)
        t.statusDetail = "Rate limited by the provider, retrying"
        XCTAssertFalse(t.isWaiting, "unrelated statusDetail text must not read as a question")
    }

    // MARK: - The five statuses

    func testEveryCrobotStatusMapsToSomethingHonest() {
        func state(_ s: String) -> AgentSessionState {
            var t = CrobotTask(id: "x"); t.status = s; return t.state
        }
        XCTAssertEqual(state("starting"), .submitted)
        XCTAssertEqual(state("running"), .working)
        XCTAssertEqual(state("idle"), .completed)
        XCTAssertEqual(state("failed"), .failed)
        // The disk was released; the record stays and a follow-up recreates
        // the sandbox. Finished, not dead.
        XCTAssertEqual(state("archived"), .completed)
        // A status this build predates must not empty the grid.
        XCTAssertEqual(state("hibernating"), .unknown)
    }

    // MARK: - A sleeping sandbox is normal

    /// The gateway answers reads with 409 rather than waking a task, so an
    /// idle task returns this on every poll. A sleeping sandbox is not asking
    /// a question, and it is not an error either.
    func testASleepingSandboxYieldsNoQuestionRatherThanThrowing() async throws {
        let g = Gateway()
        g.list = [task(a)]
        g.openCodeRoutes["GET /session"] = (409, #"{"error":"the sandbox is asleep"}"#)
        let request = try await provider(g).request(AgentSession.id(a, provider: "crobot"))
        XCTAssertNil(request)
    }

    func testASleepingSandboxYieldsAnEmptyTranscriptRatherThanThrowing() async throws {
        let g = Gateway()
        g.list = [task(a)]
        g.openCodeRoutes["GET /session"] = (409, "")
        let turns = try await provider(g).transcript(AgentSession.id(a, provider: "crobot"))
        XCTAssertTrue(turns.isEmpty)
    }

    // MARK: - One door for both verbs

    /// `POST /tasks/:id/prompt` fuzzy-matches the text against the pending
    /// question's option labels, so there is no separate answer verb and
    /// sending prose at a question is correct HERE where it would be wrong for
    /// a bare OpenCode server.
    func testAnAnswerAndAFollowUpUseTheSameEndpoint() async throws {
        let g = Gateway()
        g.list = [task(a)]
        let id = AgentSession.id(a, provider: "crobot")
        _ = try await provider(g).send("carry on", to: id)
        _ = try await provider(g).respond(
            to: PendingRequest(id: "q", session: id, asked: "which?"),
            with: Response("main"))
        XCTAssertEqual(g.prompts.map(\.1), ["carry on", "main"])
        XCTAssertEqual(Set(g.prompts.map(\.0)), [a])
    }

    /// A declared limit that nothing enforces is the same defect as a declared
    /// capability nothing reads. Caught by the conformance suite on the first
    /// run, exactly as it was for the local provider.
    func testASendToAWorkingTaskReportsBusyWithoutPostingIt() async throws {
        let g = Gateway()
        g.list = [task(a, status: "running")]
        g.detail[a] = task(a, status: "running")
        let outcome = try await provider(g).send("hi", to: AgentSession.id(a, provider: "crobot"))
        XCTAssertEqual(outcome, .busy)
        XCTAssertTrue(g.prompts.isEmpty, "it must not reach the gateway at all")
    }

    func testASendToAnIdleTaskGoesThrough() async throws {
        let g = Gateway()
        g.list = [task(a, status: "idle")]
        g.detail[a] = task(a, status: "idle")
        _ = try await provider(g).send("hi", to: AgentSession.id(a, provider: "crobot"))
        XCTAssertEqual(g.prompts.map(\.1), ["hi"])
    }

    func testBusyFromTheGatewayIsCarriedThroughRatherThanSwallowed() async throws {
        let g = Gateway()
        g.list = [task(a, status: "idle")]
        g.detail[a] = task(a, status: "idle")
        g.promptResult = .busy
        let outcome = try await provider(g).send("hi", to: AgentSession.id(a, provider: "crobot"))
        XCTAssertEqual(outcome, .busy)
    }

    // MARK: - Starting

    /// A task without a repository is not a thing crobot can make, and saying
    /// so beats a 400 the user has to interpret.
    func testStartingWithoutARepositoryRefusesInWords() async {
        do {
            _ = try await provider(Gateway()).start(Brief(prompt: "do the thing"))
            XCTFail("expected a refusal")
        } catch let error as CrobotProvider.CrobotError {
            XCTAssertEqual(error, .repositoryRequired)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testStartingPassesTheRepositoryAndBranch() async throws {
        let g = Gateway()
        _ = try await provider(g).start(
            Brief(prompt: "port it", repository: "acme/importer", branch: "main"))
        XCTAssertEqual(g.created.first?.0, "acme/importer")
        XCTAssertEqual(g.created.first?.2, "main")
    }

    // MARK: - It carries a pull request, unlike the local one

    func testAPullRequestReachesTheSessionWhenThereIsOne() async throws {
        let g = Gateway()
        g.list = [task(a, pr: "https://github.com/acme/importer/pull/9")]
        let session = try await provider(g).mine().first
        XCTAssertEqual(session?.pullRequest?.absoluteString,
                       "https://github.com/acme/importer/pull/9")
        XCTAssertTrue(provider(g).can.carriesPullRequest)
    }

    /// The three capabilities that disagree with local OpenCode's, which is
    /// what the conformance suite exists to police.
    func testItDisagreesWithLocalOpenCodeInExactlyTheExpectedPlaces() {
        let c = provider(Gateway()).can
        XCTAssertFalse(c.listIsCallerScoped)
        XCTAssertTrue(c.carriesPullRequest)
        XCTAssertFalse(c.sendWhileWorking)
        XCTAssertNil(provider(Gateway()).changes(), "crobot is polled, not streamed")
        XCTAssertNotNil(provider(Gateway()).url(for: a), "and it has a page, unlike local")
    }

    // MARK: - Conformance

    func testItConforms() async throws {
        let g = Gateway()
        g.list = [task(a, status: "running")]
        g.detail[a] = task(a, status: "running")
        g.openCodeRoutes["GET /session"] = (200, "[]")
        try await AgentProviderConformance.run(provider(g), egress: true)
    }
}

// MARK: - crobot asks for a repo before it starts (#374 gap, 15 Sep 2026)

extension CrobotProviderTests {

    /// **The gap Robert hit: starting a crobot task from the app just errored.**
    /// The app sent `start(Brief(prompt: ""))` with no repository, crobot threw
    /// `repositoryRequired`, and the raw error surfaced. crobot needs a repo, so
    /// now it ASKS for one — the same way any agent asks a question — instead of
    /// failing.
    func testCrobotAsksWhichRepoWhenTheBriefHasNone() async throws {
        let g = Gateway()
        g.repoList = ["Coframe/crobot", "Coframe/jarvis", "Coframe/darwin"]
        let questions = try await provider(g).startQuestions(for: Brief(prompt: "fix the build"))
        XCTAssertEqual(questions.count, 1)
        let q = questions.first
        XCTAssertEqual(q?.asked, "Which repository should I work in?")
        XCTAssertEqual(q?.options.map(\.id),
                       ["Coframe/crobot", "Coframe/jarvis", "Coframe/darwin"],
                       "the options are the repos this key can reach, from GET /repos")
        XCTAssertTrue(q?.allowsMultiple == true, "a task can span repos — tick one or more")
        XCTAssertTrue(q?.allowsCustom == true, "and a repo not listed can still be typed")
    }

    /// A brief that already names a repo asks nothing — a deep link, or the
    /// second time round after the question was answered.
    func testCrobotAsksNothingWhenTheRepoIsAlreadyChosen() async throws {
        var brief = Brief(prompt: "go")
        brief.repository = "Coframe/crobot"
        let questions = try await provider(Gateway()).startQuestions(for: brief)
        XCTAssertTrue(questions.isEmpty)
    }

    /// The general seam: a provider that needs nothing asks nothing, with no
    /// code of its own. This is what keeps "custom workflow for crobot" from
    /// becoming "every provider reimplements start".
    func testMostProvidersAskNothingByDefault() async throws {
        struct Bare: AgentProvider {
            let id = "bare"; let can = Capabilities()
            func changes() -> AsyncStream<AgentEvent>? { nil }
            func mine() async throws -> [AgentSession] { [] }
            func refine(_ id: AgentSession.ID) async throws -> AgentSession { .of(id, provider: "bare") }
            func request(_ id: AgentSession.ID) async throws -> PendingRequest? { nil }
            func transcript(_ id: AgentSession.ID) async throws -> [Turn] { [] }
            func send(_ t: String, to id: AgentSession.ID) async throws -> SendOutcome { .accepted }
            func respond(to r: PendingRequest, with response: Response) async throws -> SendOutcome { .accepted }
            func start(_ brief: Brief) async throws -> AgentSession.ID { "x" }
            func cancel(_ id: AgentSession.ID) async throws -> SendOutcome { .accepted }
            func url(for id: AgentSession.ID) -> URL? { nil }
        }
        let asked = try await Bare().startQuestions(for: Brief(prompt: "hi"))
        XCTAssertTrue(asked.isEmpty, "the default is to ask nothing")
    }
}
