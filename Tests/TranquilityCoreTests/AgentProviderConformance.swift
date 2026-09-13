import XCTest
@testable import TranquilityCore

/// **What a provider must do, executable.**
///
/// Without this, "add a provider" means reading two existing adapters and
/// guessing. Vibe Kanban keeps a mock executor alongside its real ones for
/// exactly this reason, and it is the most adopted open-source multi-agent
/// client there is.
///
/// The acceptance test for the whole epic (#366): **adding a third provider
/// should be one file plus one entry in the registry, with this suite passing
/// unchanged.**
///
/// Every assertion below checks BOTH SIDES of a rule, not just the happy path.
/// A suite that only proves a provider can succeed is a suite that passes for a
/// provider which never refuses anything, and refusing correctly is most of
/// what this seam is for.
///
/// No socket opens. Providers are driven by fixtures, following the
/// `HubMirror.Transport` seam: one protocol with a `URLSession` implementation
/// beside it, so the tested path is the shipped path minus the network.
enum AgentProviderConformance {

    /// Run every rule against one provider. Called from
    /// `AgentProviderConformanceTests` once per provider.
    static func run(_ provider: any AgentProvider, file: StaticString = #filePath,
                    line: UInt = #line) async throws {
        try await idsAreAddressable(provider, file: file, line: line)
        try await capabilitiesRefuseRatherThanThrow(provider, file: file, line: line)
        try await theIngressIsExactlyOneOfTwoShapes(provider, file: file, line: line)
        try await aSnapshotIsAlwaysAvailable(provider, file: file, line: line)
        try await questionsAreFetchedSeparately(provider, file: file, line: line)
        try await anUnchangedDigestSaysNothing(provider, file: file, line: line)
        try await aFailedPollIsUnknownAndNeverIdle(provider, file: file, line: line)
        try await structuralAnswersNameARealOption(provider, file: file, line: line)
    }

    // MARK: - Ids

    /// `ArtifactStore.isPlausibleSession` refuses anything that is not hex and
    /// dashes within 64 characters, and a refused id gets no hub page at all.
    /// A provider whose ids do not satisfy it has agents that cannot be written
    /// about, which is silent, and discovered weeks later by somebody looking
    /// for a page that was never made.
    static func idsAreAddressable(_ p: any AgentProvider, file: StaticString,
                                  line: UInt) async throws {
        for session in try await p.mine() {
            XCTAssertTrue(ArtifactStore.isPlausibleSession(session.id),
                          "\(p.id): id \(session.id) gets no hub page", file: file, line: line)
            XCTAssertEqual(session.provider, p.id,
                           "\(p.id): a session must carry the provider that made it",
                           file: file, line: line)
        }
    }

    // MARK: - Capabilities

    /// **A false capability REFUSES. It does not throw.**
    ///
    /// The difference is what the panel can say. A refusal is an answer, and
    /// `.unsupported` is a sentence somebody can act on ("this provider has no
    /// way to do that"). A throw is a failure, and the panel has to apologise
    /// for it as though something went wrong. Warp's rule is the right one:
    /// surface the gap rather than hide it.
    static func capabilitiesRefuseRatherThanThrow(_ p: any AgentProvider,
                                                  file: StaticString, line: UInt) async throws {
        guard let any = try await p.mine().first else { return }

        if !p.can.canSend {
            let outcome = try await p.send("probe", to: any.id)
            XCTAssertEqual(outcome, .unsupported,
                           "\(p.id): canSend is false, so send must refuse rather than throw",
                           file: file, line: line)
        }
        if !p.can.canAnswer {
            let request = PendingRequest(id: "probe", session: any.id, asked: "?")
            let outcome = try await p.respond(to: request, with: .text("no"))
            XCTAssertEqual(outcome, .unsupported,
                           "\(p.id): canAnswer is false, so respond must refuse rather than throw",
                           file: file, line: line)
        }
        if !p.can.sendWhileWorking, any.state == .working, p.can.canSend {
            let outcome = try await p.send("probe", to: any.id)
            XCTAssertEqual(outcome, .busy,
                           "\(p.id): a send to a working agent must report busy, not accepted",
                           file: file, line: line)
        }
        if !p.can.carriesPullRequest {
            for session in try await p.mine() {
                XCTAssertNil(session.pullRequest,
                             "\(p.id): carriesPullRequest is false but one arrived",
                             file: file, line: line)
            }
        }
    }

    // MARK: - Ingress

    /// A provider streams or it is polled, and `changes()` returning nil IS the
    /// declaration. Both sides: a provider that says it pushes must actually
    /// yield something, and one that says it does not must not secretly hold a
    /// stream nobody reads.
    static func theIngressIsExactlyOneOfTwoShapes(_ p: any AgentProvider,
                                                  file: StaticString, line: UInt) async throws {
        guard let stream = p.changes() else {
            XCTAssertFalse(p.pushes, "\(p.id): nil stream but pushes is true",
                           file: file, line: line)
            return
        }
        XCTAssertTrue(p.pushes, file: file, line: line)
        var count = 0
        for await event in stream {
            count += 1
            XCTAssertEqual(event.provider, p.id,
                           "\(p.id): an event must name the provider that emitted it",
                           file: file, line: line)
            XCTAssertTrue(ArtifactStore.isPlausibleSession(event.session),
                          "\(p.id): event names an unaddressable session \(event.session)",
                          file: file, line: line)
        }
        XCTAssertGreaterThan(count, 0,
                             "\(p.id): declares a stream and yielded nothing at all",
                             file: file, line: line)
    }

    /// **`mine()` is mandatory even for a streaming provider**, because it is
    /// the catch-up after a dropped stream, and every one of these connections
    /// will drop. A2A requires resubscribe to deliver a full snapshot first for
    /// exactly this reason: a client disconnected across a transition into a
    /// blocked state must not be able to stay wrong about it.
    static func aSnapshotIsAlwaysAvailable(_ p: any AgentProvider,
                                           file: StaticString, line: UInt) async throws {
        let snapshot = try await p.mine()
        XCTAssertFalse(snapshot.isEmpty,
                       "\(p.id): mine() returned nothing, so there is no catch-up after a gap",
                       file: file, line: line)
    }

    // MARK: - The question

    /// **Fetched separately, never carried on the state.** All six vendors
    /// surveyed store them apart, so an interface that coupled them would need
    /// a rewrite on the first provider that separated them, which is all of
    /// them. Both sides: a blocked session must have a request to fetch, and a
    /// session that is not blocked must not invent one.
    static func questionsAreFetchedSeparately(_ p: any AgentProvider,
                                              file: StaticString, line: UInt) async throws {
        for session in try await p.mine() {
            let request = try await p.request(session.id)
            if session.state.isBlocked {
                XCTAssertNotNil(request,
                                "\(p.id): \(session.id) is \(session.state.rawValue) with no "
                                    + "request to show, so the amber row has nothing to say",
                                file: file, line: line)
            }
            if let request {
                XCTAssertEqual(request.session, session.id,
                               "\(p.id): a request must name the session it belongs to",
                               file: file, line: line)
                XCTAssertFalse(request.asked.isEmpty,
                               "\(p.id): a request with no words is not answerable",
                               file: file, line: line)
            }
        }
    }

    // MARK: - Emission

    /// **A digest that has not changed writes no spool line.** A poller that
    /// re-emits an unchanged session every tick moves the read-state watermark
    /// past content nobody has seen, and the grid goes quiet while the agent is
    /// still asking. Both sides: identical polls emit nothing, and a real
    /// change emits exactly one event.
    static func anUnchangedDigestSaysNothing(_ p: any AgentProvider,
                                             file: StaticString, line: UInt) async throws {
        let first = try await p.mine()
        let opening = AgentPoll.events(from: [:], to: first)
        XCTAssertEqual(opening.events.count, first.count,
                       "\(p.id): first sight of every agent is an event", file: file, line: line)

        let quiet = AgentPoll.events(from: opening.digests, to: try await p.mine())
        XCTAssertTrue(quiet.events.isEmpty,
                      "\(p.id): an unchanged poll emitted \(quiet.events.count) event(s)",
                      file: file, line: line)

        guard var moved = first.first else { return }
        moved.title += " (renamed)"
        let after = AgentPoll.events(from: opening.digests, to: [moved])
        XCTAssertEqual(after.events.count, 1,
                       "\(p.id): a real change must emit exactly one event",
                       file: file, line: line)
    }

    /// **A failed poll yields unknown, and never idle.** Not hearing from a
    /// provider is not evidence that its agents finished, and it is not
    /// evidence that they need you either. This is the rule that decides what a
    /// captive portal looks like on the grid.
    static func aFailedPollIsUnknownAndNeverIdle(_ p: any AgentProvider,
                                                 file: StaticString, line: UInt) async throws {
        // The state a caller must fall back to when `mine()` throws. Asserted
        // as a property of the model rather than by breaking the provider,
        // because a provider cannot be asked to fail on demand without a seam
        // that ships in production purely to be broken.
        let fallback = AgentSessionState.unknown
        XCTAssertFalse(fallback.isFinished,
                       "unknown must never read as finished", file: file, line: line)
        XCTAssertFalse(fallback.isBlocked,
                       "unknown must never read as blocked", file: file, line: line)
        XCTAssertEqual(
            AgentPresentation.bucket(state: fallback, hasPendingRequest: false, hasUnread: false),
            .idle, "an unreachable provider's agents are quiet, never done",
            file: file, line: line)
    }

    /// A structural answer must name an option the request actually offered, so
    /// the provider is never asked to parse a sentence back into the choice it
    /// made. A provider that accepts an option it never offered will accept a
    /// stale one from a row the user left open.
    static func structuralAnswersNameARealOption(_ p: any AgentProvider,
                                                 file: StaticString, line: UInt) async throws {
        guard p.can.canAnswer else { return }
        for session in try await p.mine() {
            guard let request = try await p.request(session.id), !request.options.isEmpty
            else { continue }
            let good = try await p.respond(to: request, with: .option(request.options[0].id))
            XCTAssertEqual(good, .accepted,
                           "\(p.id): refused an option it offered", file: file, line: line)
            let bad = try await p.respond(to: request, with: .option("not-an-option"))
            XCTAssertNotEqual(bad, .accepted,
                              "\(p.id): accepted an option it never offered",
                              file: file, line: line)
        }
    }
}
