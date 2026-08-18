import Foundation
import XCTest
@testable import TranquilityCore

/// The gate is four lines of logic, and every one of them is a ruling.
///
/// Ruled 18 Aug, replacing a design with a stale-drop timer, a coalescing window
/// and a deferred replay: *"Anything complicated here is basically just alert
/// channel open or alert channel not open. We don't need to enqueue things and
/// then play a bunch of alerts at the end. That's just surface for bugs."*
///
/// So these tests exist mostly to hold the SHAPE — a cue that cannot play is
/// dropped, not remembered — and to pin the one asymmetry, which is easy to
/// "tidy up" into a bug: `listening` must survive `userIsSpeaking`, because the
/// microphone being open is the thing `listening` announces.
final class EarconGateTests: XCTestCase {

    private let quiet = EarconGate(userIsSpeaking: false, agentIsSpeaking: false)

    func testQuietChannelAllowsEverything() {
        for cue in EarconGate.Cue.allCases {
            XCTAssertTrue(quiet.allows(cue), "\(cue) should play on a quiet channel")
            XCTAssertNil(quiet.refusal(for: cue))
        }
    }

    func testAgentSpeakingVetoesEverything() {
        let gate = EarconGate(userIsSpeaking: false, agentIsSpeaking: true)
        for cue in EarconGate.Cue.allCases {
            XCTAssertFalse(gate.allows(cue), "\(cue) must not talk over the voice")
            XCTAssertEqual(gate.refusal(for: cue), "agent is speaking")
        }
    }

    /// The asymmetry. `listening` fires the moment audio starts flowing, so
    /// `userIsSpeaking` is true BY CONSTRUCTION when it wants to play. A gate that
    /// treats it like the others silences it permanently.
    func testListeningSurvivesAnOpenMicButNothingElseDoes() {
        let gate = EarconGate(userIsSpeaking: true, agentIsSpeaking: false)
        XCTAssertTrue(gate.allows(.listening))
        XCTAssertNil(gate.refusal(for: .listening))
        for cue in [EarconGate.Cue.dispatched, .returned, .needsYou] {
            XCTAssertFalse(gate.allows(cue), "\(cue) must not play into an open mic")
            XCTAssertEqual(gate.refusal(for: cue), "mic is open")
        }
    }

    /// Both vetoes at once: the agent's takes precedence, including over the
    /// `listening` exemption. In practice the ⌥-while-speaking gesture stops the
    /// voice before audio flows, so this state is transient — but if it is ever
    /// reached, not talking over speech is the stronger rule.
    func testAgentSpeakingOutranksTheListeningExemption() {
        let gate = EarconGate(userIsSpeaking: true, agentIsSpeaking: true)
        XCTAssertFalse(gate.allows(.listening))
        XCTAssertEqual(gate.refusal(for: .listening), "agent is speaking")
    }

    /// `allows` and `refusal` must never disagree — they are read at the same
    /// call site, one to decide and one to explain, and a mismatch would log a
    /// reason for a cue that played.
    func testRefusalAgreesWithAllowsAcrossEveryState() {
        for user in [true, false] {
            for agent in [true, false] {
                let gate = EarconGate(userIsSpeaking: user, agentIsSpeaking: agent)
                for cue in EarconGate.Cue.allCases {
                    XCTAssertEqual(gate.allows(cue), gate.refusal(for: cue) == nil,
                                   "user=\(user) agent=\(agent) cue=\(cue)")
                }
            }
        }
    }

    /// The generator writes kebab-case filenames; the app derives them from these
    /// raw values. If a case is renamed without renaming the file, the cue goes
    /// silent and only a log line says so — so pin the contract here.
    func testRawValuesAreTheFilenameContract() {
        XCTAssertEqual(EarconGate.Cue.listening.rawValue, "listening")
        XCTAssertEqual(EarconGate.Cue.dispatched.rawValue, "dispatched")
        XCTAssertEqual(EarconGate.Cue.returned.rawValue, "returned")
        // needsYou maps to "needs-you.wav" in Earcons.fileName — deliberately the
        // one that does not match, because the generator owns the filenames.
        XCTAssertEqual(EarconGate.Cue.needsYou.rawValue, "needsYou")
        XCTAssertEqual(EarconGate.Cue.allCases.count, 4,
                       "a fifth cue needs a ruling, not just a case — see the ceiling of five")
    }
}
