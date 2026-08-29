import Foundation
import XCTest
@testable import TranquilityCore

/// The persisted cast: missing file seeds the original roster, a saved order
/// round-trips, and a deliberately emptied roster stays empty.
final class VoiceRosterTests: XCTestCase {

    private var savedURL: URL!
    private var savedSystemURL: URL!

    override func setUp() {
        super.setUp()
        savedURL = VoiceRoster.fileURL
        savedSystemURL = VoiceRoster.systemFileURL
        let unique = UUID().uuidString
        VoiceRoster.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roster-\(unique).json")
        VoiceRoster.systemFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roster-system-\(unique).json")
    }

    override func tearDown() {
        VoiceRoster.fileURL = savedURL
        VoiceRoster.systemFileURL = savedSystemURL
        super.tearDown()
    }

    func testMissingFileSeedsTheOriginalCast() {
        XCTAssertEqual(VoiceRoster.load(), VoiceRoster.seed)
    }

    func testSavedOrderRoundTrips() {
        let reordered = Array(VoiceRoster.seed.reversed().prefix(3))
        VoiceRoster.save(reordered)
        XCTAssertEqual(VoiceRoster.load(), reordered)
    }

    func testEmptiedRosterStaysEmpty() {
        // [] is a decision, not an accident — it must not resurrect the seed.
        VoiceRoster.save([])
        XCTAssertEqual(VoiceRoster.load(), [])
    }

    // MARK: - Two rosters

    /// The incident this file now guards. On 20 Aug the roster held 26 entries:
    /// the 15 seeded ElevenLabs ids plus 11 Apple ones, added through the
    /// settings pane on 13 Aug because the pane lists both families and its
    /// toggle appended any checked id to the one roster. Round-robin then handed
    /// an Apple identifier to ElevenLabs roughly two times in five.
    ///
    /// Filtered on the way OUT, so it holds no matter what is on disk — an older
    /// build's file, or a hand edit.
    func testASystemVoiceOnDiskIsNeverReturnedAsACloudVoice() throws {
        let mixed = VoiceRoster.seed + ["com.apple.ttsbundle.siri_Nicky_en-US_premium",
                                        "com.apple.voice.premium.en-US.Ava"]
        try JSONEncoder().encode(mixed).write(to: VoiceRoster.fileURL)
        XCTAssertEqual(VoiceRoster.load(), VoiceRoster.seed,
                       "an Apple id is not a cloud voice, whatever the file says")
    }

    /// And the mirror: the system roster never yields a cloud id, so the
    /// fallback cannot be handed something `AVSpeechSynthesizer` has never heard of.
    func testACloudVoiceOnDiskIsNeverReturnedAsASystemVoice() throws {
        try JSONEncoder().encode(VoiceRoster.seed).write(to: VoiceRoster.systemFileURL)
        XCTAssertEqual(VoiceRoster.loadSystem(), [],
                       "an ElevenLabs id is not something the system synthesiser can say")
    }

    /// The migration moves the Apple entries rather than dropping them: the user
    /// checked those voices on purpose. They just belong to the other roster.
    func testTheSplitMovesAppleVoicesRatherThanDiscardingThem() throws {
        let apple = ["com.apple.ttsbundle.siri_Nicky_en-US_premium",
                     "com.apple.voice.enhanced.en-GB.Daniel"]
        try JSONEncoder().encode(VoiceRoster.seed + apple).write(to: VoiceRoster.fileURL)

        let split = VoiceRoster.splitMixedRoster()
        XCTAssertEqual(split?.cloud, VoiceRoster.seed.count)
        XCTAssertEqual(split?.system, apple.count)
        XCTAssertEqual(VoiceRoster.load(), VoiceRoster.seed)
        XCTAssertEqual(VoiceRoster.loadSystem(), apple, "a checked voice is not thrown away")
    }

    /// Runs once. The system file existing IS the flag, so a second call cannot
    /// overwrite a roster the user has since edited.
    func testTheSplitIsIdempotent() throws {
        let apple = ["com.apple.voice.premium.en-US.Ava"]
        try JSONEncoder().encode(VoiceRoster.seed + apple).write(to: VoiceRoster.fileURL)
        XCTAssertNotNil(VoiceRoster.splitMixedRoster())

        VoiceRoster.saveSystem(["com.apple.voice.enhanced.en-US.Tom"])
        XCTAssertNil(VoiceRoster.splitMixedRoster(), "a second split must be a no-op")
        XCTAssertEqual(VoiceRoster.loadSystem(), ["com.apple.voice.enhanced.en-US.Tom"],
                       "the user's later edit must survive")
    }

    /// A roster that was never mixed needs no migration, and must not get an
    /// empty system file that would then suppress the seed.
    func testAnUnmixedRosterIsNotMigrated() throws {
        try JSONEncoder().encode(VoiceRoster.seed).write(to: VoiceRoster.fileURL)
        XCTAssertNil(VoiceRoster.splitMixedRoster())
        XCTAssertFalse(FileManager.default.fileExists(atPath: VoiceRoster.systemFileURL.path),
                       "no system file means the seed still applies")
    }
}
