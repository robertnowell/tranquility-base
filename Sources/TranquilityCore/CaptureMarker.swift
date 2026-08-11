import Foundation

/// A file that exists exactly while the microphone is open.
///
/// It has one reader: `scripts/relaunch.sh`, which force-quits the app in order
/// to rebuild it. The recorder holds an utterance in memory and flushes once at
/// key-up (a deliberate choice — see Recorder's header), so a kill mid-sentence
/// does not lose a file, it loses the words outright.
///
/// That was survivable while relaunching was a decision somebody made. It became
/// a hazard when a merge started firing it: nobody is choosing the moment any
/// more, and the moment can now be the middle of your sentence.
///
/// Deliberately a FILE rather than a query or a socket. The process that needs
/// the answer is a shell script whose whole job is to kill this app — it has to
/// work when the app is unresponsive, and it has to work from bash.
public enum CaptureMarker {

    public static var url: URL {
        QueueStore.supportDirectory.appendingPathComponent("capturing")
    }

    /// How often a live capture re-stamps the marker. The writer is a timer on
    /// its own queue, deliberately not the main one: the main queue has been
    /// wedged by an unwinding ObjC exception in this app before, and a liveness
    /// signal that dies with the thread it is reporting on is not a liveness
    /// signal.
    public static let heartbeat: TimeInterval = 5

    /// How old a stamp may be before readers treat the writer as dead.
    ///
    /// This used to be 180s and the stamp was written once, at the start. The
    /// two facts together meant the marker was answering "how long has this
    /// capture been running", when the only question worth asking is "is the
    /// process that opened this microphone still alive". Those agree for a
    /// push-to-talk utterance, where the longest observed was 92 seconds. They
    /// disagree for hands-free, which has no bound at all — and on 10 Aug they
    /// disagreed at a cost: a four-minute capture read as stale at 230s and was
    /// destroyed by `scripts/relaunch.sh`.
    ///
    /// Now the stamp is refreshed while the capture runs, so age means "silence
    /// from the writer" and four times the heartbeat is generous: it survives a
    /// stalled write or a busy queue, and still frees a genuinely dead process's
    /// marker in twenty seconds rather than three minutes.
    ///
    /// `scripts/relaunch.sh` hardcodes this same number — it is a shell script
    /// and cannot read Swift. Change both or neither.
    public static let staleAfter: TimeInterval = 20

    public static func begin(now: Date = Date()) { write(to: url, now: now) }

    /// Re-stamp a marker that is already ours. Identical to `begin` in effect;
    /// named separately because the call sites mean different things and a
    /// reader of `Recorder` should not have to work out why a capture "begins"
    /// every five seconds.
    public static func refresh(now: Date = Date()) { write(to: url, now: now) }

    public static func end() { remove(at: url) }

    public static func isCapturing(now: Date = Date()) -> Bool {
        decide(contents: try? String(contentsOf: url, encoding: .utf8), now: now)
    }

    // MARK: - Seams
    //
    // The decision is a pure function of the file's contents, and the file
    // operations take an explicit URL. Both exist so the tests never touch the
    // live support directory: the app is normally RUNNING while tests are, and a
    // test that dropped a real marker there would make a real relaunch wait on
    // a microphone nobody opened.

    /// Written non-atomically on purpose: this sits on the mic-open path, and a
    /// temp-file-plus-rename buys durability nothing here wants. A torn write
    /// fails to parse, and an unparseable marker reads as "not capturing" — the
    /// same answer as no marker at all.
    static func write(to url: URL, now: Date) {
        try? String(Int(now.timeIntervalSince1970))
            .write(to: url, atomically: false, encoding: .utf8)
    }

    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// True only while a capture is both marked AND recent. Every failure mode —
    /// absent, unreadable, garbage, negative, ancient — resolves to false,
    /// because the cost of a false positive is a relaunch that never happens,
    /// and relaunching is the thing that keeps the app current.
    static func decide(contents: String?, now: Date) -> Bool {
        guard let contents,
              let started = TimeInterval(
                contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        let age = now.timeIntervalSince1970 - started
        return age >= 0 && age < staleAfter
    }
}
