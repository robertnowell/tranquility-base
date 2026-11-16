import Foundation
import TranquilityCore

/// The one result event for every start of an agent's process (ruled
/// 14 Nov 2026). The tap recorded `agent_revived` and the reply recorded
/// `reply_started_process`, so a falling revive count proved nothing.
///
/// The name and the three `outcome` words are the tap's, kept so the series
/// from before continues. `result` is the exact answer, and `via` is the
/// door that asked.
enum AgentStartRecord {
    static func record(_ outcome: AgentStart.Outcome, via: AgentStart.Via, sessionId: String) {
        let legacy: String
        switch outcome {
        case .started: legacy = "revived"
        case .running, .joined: legacy = "already_awake"
        case .waitingOnQuestion, .heldBy, .unknown, .refused: legacy = "not_revived"
        }
        Track.record("agent_revived", [
            "outcome": .token(legacy), "result": .token(outcome.word),
            "via": .token(via.rawValue),
            "agent_id": Track.hash(sessionId),
        ])
    }
}
