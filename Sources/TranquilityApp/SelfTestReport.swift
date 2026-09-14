import Foundation

/// One machine-readable verdict per launch self-test.
///
/// The panel's self-tests have always asserted the right things and logged them
/// as raw fields — `cancellable=true cancelled=true sent=false`. A person reads
/// that correctly. A script cannot: `sent=false` is the PASS there (the send was
/// cancelled, so it must not have sent), while `armed=false` two lines later is
/// a failure. Scanning the log for `=false` would fail every healthy launch,
/// which is how a gate gets switched off in a day.
///
/// So the expectation is stated where it is known — at the call site, in the
/// `checks` array — and the verdict comes out in one shape the gate can read.
/// `selftest-arm` in main.swift already ends its lines this way; this is that
/// convention, made reusable rather than retyped.
///
/// The raw fields are still printed after the verdict. A gate needs the verdict;
/// a human debugging a failure needs the fields, and losing them to make the log
/// machine-friendly would trade a diagnosis for a boolean.
enum SelfTest {
    /// `checks` are (name, didPass) — each already normalised so `true` is the
    /// desired outcome. Write `("notSent", !sent)`, never `("sent", sent)`.
    static func report(_ name: String, _ checks: [(String, Bool)]) {
        let failed = checks.filter { !$0.1 }.map(\.0)
        let verdict = failed.isEmpty ? "PASS" : "FAIL(\(failed.joined(separator: ",")))"
        let fields = checks.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        Permissions.log("selftest \(name): \(verdict) — \(fields)")
    }

    /// A self-test that could not run is not a self-test that passed. Recorded
    /// distinctly so a permanently-skipped drill cannot masquerade as coverage.
    static func skipped(_ name: String, because reason: String) {
        Permissions.log("selftest \(name): SKIP — \(reason)")
    }

    /// For the drills that report on a timer, seconds after the call that armed
    /// them: a verdict is only a verdict if it is about the panel the drill set
    /// up. Since the slate now stands down the moment a real key arrives
    /// (`yieldTheSlateToAGesture`), these can find the USER's panel there
    /// instead, and asserting against it would be measuring a stranger.
    ///
    /// SKIP rather than PASS, because a PASS is the worse error of the two: a
    /// claim of coverage over a launch where the drill never really ran. And
    /// SKIP rather than silence, because a drill that quietly reports nothing
    /// is how a slate loses a verdict without anybody noticing.
    static func report(_ name: String, _ checks: [(String, Bool)],
                       skippedBecauseOfAGesture interrupted: Bool) {
        guard !interrupted else {
            skipped(name, because: "a real gesture took the panel mid-slate")
            return
        }
        report(name, checks)
    }

    /// The line that says the slate is finished, so nothing has to guess how
    /// long a slate takes.
    ///
    /// Deliberately NOT in the `selftest <name>: <verdict>` shape the gate
    /// scans for verdicts: it is a boundary, not a drill, and counting it as
    /// one would let a run with zero drills look like a run with one.
    static let slateCompleteMarker = "selftest: slate complete"

    static func slateComplete() {
        Permissions.log(slateCompleteMarker)
        // Every verdict on disk before the marker is answered for. Writes are
        // asynchronous now (Permissions.logQueue), and check-selftests.sh reads
        // the FILE — so an unflushed verdict is indistinguishable from a drill
        // that never ran, which is the exact failure this whole slate exists to
        // make impossible.
        Permissions.flushLog()
    }
}
