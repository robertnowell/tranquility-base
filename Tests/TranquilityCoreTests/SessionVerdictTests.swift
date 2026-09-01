import XCTest
@testable import TranquilityCore

/// The arbiter must agree with the function it replaces, on every input.
///
/// This is the refactor's whole safety net, and it is deliberately a
/// DIFFERENTIAL test rather than a golden one. The distinction cost this
/// project real money on 01 Sep: a golden corpus recorded from current
/// behaviour captures what the code DOES, not what it SHOULD do, so a suite
/// built that way would have certified all five of the wrong-lamp bugs as
/// expected. Here the oracle is the old implementation itself, which is a
/// legitimate oracle for exactly one question, "did the extraction change
/// anything", and for no other.
///
/// So: this file proves the move is faithful. It proves nothing about whether
/// the rules are right. `VerdictInvariantTests` below carries that half.

/// The implementation `SessionVerdict` replaced, kept HERE and only here.
///
/// A differential test needs an oracle, and for the single question "did the
/// extraction change anything" the previous implementation is a legitimate one.
/// It lives in the test target so production has exactly one copy of the rules,
/// and so that this comparison keeps meaning something: if the old body stayed
/// in `GridAssembler` and the new code called it, the test would be comparing a
/// function with itself.
///
/// Do not fix bugs here. If a rule is wrong, it is wrong in
/// `SessionVerdict.resolve`, and this file's job is only to prove the day of the
/// move changed nothing.
enum LegacyLamp {
    static func lampAndReason(
        for evidence: SessionActivity.Evidence?, sessionId: String,
        live: LiveSession?, boundary: SessionActivity.TurnBoundary? = nil,
        pickedUp: Bool = false, isInFlight: Bool = false
    ) -> (lamp: Lamp, reason: String?, detail: String?) {

        let activity = evidence?.activity
        let resumed = AgentRestart.resumed(
            startedAt: live?.startedAtDate,
            lastWord: AgentRestart.lastWord(observedAt: evidence?.observedAt,
                                            boundary: boundary))
        // Blocked on you, said by the process itself, and it outranks
        // everything else here — see `blockedOnYou`.
        if let blocked = GridAssembler.blockedOnYou(live, resumed: resumed) { return blocked }
        // Resumed, and told nothing since: whatever the file describes was
        // written by a process that has since been killed. Ruled 19 Aug — a
        // session you restart is no longer idle and belongs on the grid — so
        // this sits above the two downgrades below, which read a resumed
        // process's brand-new idleness as "nothing here" and filed the row.
        //
        // It supplies the colour ONLY where nothing else does. `busy` first,
        // because a resumed session that is already chewing has simply not
        // written its first line yet, and blue is the true state; `blocked`
        // keeps its own words inside `reason`. See `AgentRestart`.
        if live?.status != "busy", resumed,
           let said = AgentRestart.reason(for: activity) {
            return (.fault, said.short, said.full)
        }
        let observed: (Lamp, String?, String?) = {
            switch activity {
            case .working:
                // The file says a turn is in flight. If the process says it is
                // idle, the turn ended in a shape the file cannot express — an
                // unanswered prompt with no turn-end marker, the 17:19 case.
                // The process is right and it costs nothing to believe it.
                return live?.status == "idle" ? (.running, nil, nil) : (.working, nil, nil)
            // An ERROR is a fact the transcript states outright, and no process
            // status contradicts it: a session sitting on a usage limit is idle
            // by every measure the API has.
            case .blocked: return (.fault, activity?.shortReason, activity?.fullReason)
            // A STALL is an inference from silence, and silence is exactly what
            // a running process can speak to. Measured 18 Aug: `59181c6d` and
            // `b18ebb61` both had a real typed prompt as their last entry and
            // nothing for four hours — a textbook stall by the file — and both
            // reported `idle`. Robert, looking at the same two rows: "in both
            // of these cases, the agent did return."
            case .stalled:
                switch live?.status {
                case "idle": return (.running, nil, nil)
                case "busy": return (.working, nil, nil)
                // No process at all, or a status we do not recognise: the file
                // is the only witness left and it says silence. Amber stands.
                default: return (.fault, activity?.shortReason, activity?.fullReason)
                }
            case .idle, nil:
                // And the mirror: the file has nothing to say, the process says
                // it is chewing. Blue rather than quiet.
                return live?.status == "busy" ? (.working, nil, nil) : (.running, nil, nil)
            }
        }()
        guard observed.0 == .running else { return observed }
        if isInFlight { return (.working, nil, nil) }
        // Last, and only over a lamp that was going out anyway: the user picked
        // this session up. Ruled 19 Aug — *"because it's alive, clicking on it
        // obviously means I want it to be alive. Now it's in the grid."*
        //
        // Deliberately the LOWEST precedence of anything here. Every rule above
        // is a fact about the agent, and none of them may be overwritten by a
        // fact about the user; this speaks for exactly the rows that have
        // nothing of their own to say, which is the only kind the switch was
        // ever pressed on. Amber rather than a lit-but-colourless row, because
        // amber is what this panel calls "your move", and a session standing by
        // with nothing in flight is waiting on precisely one thing.
        guard pickedUp else { return observed }
        return (.fault, "standing by",
                "You switched this session on. It is alive with nothing in flight, "
                + "waiting for what you tell it next.")
    }
}

final class VerdictAgreesWithTheOldLampTests: XCTestCase {

    /// Every shape the file can be in.
    private let activities: [SessionActivity?] = [
        nil,
        .working,
        .idle,
        .stalled(reason: "silent for 3h, nothing written since it started this"),
        .blocked(reason: "stream disconnected before completion: error sending request"),
    ]

    /// Every shape the process can be in, including the two that used to be
    /// indistinguishable from "idle".
    private func processes() -> [(label: String, live: LiveSession?)] {
        func session(status: String?, waitingFor: String? = nil,
                     startedAt: Double? = nil) -> LiveSession {
            LiveSession(harness: CodexAdapter().id, pid: 1, sessionId: "s",
                        cwd: "/tmp", status: status, name: nil,
                        waitingFor: waitingFor, kind: nil, startedAt: startedAt)
        }
        return [
            ("no process at all", nil),
            ("present, no status", session(status: nil)),
            ("busy", session(status: "busy")),
            ("idle", session(status: "idle")),
            ("waiting on a dialog", session(status: "waiting",
                                            waitingFor: Readiness.dialogOpen)),
            ("waiting on a permission", session(status: "waiting",
                                                waitingFor: Readiness.permissionPrompt)),
            ("waiting, unspecified", session(status: "waiting", waitingFor: nil)),
            ("busy and freshly started", session(status: "busy", startedAt: 4_000_000_000)),
            ("idle and freshly started", session(status: "idle", startedAt: 4_000_000_000)),
        ]
    }

    private func lamp(for state: SessionState) -> Lamp {
        switch state {
        case .working: return .working
        case .blocked: return .fault
        case .quiet:   return .running
        }
    }

    func testTheArbiterAgreesWithTheOldFunctionEverywhere() {
        let old = Date(timeIntervalSince1970: 3_000_000)
        let boundaries: [SessionActivity.TurnBoundary?] = [
            nil,
            .init(kind: .userPromptSubmit, at: old),
            .init(kind: .stop, at: old),
        ]
        var compared = 0

        for activity in activities {
            for (label, live) in processes() {
                for boundary in boundaries {
                    for pickedUp in [false, true] {
                        for isInFlight in [false, true] {
                            let evidence = activity.map {
                                SessionActivity.Evidence(activity: $0, observedAt: old,
                                                         modifiedAt: old)
                            }
                            let reference = LegacyLamp.lampAndReason(
                                for: evidence, sessionId: "s", live: live,
                                boundary: boundary, pickedUp: pickedUp,
                                isInFlight: isInFlight)

                            // The same `resumed` the reference computes for itself,
                            // so the two are driven by identical facts.
                            let resumed = AgentRestart.resumed(
                                startedAt: live?.startedAtDate,
                                lastWord: AgentRestart.lastWord(observedAt: evidence?.observedAt,
                                                                boundary: boundary))
                            let verdict = SessionVerdict.resolve(
                                process: SessionVerdict.testimony(of: live, resumed: resumed),
                                file: activity.map { Testimony.says($0) } ?? .silent,
                                resumed: resumed, pickedUp: pickedUp, isInFlight: isInFlight)

                            let where_ = "\(label) | file \(activity.map(String.init(describing:)) ?? "silent") "
                                + "| boundary \(boundary?.kind.rawValue ?? "none") "
                                + "| pickedUp \(pickedUp) | inFlight \(isInFlight)"
                            XCTAssertEqual(lamp(for: verdict.state), reference.lamp,
                                           "lamp disagrees: \(where_)")
                            XCTAssertEqual(verdict.because, reference.reason,
                                           "reason disagrees: \(where_)")
                            XCTAssertEqual(verdict.detail, reference.detail,
                                           "detail disagrees: \(where_)")
                            compared += 1
                        }
                    }
                }
            }
        }
        // A differential test that silently compared nothing would pass.
        XCTAssertEqual(compared, activities.count * processes().count * 3 * 2 * 2)
        XCTAssertGreaterThan(compared, 500)
    }
}

/// What the rules must be true of, regardless of what they currently are.
///
/// These need no oracle, which is why they are the half that can catch a NEW
/// bug rather than only a regression. Each one is a property the 30 Aug to
/// 01 Sep bugs violated.
final class VerdictInvariantTests: XCTestCase {

    private let everyProcessTestimony: [Testimony<ProcessSays>] = [
        .outOfScope, .silent,
        .says(.alive), .says(.busy), .says(.idle),
        .says(.waiting(short: "asking you", full: "It is asking you something.")),
    ]

    private let everyFileTestimony: [Testimony<SessionActivity>] = [
        .outOfScope, .silent,
        .says(.working), .says(.idle),
        .says(.stalled(reason: "silent for 3h")),
        .says(.blocked(reason: "stream disconnected")),
    ]

    /// TOTALITY. Every combination resolves to a defined verdict. Nothing falls
    /// through, crashes, or reaches a default. This is the invariant that a
    /// fifth witness or a sixth activity case would break loudly instead of
    /// quietly.
    func testEveryCombinationResolves() {
        var seen = Set<SessionState>()
        var count = 0
        for process in everyProcessTestimony {
            for file in everyFileTestimony {
                for resumed in [false, true] {
                    for pickedUp in [false, true] {
                        for isInFlight in [false, true] {
                            let verdict = SessionVerdict.resolve(
                                process: process, file: file, resumed: resumed,
                                pickedUp: pickedUp, isInFlight: isInFlight)
                            seen.insert(verdict.state)
                            count += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(count, 6 * 6 * 2 * 2 * 2)
        XCTAssertEqual(seen, [.working, .blocked, .quiet],
                       "every state must be reachable, or a rule is dead")
    }

    /// THE BUG, AS A PROPERTY. A witness that did not speak must never change a
    /// verdict. `outOfScope` and `silent` must be indistinguishable in effect
    /// from each other, and neither may act like an observation.
    ///
    /// Every one of the five bugs violated this: a silent process spelled
    /// "idle" turned a working session grey; a missing Stop spelled "busy" held
    /// a dead one blue.
    func testASilentWitnessNeverChangesTheVerdict() {
        for file in everyFileTestimony {
            for resumed in [false, true] {
                for pickedUp in [false, true] {
                    for isInFlight in [false, true] {
                        let outOfScope = SessionVerdict.resolve(
                            process: .outOfScope, file: file, resumed: resumed,
                            pickedUp: pickedUp, isInFlight: isInFlight)
                        let silent = SessionVerdict.resolve(
                            process: .silent, file: file, resumed: resumed,
                            pickedUp: pickedUp, isInFlight: isInFlight)
                        XCTAssertEqual(outOfScope, silent,
                                       "a blind witness and a quiet one must weigh the same")
                    }
                }
            }
        }
    }

    /// A process that is merely ALIVE says nothing about working versus quiet,
    /// so it must weigh exactly as much as saying nothing at all. This is the
    /// `?? "idle"` bug expressed as a law.
    func testAliveWeighsTheSameAsSilence() {
        for file in everyFileTestimony {
            for resumed in [false, true] {
                let alive = SessionVerdict.resolve(process: .says(.alive), file: file,
                                                   resumed: resumed)
                let silent = SessionVerdict.resolve(process: .silent, file: file,
                                                    resumed: resumed)
                XCTAssertEqual(alive.state, silent.state,
                               "being alive is not a claim about being idle")
            }
        }
    }

    /// And the converse, so the invariant above cannot be satisfied by making
    /// the process witness powerless: a REAL idle claim still outranks a file
    /// that looks busy. That is the 18 Aug ruling and it stays.
    func testARealIdleClaimStillOutranksTheFile() {
        let quiet = SessionVerdict.resolve(process: .says(.idle), file: .says(.working))
        XCTAssertEqual(quiet.state, .quiet)
        XCTAssertEqual(quiet.witness, .process)

        let working = SessionVerdict.resolve(process: .says(.alive), file: .says(.working))
        XCTAssertEqual(working.state, .working, "and 'alive' must not do the same")
    }

    /// An error in the file is a fact, and no process status may contradict it.
    /// A session sitting on a usage limit is idle by every measure the API has.
    func testAFileErrorSurvivesEveryProcessStatus() {
        for process in everyProcessTestimony {
            let verdict = SessionVerdict.resolve(
                process: process, file: .says(.blocked(reason: "hit your usage limit")))
            // The one thing that legitimately outranks it is the process saying
            // it is holding for a human, which is also a needs-you state.
            XCTAssertEqual(verdict.state, .blocked,
                           "an error must never resolve to working or quiet")
        }
    }

    /// Facts about the USER never overwrite facts about the agent. `pickedUp`
    /// speaks only for a row that had nothing of its own to say.
    func testUserFactsNeverOverwriteAgentFacts() {
        for process in everyProcessTestimony {
            for file in everyFileTestimony {
                let plain = SessionVerdict.resolve(process: process, file: file)
                let switched = SessionVerdict.resolve(process: process, file: file,
                                                      pickedUp: true, isInFlight: true)
                guard plain.state != .quiet else { continue }
                XCTAssertEqual(plain, switched,
                               "a row with something to say must ignore the user's switch")
            }
        }
    }

    /// The verdict always names who decided, so a wrong lamp is a log line
    /// rather than a screenshot.
    func testEveryVerdictNamesItsWitness() {
        for process in everyProcessTestimony {
            for file in everyFileTestimony {
                let verdict = SessionVerdict.resolve(process: process, file: file)
                if verdict.witness == .none {
                    XCTAssertEqual(verdict.state, .quiet,
                                   "only a session nobody could see may name no witness")
                }
            }
        }
    }
}

/// The capability model, consulted rather than merely recorded.
final class TestimonyScopeTests: XCTestCase {

    /// A harness with no liveness registry is BLIND to a missing session, not
    /// silent about it. Before this, nothing in the state path read
    /// `registersWithLiveness` at all: it documented the difference between the
    /// harnesses without enforcing it anywhere.
    func testAHarnessWithNoRegistryIsOutOfScope() {
        XCTAssertEqual(SessionVerdict.testimony(of: nil, harness: CodexAdapter().id),
                       .outOfScope)
    }

    /// A harness that does register and did not find the session has genuinely
    /// looked.
    func testAHarnessWithARegistryIsMerelySilent() {
        XCTAssertEqual(SessionVerdict.testimony(of: nil, harness: ClaudeCodeAdapter().id),
                       .silent)
    }

    /// Without a harness we do not guess which of the two it is. Both weigh the
    /// same, so this costs nothing.
    func testAnUnknownHarnessIsSilentRatherThanGuessed() {
        XCTAssertEqual(SessionVerdict.testimony(of: nil), .silent)
    }

    /// A present process with no status is ALIVE, which is the case the old
    /// code spelled "idle".
    func testAProcessWithNoStatusIsAliveNotIdle() {
        let live = LiveSession(harness: CodexAdapter().id, pid: 1, sessionId: "s",
                               cwd: "/tmp", status: nil, name: nil, waitingFor: nil)
        XCTAssertEqual(SessionVerdict.testimony(of: live), .says(.alive))
    }
}
