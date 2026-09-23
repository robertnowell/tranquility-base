import Foundation

/// The fault spine: which rows went amber, once per new reason per agent,
/// from the same rows the grid draws.
///
/// Beside `LampWatch` (the lamp spine) and `ExitWatch` (the exit spine), and
/// fed from the same tick, for the same reason both of those exist: a record
/// derived from anything other than the rows on screen can disagree with the
/// screen. What it feeds is different. The lamp spine is a PostHog event with
/// a classified word; this hands `Failures` the row's own words under the
/// witness's kind, so an agent stuck on anything reaches Sentry and the Slack
/// route the way a launch death or a failed update does.
///
/// Why it did not exist until 23 Sep 2026: a user in Dallas sat on
/// "Connection lost mid-response" through the last minutes of one session
/// and the first minute of the next, took a screenshot and wrote in. The lamp
/// spine had recorded `to=fault reason=network` three times. Nothing else had
/// heard. Ruled that day: "basically every amber lamp I want to know about",
/// and the person's remedy is the door, not a caption, since amber already
/// goes straight to the agent (15 Sep).
///
/// Two rules, both borrowed from `LampWatch`:
/// - **The first tick seeds and says nothing.** A launch that finds standing
///   faults must not page for each of them; they were faults before the app
///   was, and the page would carry nothing new.
/// - **Once per reason.** A row that stays on the same words across ticks is
///   one failure, not one per second. A row whose words CHANGE is a new
///   failure, because something new happened to it.
public struct FaultWatch: Sendable {
    private var seen: [String: SessionRow.Fault] = [:]
    private var seeded = false

    public init() {}

    /// The rows that are newly at fault on this tick, in grid order.
    public mutating func observe(_ rows: [SessionRow]) -> [SessionRow] {
        var current: [String: SessionRow.Fault] = [:]
        for row in rows {
            if let fault = row.fault { current[row.id] = fault }
        }
        let prior = seen
        seen = current
        guard seeded else {
            seeded = true
            return []
        }
        return rows.filter { row in
            guard let fault = row.fault else { return false }
            return prior[row.id] != fault
        }
    }
}
