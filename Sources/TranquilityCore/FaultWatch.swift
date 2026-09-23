import Foundation

/// The fault spine: which rows went amber on a sentence the HARNESS wrote,
/// once per new sentence per agent, from the same rows the grid draws.
///
/// Beside `LampWatch` (the lamp spine) and `ExitWatch` (the exit spine), and
/// fed from the same tick, for the same reason both of those exist: a record
/// derived from anything other than the rows on screen can disagree with the
/// screen. What it feeds is different. The lamp spine is a PostHog event with
/// a classified word; this hands `Failures` the harness's own sentence, so an
/// agent stuck on an error reaches Sentry and the Slack route the way a
/// launch death or a failed update does.
///
/// Why it did not exist until 23 Sep 2026: a user in Dallas sat on
/// "Connection lost mid-response" through the last minutes of one session
/// and the first minute of the next, took a screenshot and wrote in. The lamp
/// spine had recorded `to=fault reason=network` three times. Nothing else had
/// heard. The morning's only Slack alert was a DNS blip on a different Mac.
///
/// Two rules, both borrowed from `LampWatch`:
/// - **The first tick seeds and says nothing.** A launch that finds standing
///   faults must not page for each of them; they were faults before the app
///   was, and (Sentry groups by kind) the page would carry nothing new.
/// - **Once per sentence.** A row that stays on the same fault across ticks is
///   one failure, not one per second. A row whose sentence CHANGES is a new
///   failure, because the harness said something new.
public struct FaultWatch: Sendable {
    private var seen: [String: String] = [:]
    private var seeded = false

    public init() {}

    /// The rows that are newly at fault on this tick, in grid order.
    public mutating func observe(_ rows: [SessionRow]) -> [SessionRow] {
        var current: [String: String] = [:]
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
