import Foundation

/// A file that exists exactly while a hands-free session is up.
///
/// The sibling of `CaptureMarker`, for the case that marker was never able to
/// answer. Read that file's header first: the protocol, the reasoning about
/// atomic writes and the staleness rule are all there and all apply here.
///
/// Why a second marker rather than folding this into the first. `CaptureMarker`
/// means "something said is still in flight" — seconds long, and every reader
/// of it WAITS, because the utterance will land shortly and then the app can be
/// stopped. A hands-free session is not like that. It is open-ended, it can run
/// for an hour, and the right answer is not to wait for it but to refuse: an
/// install or a relaunch during one drops the call mid-sentence, which is what
/// happened repeatedly on 23 Sep while three fixes were being delivered into
/// the middle of the session testing them. Two different answers, so two
/// different questions, so two files.
///
/// Deliberately a FILE, for the same reason as the other one: the process that
/// needs the answer is a shell script whose whole job is to kill this app.
public enum HandsFreeMarker {

    public static var url: URL {
        QueueStore.supportDirectory.appendingPathComponent("hands-free")
    }

    /// How old a stamp may be before readers treat the writer as dead. The app
    /// re-stamps every second from the same timer that settles `CaptureMarker`,
    /// so twenty seconds is generous against a stalled write and still frees a
    /// dead process's marker quickly.
    ///
    /// `scripts/lib/app-process.sh` hardcodes this same number — it is a shell
    /// script and cannot read Swift. Change both or neither.
    public static let staleAfter: TimeInterval = 20

    /// Derived every second from the app's own state rather than written at the
    /// two ends of a session, so a session that ends in a way nobody wired
    /// cannot leave the marker standing and hold off every future install.
    public static func settle(live: Bool, now: Date = Date()) {
        if live {
            try? String(Int(now.timeIntervalSince1970))
                .write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func isLive(now: Date = Date()) -> Bool {
        decide(contents: try? String(contentsOf: url, encoding: .utf8), now: now)
    }

    /// A pure function of the file's contents, so tests never touch the live
    /// support directory. Every failure mode — absent, unreadable, garbage,
    /// negative, ancient — resolves to false: the cost of a false positive is
    /// an app that never updates again.
    static func decide(contents: String?, now: Date) -> Bool {
        guard let contents,
              let stamped = TimeInterval(
                contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        let age = now.timeIntervalSince1970 - stamped
        return age >= 0 && age < staleAfter
    }
}
