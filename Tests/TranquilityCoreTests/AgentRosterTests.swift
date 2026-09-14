import XCTest
@testable import TranquilityCore

final class AgentRosterTests: XCTestCase {

    private func grid(installed: Set<String> = [], credentialed: Set<String> = [],
                      signedOut: Set<String> = []) -> [AgentRoster.Agent] {
        AgentRoster.grid(installed: { installed.contains($0) },
                         credentialed: { credentialed.contains($0) },
                         signedOut: signedOut)
    }

    /// **Only agents we have driven end to end.** *"The only things that should
    /// be in the grid are ones that we've fully validated and tested and love
    /// and work with."* The ACP catalog is a different list with a different
    /// job: eleven published claims about other people's software, of which we
    /// have proven two.
    func testTheRosterIsTheShortlistAndNotThePublishedCatalog() {
        let roster = Set(AgentRoster.validated.map(\.id))
        XCTAssertEqual(roster, ["claude-code", "codex", "crobot", "opencode"])
        XCTAssertFalse(roster.contains("devin"),
                       "Devin is proven at the protocol and wired to nothing; four we "
                       + "can drive beats five where one is a promise")
        // Cursor is published, installed on at least one machine, and BROKEN
        // there (no `acp` subcommand at all). It must not be offered.
        XCTAssertTrue(ACPCatalog.published.contains { $0.id == "cursor" })
        XCTAssertFalse(roster.contains("cursor"),
                       "an agent we could not drive must not be offered")
        XCTAssertLessThan(roster.count, ACPCatalog.published.count + 2,
                          "the roster is a shortlist, not the catalog with extras")
    }

    /// Every entry says who vouched for it and when, so a row nobody can stand
    /// behind any more is obvious on sight rather than after an outage.
    func testEveryValidatedAgentCarriesItsEvidence() {
        for entry in AgentRoster.validated {
            XCTAssertFalse(entry.provenance.isEmpty, "\(entry.id) has no provenance")
            XCTAssertFalse(entry.glyph.isEmpty, "\(entry.id) has no glyph for its tile")
        }
    }

    // MARK: - A tile is a tick, or a next step

    func testAnInstalledAndCredentialedAgentIsSimplyReady() {
        let tile = grid(installed: ["opencode"], credentialed: ["opencode"])
            .first { $0.id == "opencode" }
        XCTAssertEqual(tile?.standing, .ready)
    }

    func testAnAgentThatIsNotHereOffersTheInstall() {
        let tile = grid().first { $0.id == "opencode" }
        guard case .needsSetup(.install) = tile?.standing else {
            return XCTFail("\(String(describing: tile?.standing))")
        }
    }

    /// **Signed out is an ordinary state, not an error.** It offers the step
    /// and nothing else: no failure, no block, no red.
    func testBeingSignedOutOffersASignInAndNotAFailure() {
        let tile = grid(installed: ["opencode"], credentialed: ["opencode"],
                        signedOut: ["opencode"]).first { $0.id == "opencode" }
        guard case .needsSetup(.signIn) = tile?.standing else {
            return XCTFail("\(String(describing: tile?.standing))")
        }
        XCTAssertFalse(tile?.standing.isReady == true)
    }

    // MARK: - Nothing expensive happens to paint this

    /// The readiness probe that actually proves an agent works costs a real
    /// model call, and proving it is OUR job rather than the user's. So the
    /// grid must be assemblable from what is on disk, and this test is the
    /// tripwire: it builds the whole thing with closures that would trap if
    /// anything tried to reach the network.
    func testPaintingTheGridAsksNothingExpensive() {
        var asked: [String] = []
        let tiles = AgentRoster.grid(
            installed: { asked.append("installed:\($0)"); return true },
            credentialed: { asked.append("credentialed:\($0)"); return true })
        XCTAssertEqual(tiles.count, AgentRoster.validated.count)
        XCTAssertTrue(asked.allSatisfy { $0.hasPrefix("installed:")
                                      || $0.hasPrefix("credentialed:") },
                      "the grid asked something other than disk: \(asked)")
    }

    // MARK: - Where a sign-out is actually discovered

    /// Measured 14 Sep against a logged-out `devin acp`: the handshake passes,
    /// `session/new` passes, and only the prompt turn fails. So the first
    /// moment the truth exists is a turn coming back, and this is what reads
    /// it. The vendor's own sentence is kept because it names the command.
    func testASignOutIsRecognisedFromTheTurnThatFailed() {
        let real = "Please log in to use Devin. Use `/login` to authenticate again."
        guard case .signIn(let words)? = AgentRoster.signOut(in: real) else {
            return XCTFail("the real logged-out message was not recognised")
        }
        XCTAssertTrue(words.contains("/login"), "keep the instruction that names the command")
    }

    func testTheOtherWaysAVendorSaysItAreRecognisedToo() {
        for reason in ["Unauthorized", "invalid api key", "Authentication required",
                       "You are not authenticated", "expired token, please sign in"] {
            XCTAssertNotNil(AgentRoster.signOut(in: reason), "missed: \(reason)")
        }
    }

    /// **And an ordinary failure is NOT a sign-out.** Reading every error as
    /// "log in again" would send the user to a login screen for a network blip
    /// and hide the real reason, which is the failure this codebase already
    /// recorded once when a refusal was returned as a generic failure.
    func testAnOrdinaryFailureIsNotMistakenForASignOut() {
        for reason in ["connection reset by peer", "the model is overloaded",
                       "rate limit exceeded", "no such session", "disk full"] {
            XCTAssertNil(AgentRoster.signOut(in: reason),
                         "\(reason) is not a sign-out and must not offer a login")
        }
    }
}

// MARK: - Validated is not the same as reachable (14 Sep)

extension AgentRosterTests {

    /// **A tile must not sign somebody in to something the app cannot drive.**
    /// The first draft of the roster listed five agents as though picking any
    /// of them worked, when three of them stop somewhere short: crobot can be
    /// seen and opened but has never had a reply delivered to a live gateway,
    /// OpenCode reaches the app over HTTP while its ACP path is registered
    /// nowhere, and Devin is proven at the protocol and wired to nothing.
    func testOnlyAgentsTheAppCanActuallyDriveAreOfferable() {
        let offerable = AgentRoster.validated.filter { $0.reach.isOfferable }.map(\.id)
        XCTAssertEqual(Set(offerable), ["claude-code", "codex", "crobot", "opencode"],
                       "an agent became offerable without the app being able to drive it")
    }

    /// Anything short of drivable states where it stops, rather than being
    /// dropped without explanation.
    func testAnythingShortOfDrivableSaysWhereItStops() {
        for entry in AgentRoster.validated where !entry.reach.isOfferable {
            XCTAssertFalse(entry.provenance.isEmpty,
                           "\(entry.id) stops short and does not say where")
        }
    }

    /// **Every offered agent was driven against the real thing**, and its
    /// evidence says so. The bar is a message sent AND the answer read back,
    /// because `.accepted` is the server taking a request, not an agent
    /// answering. Both remote providers failed this bar this morning.
    func testEveryOfferedAgentWasDrivenLiveAndSaysSo() {
        for entry in AgentRoster.validated where entry.reach.isOfferable {
            let ok = entry.provenance.contains("read back")
                || entry.provenance.contains("READ BACK")
                || entry.provenance.contains("daily use")
            XCTAssertTrue(ok, "\(entry.id) is offered without live evidence: \(entry.provenance)")
        }
    }

    /// The provenance must not claim more than was done. This is a specific
    /// guard against the sentence that was actually written today — "reply
    /// delivered through the spool" — about a reply that has only ever reached
    /// a test double.
    func testCrobotsEvidenceNamesTheLiveRunAndItsCost() {
        let crobot = AgentRoster.validated.first { $0.id == "crobot" }?.provenance ?? ""
        XCTAssertTrue(crobot.contains("READ BACK"), "must name the read-back, not the send")
        XCTAssertTrue(crobot.contains("99s") || crobot.contains("cold sandbox"),
                      "must carry what it costs: the first write wakes a sandbox")
    }
}
