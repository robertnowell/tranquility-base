import XCTest
@testable import TranquilityCore

/// The guard that stands between an automatic relaunch and a live microphone.
///
/// Every case here is about which way this fails. A false NEGATIVE costs a
/// relaunch that waits when it needn't, or one that kills a recording. A false
/// POSITIVE — reading "capturing" when nothing is — wedges relaunches forever,
/// which silently reintroduces the problem the relaunch script exists to solve:
/// an app running a build nobody merged.
///
/// So: every unreadable, malformed, or ancient marker must read as NOT capturing.
final class CaptureMarkerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func stamp(secondsAgo: TimeInterval) -> String {
        String(Int(now.timeIntervalSince1970 - secondsAgo))
    }

    // MARK: - The protecting case

    func testAFreshMarkerMeansCapturing() {
        XCTAssertTrue(CaptureMarker.decide(contents: stamp(secondsAgo: 0), now: now))
        XCTAssertTrue(CaptureMarker.decide(contents: stamp(secondsAgo: 5), now: now))
        // One missed heartbeat is not death. The window is four of them, so a
        // stalled write or a busy queue costs nothing.
        XCTAssertTrue(CaptureMarker.decide(contents: stamp(secondsAgo: 19), now: now))
    }

    /// This case used to assert the opposite, and the reversal is the fix.
    ///
    /// The old marker was stamped once at the start and given a 180-second
    /// window, so the question it answered was "how long has this capture been
    /// running". That is the wrong question, and the two readings agree only
    /// for push-to-talk: hands-free has no length bound at all. On 10 Aug a
    /// four-minute capture aged past 180s, read as dead, and `relaunch.sh`
    /// destroyed it.
    ///
    /// A live capture now re-stamps every `heartbeat` seconds, so an old stamp
    /// means the writer stopped — whatever the microphone is doing. Protecting
    /// a long utterance is the heartbeat's job, and it is no longer this
    /// function's job to guess at durations.
    func testAnOldStampIsDeadEvenThoughUtterancesRunLonger() {
        XCTAssertFalse(CaptureMarker.decide(contents: stamp(secondsAgo: 92), now: now),
                       "a 92s-old stamp means 92s of silence from the writer")
        XCTAssertFalse(CaptureMarker.decide(contents: stamp(secondsAgo: 240), now: now),
                       "the 10 Aug case: four minutes without a heartbeat is a dead process")
    }

    /// The heartbeat has to fit inside the staleness window with room to spare,
    /// or a live capture flickers as dead between beats and a relaunch kills it.
    func testTheHeartbeatFitsComfortablyInsideTheWindow() {
        XCTAssertLessThan(CaptureMarker.heartbeat * 2, CaptureMarker.staleAfter,
                          "at least two beats must be missable before the writer is called dead")
    }

    /// `refresh` is `begin` by another name, and the names carry the meaning.
    /// If they ever diverge, a refreshed marker would stop reading as capturing.
    func testRefreshKeepsAMarkerAlive() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capture-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("capturing")

        // Stamped, then left long enough to be called dead.
        CaptureMarker.write(to: marker, now: now)
        let old = try String(contentsOf: marker, encoding: .utf8)
        let muchLater = now.addingTimeInterval(CaptureMarker.staleAfter + 60)
        XCTAssertFalse(CaptureMarker.decide(contents: old, now: muchLater))

        // A beat lands. The same capture is alive again, with no restart.
        CaptureMarker.write(to: marker, now: muchLater)
        let beaten = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(CaptureMarker.decide(contents: beaten, now: muchLater))
    }

    /// Trailing newlines are what a shell `echo` or a text editor leaves behind,
    /// and the file is human-inspectable by design.
    func testWhitespaceAroundTheStampIsTolerated() {
        XCTAssertTrue(CaptureMarker.decide(contents: "\(stamp(secondsAgo: 3))\n", now: now))
        XCTAssertTrue(CaptureMarker.decide(contents: "  \(stamp(secondsAgo: 3))  ", now: now))
    }

    // MARK: - Every way it must fail open

    /// A crash leaves the marker behind. Without ageing, every future relaunch
    /// would wait two minutes and then refuse — the app would stop updating and
    /// nothing would say why.
    func testAnAncientMarkerIsIgnored() {
        XCTAssertFalse(CaptureMarker.decide(contents: stamp(secondsAgo: 20), now: now))
        XCTAssertFalse(CaptureMarker.decide(contents: stamp(secondsAgo: 10_000), now: now))
    }

    func testNoMarkerMeansNotCapturing() {
        XCTAssertFalse(CaptureMarker.decide(contents: nil, now: now))
    }

    func testUnparseableMarkersMeanNotCapturing() {
        for garbage in ["", "   ", "not-a-number", "12x34", "NaN", "\u{0}\u{1}"] {
            XCTAssertFalse(CaptureMarker.decide(contents: garbage, now: now),
                           "\(garbage.debugDescription) must not read as capturing")
        }
    }

    /// A clock that moved backwards (NTP correction, timezone edit) would
    /// otherwise produce a negative age that compares as "recent" forever.
    func testAMarkerFromTheFutureIsIgnored() {
        XCTAssertFalse(CaptureMarker.decide(contents: stamp(secondsAgo: -60), now: now))
    }

    // MARK: - Round trip, off the live support directory

    func testWriteThenReadThenRemove() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capture-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("capturing")

        CaptureMarker.write(to: marker, now: now)
        let written = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(CaptureMarker.decide(contents: written, now: now))

        CaptureMarker.remove(at: marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Removing something that was never there is the abandon-before-open path,
    /// and it must not throw.
    func testRemovingAMarkerThatIsNotThereIsHarmless() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-absent-\(UUID().uuidString)")
        CaptureMarker.remove(at: missing)
    }
}
