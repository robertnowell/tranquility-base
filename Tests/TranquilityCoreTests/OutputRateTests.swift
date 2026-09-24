import XCTest

/// The arithmetic that makes a chipmunk, stated once so the number in the
/// commit message cannot drift from the number in the code.
///
/// 23 Sep, wearing AirPods: everything the manager said came out an octave up
/// and at double speed. The device reads 48000 Hz before a session, 24000 Hz
/// for the moment the duplex link renegotiates, and 48000 Hz again once it
/// settles — and the audio module reads the rate exactly once, inside that
/// window. Samples prepared for 24000 and played at 48000 come out at twice
/// the speed, which is one octave.
final class OutputRateTests: XCTestCase {
    func testRenderingAtHalfTheDeviceRateDoublesTheSpeed() {
        let configured = 24000.0, device = 48000.0
        XCTAssertEqual(device / configured, 2.0, accuracy: 0.0001)
    }

    /// A doubling of playback rate is a rise of exactly twelve semitones.
    func testWhichIsExactlyAnOctave() {
        let semitones = 12 * log2(48000.0 / 24000.0)
        XCTAssertEqual(semitones, 12, accuracy: 0.0001)
    }

    /// The other direction is the one nobody reported, because it is much less
    /// alarming: settling low would have sounded slow and deep.
    func testTheOppositeMismatchWouldHaveSoundedSlow() {
        XCTAssertLessThan(24000.0 / 48000.0, 1.0)
    }
}
