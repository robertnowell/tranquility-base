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
}
