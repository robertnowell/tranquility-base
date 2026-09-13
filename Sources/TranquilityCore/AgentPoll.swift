import CryptoKit
import Foundation

/// How a POLLED provider reaches the event model.
///
/// Providers emit events (#366). A provider with a stream does that directly;
/// a provider without one hands over a list, and this turns two consecutive
/// lists into the events between them. Both paths land in the same log, which
/// is the convergence point the whole design rests on: the event, not the
/// interface.
///
/// The rule this type exists to enforce is the cheap one and the important
/// one: **a digest that has not changed produces nothing.** A poller that
/// re-emits an unchanged session on every tick writes a spool line every few
/// seconds per agent, and the read-state watermarks are ordered by row id, so
/// every one of those lines moves the cursor past content nobody has seen. The
/// grid would go quiet while the agent was still asking.
///
/// The spool line itself is #372. This is the part that decides whether there
/// is one.
public enum AgentPoll {

    /// A content hash of everything a row or a card renders.
    ///
    /// Deliberately EXCLUDES `updatedAt`. Several vendors move that timestamp
    /// on a poll that changed nothing observable (a heartbeat, a re-read), and
    /// including it would make the digest change every tick, which is the exact
    /// failure this function exists to prevent. If the visible content is
    /// identical there is nothing to tell anybody.
    public static func digest(_ session: AgentSession) -> String {
        let parts = [session.id, session.provider, session.title,
                     session.state.rawValue, session.repository ?? "",
                     session.pullRequest?.absoluteString ?? "",
                     session.url?.absoluteString ?? ""]
        let joined = parts.joined(separator: "\u{0}")
        return SHA256.hash(data: Data(joined.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The events between two polls.
    ///
    /// A session absent from `before` appeared. One whose digest moved changed.
    /// One whose digest did not move produces nothing at all.
    ///
    /// A session that DISAPPEARS from the list produces nothing either, and
    /// that is deliberate rather than an omission: crobot's list endpoint has
    /// no creator filter and several vendors paginate, so absence from one page
    /// of one poll is not evidence that an agent ended. An ending is a state
    /// (`completed`, `failed`, `canceled`), and inventing one from a short list
    /// is the failed-poll bug in another costume.
    public static func events(from before: [AgentSession.ID: String],
                              to now: [AgentSession],
                              at: Date = Date())
        -> (events: [AgentEvent], digests: [AgentSession.ID: String]) {
        var events: [AgentEvent] = []
        var digests: [AgentSession.ID: String] = [:]
        for session in now {
            let d = digest(session)
            digests[session.id] = d
            guard let seen = before[session.id] else {
                events.append(AgentEvent(provider: session.provider, session: session.id,
                                         at: at, kind: .appeared(session)))
                continue
            }
            if seen != d {
                // The WHOLE session, never a delta, for the reason A2A's
                // resubscribe returns a full snapshot: a consumer that missed
                // an earlier event must not be able to stay wrong about the
                // state it is in now.
                events.append(AgentEvent(provider: session.provider, session: session.id,
                                         at: at, kind: .changed(session)))
            }
        }
        return (events, digests)
    }
}
