import Foundation
import TranquilityCore

/// What a self-test drill needs from the panel: drive it into a state, read
/// a measurement back. Named 23 Aug (App-lane P2, "name the coupling before
/// moving") ahead of the actual move — see `Widgets.swift`'s own doc comment
/// for the sibling half of this pass, and `docs/architecture-program.md`'s
/// P4 for where the ~3,200 lines of drill/pose code this seam is for
/// eventually go.
///
/// Sized deliberately narrow, not an exhaustive mirror of everything a drill
/// touches today. A survey of all 25 self-test functions (44 `SelfTest.
/// report`/`skipped` call sites, including the 1,342-line `selfTest()` and
/// the `pose(_:)` fixture switch) found the coupling is NOT an access-
/// control problem — nearly every "drive the panel" method a drill calls
/// (`showAnnouncement`, `showArming`, `showListening`, `showTranscribing`,
/// `showResult`, `endCapture`, `highlight(upTo:)`, `adoptTarget`, `pose`,
/// `poseSnapshot`) is already `internal`, StatusHUD's real production API,
/// not test-only. What IS coupled is structural: those 25 functions are
/// interleaved inside StatusHUD's class body alongside production code, and
/// most of what each one reads BACK is a one-off private label or geometry
/// value that belongs to exactly one drill — `noWordsNotice`, `placardFont`,
/// `nameLabel`, and dozens like them. Naming every one of those as a
/// protocol requirement would document today's incidental implementation,
/// not a real seam; they stay direct reaches wherever a drill body ends up
/// living once P4 actually moves it.
///
/// So this protocol carries exactly what's genuinely reusable: the driving
/// primitives nearly every drill calls (restated here, not reimplemented —
/// `StatusHUD` already satisfies every requirement for free), plus the
/// small set of readouts more than one drill needs. `inkBrightLength` is
/// the one of those confirmed so far; more join as P4 actually moves drills
/// and finds which one-off reaches turn out to recur.
@MainActor
protocol TestSurface: AnyObject {
    // MARK: - Driving primitives

    func adoptTarget(sessionId: String, pid: Int?, label: String, cwd: String?)

    @discardableResult
    func showAnnouncement(
        spoken: SanitizedSpokenText, sessionId: String, pid: Int?, project: String,
        cwd: String?, eventId: String?, placard: String?
    ) -> Bool

    @discardableResult
    func showArming(target: String?) -> Bool
    func revertArming(because reason: String)

    func showListening(level: @escaping () -> Float)

    func showTranscribing(_ message: String,
                          onCancel: @escaping () -> Void,
                          onRetry: @escaping () -> Void)

    func showResult(_ message: String,
                    about: (sessionId: String, pid: Int?, label: String)?)

    func endCapture(because reason: String)

    func highlight(upTo index: Int)

    // MARK: - Shared readouts

    /// How many characters are currently painted as spoken — the ink drill's
    /// measurement, read from the pixels rather than the model, so a
    /// regression where the two disagree is exactly what it would catch.
    var inkBrightLength: Int { get }
}

/// `StatusHUD` already implements every requirement above as its own real
/// production API — this conformance adds nothing, which is the point:
/// P2's job is naming the seam, not building a second implementation of it.
extension StatusHUD: TestSurface {}
