import Foundation

/// Words on their way to a session: from the moment a capture closes on a
/// target to the moment the dispatch resolves.
///
/// The grid's lamp is otherwise read from the target's transcript
/// (`SessionActivity`), which deliberately infers nothing it cannot see. A
/// reply in flight is invisible there BY DEFINITION: the words have not landed
/// in the file yet, and `⌃⌥` already took the session out of the waiting set
/// when it was heard. So the row fell through to the quiet socket for the whole
/// transcribe → confirm → dispatch window — the one window where the user knows
/// perfectly well that something is happening, because they caused it. Reported
/// 10 Aug: "it shows as idle in the gap between when I dispatched audio and
/// when it's confirmed as being sent."
///
/// This is the one fact about a session the app can state FIRST-HAND rather
/// than infer — it is the sender. That is why it is an overlay applied to the
/// row, and not a new case inside `SessionActivity`: the tail of a transcript
/// is still the only honest source for what the AGENT is doing, and this says
/// something about what WE are doing to it.
///
/// Every entry carries a ceiling, and that is the load-bearing part. The
/// clear-sites are many — six outcome cases across two functions, two supersede
/// paths, a cancel closure, two catch blocks — and one missed clear would pin a
/// lamp blue on a session doing nothing at all, which is the precise failure
/// `SessionActivity.freshness` already exists to prevent on the other side of
/// the seam. Bounding the entry means a missed clear costs seconds rather than
/// forever, so correctness here does not depend on enumerating every exit.
public struct DeliveryInFlight: Sendable, Equatable {
    /// How long a delivery may claim the lamp without resolving.
    ///
    /// The real window is transcription (seconds), plus the 4s undo countdown,
    /// plus dispatch: a 250ms settle, up to 10s of read-back verification, and
    /// a 3s retry of the Return. Around 30s at its worst, so 90 is headroom
    /// rather than a second deadline the user would feel. It is not tuned to
    /// the happy path — it exists for the paths that never come back.
    public static let ceiling: TimeInterval = 90

    private struct Delivery: Equatable {
        let at: Date
        /// The waiting event this reply ANSWERS, if it was answering one. Green
        /// is only a lie about the turn being answered — see `isInFlight`.
        let answering: Int64?
    }

    private var started: [String: Delivery] = [:]

    public init() {}

    /// The capture closed on this session and the words are now ours to deliver.
    ///
    /// `answering` is the waiting event's `latestId` at the moment the capture
    /// closed, or nil when the reply answers nothing in the waiting set. It is
    /// what lets the lamp tell "green is stale, you are answering it right now"
    /// apart from "a NEWER turn arrived while you were talking" — the second is
    /// still genuinely unread, and must stay green.
    public mutating func began(sessionId: String, answering: Int64? = nil, at: Date = Date()) {
        started[sessionId] = Delivery(at: at, answering: answering)
    }

    /// The dispatch resolved — any way it resolved. A failure clears too: the
    /// lamp goes back to whatever the transcript honestly says, which for a
    /// send that never landed is the truth.
    public mutating func finished(sessionId: String) {
        started.removeValue(forKey: sessionId)
    }

    public func isInFlight(_ sessionId: String, now: Date = Date()) -> Bool {
        guard let d = started[sessionId] else { return false }
        return now.timeIntervalSince(d.at) <= Self.ceiling
    }

    /// Whether a delivery in flight has made this session's GREEN row stale.
    ///
    /// Green means "there is something here you have not answered". From the
    /// moment the capture closes until dispatch resolves, that is false in the
    /// most misleading way available: the user has just spoken to this exact
    /// turn, and the cursor does not advance until the send confirms
    /// (`Coordinator.confirmAndSend`), so the row goes on claiming to want them.
    /// Reported 10 Aug: "it shows the lamp still is green, which is actually
    /// worse than idle — now it looks like it's still waiting on me, and it's a
    /// lie. I literally just spoke to this session."
    ///
    /// Bounded to the turn being answered. If a NEWER event arrives while the
    /// reply is in flight — the agent finished something else, a second turn
    /// landed — `latestId` moves past what we are answering, and that row is
    /// unread work the user has genuinely not seen. Green wins, and must.
    public func supersedesWaiting(
        _ sessionId: String, latestId: Int64, now: Date = Date()
    ) -> Bool {
        guard let d = started[sessionId], now.timeIntervalSince(d.at) <= Self.ceiling,
              let answering = d.answering
        else { return false }
        return latestId <= answering
    }

    /// Drop entries the ceiling has expired. The lamp is already correct
    /// without this — `isInFlight` gates on the ceiling itself — so this is
    /// housekeeping on the poller, not a correctness step.
    public mutating func prune(now: Date = Date()) {
        started = started.filter { now.timeIntervalSince($0.value.at) <= Self.ceiling }
    }

    /// Sessions currently claiming the lamp. Test and log surface only.
    public func inFlightSessions(now: Date = Date()) -> Set<String> {
        Set(started.keys.filter { isInFlight($0, now: now) })
    }
}
