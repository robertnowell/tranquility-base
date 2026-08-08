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

    /// A marker orphaned by a crash must not wedge every future relaunch, so it
    /// carries its start time and readers age it out. Three minutes is far past
    /// any real push-to-talk utterance — the longest observed is 92 seconds — and
    /// far short of "silently stopped protecting anything".
    public static let staleAfter: TimeInterval = 180

    public static func begin(now: Date = Date()) { write(to: url, now: now) }

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
