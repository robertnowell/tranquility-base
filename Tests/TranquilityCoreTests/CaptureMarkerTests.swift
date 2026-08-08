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
        // The longest utterance actually observed was 92 seconds; it must still
        // be protected, and comfortably.
        XCTAssertTrue(CaptureMarker.decide(contents: stamp(secondsAgo: 92), now: now))
        XCTAssertTrue(CaptureMarker.decide(contents: stamp(secondsAgo: 179), now: now))
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
        XCTAssertFalse(CaptureMarker.decide(contents: stamp(secondsAgo: 180), now: now))
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
