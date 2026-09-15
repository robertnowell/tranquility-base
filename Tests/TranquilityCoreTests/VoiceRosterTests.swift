import Foundation
import XCTest
@testable import TranquilityCore

/// The persisted cast: missing file seeds the original roster, a saved order
/// round-trips, and a deliberately emptied roster stays empty.
final class VoiceRosterTests: XCTestCase {

    private var savedURL: URL!
    private var savedSystemURL: URL!
    private var savedCatalogURL: URL!

    override func setUp() {
        super.setUp()
        savedURL = VoiceRoster.fileURL
        savedSystemURL = VoiceRoster.systemFileURL
        savedCatalogURL = VoiceCatalog.cacheURL
        let unique = UUID().uuidString
        VoiceRoster.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roster-\(unique).json")
        VoiceRoster.systemFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roster-system-\(unique).json")
        // No catalogue by default: an absent cache means "we have not asked the
        // account yet", which every pre-existing case here relies on — the
        // roster must come back whole when there is nothing to check it against.
        VoiceCatalog.cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(unique).json")
    }

    override func tearDown() {
        VoiceRoster.fileURL = savedURL
        VoiceRoster.systemFileURL = savedSystemURL
        VoiceCatalog.cacheURL = savedCatalogURL
        super.tearDown()
    }

    /// Write a catalogue the roster can be checked against.
    private func catalogue(_ ids: [String]) throws {
        let voices = ids.map { Voice(id: $0, name: "Voice \($0)", category: "premade") }
        try JSONEncoder().encode(voices).write(to: VoiceCatalog.cacheURL)
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

    // MARK: - Voices the account no longer has
    //
    // Earned 11 Sep. A cloned voice was deleted on the ElevenLabs account and
    // stayed in the roster: minted to a brand-new session, 404 on every
    // announcement for seven minutes, and no row in the roster pane to uncheck
    // it with, because a voice the catalogue does not list has no row.

    func testAVoiceTheAccountNoLongerHasLeavesTheRoster() throws {
        let alive = "EXAVITQu4vr4xnSDxMaL"
        let deleted = "EGxJIQ5TF187oclOp8aT"
        VoiceRoster.save([alive, deleted])
        try catalogue([alive])
        XCTAssertEqual(VoiceRoster.load(), [alive],
                       "a deleted voice must not be handed out again")
    }

    func testTheDeletedCloneIsNotInTheSeed() {
        XCTAssertFalse(VoiceRoster.seed.contains("EGxJIQ5TF187oclOp8aT"),
                       "removing it from the file is undone by a fresh install "
                       + "while the seed still carries it")
    }

    /// The catalogue is a cache of the last successful fetch, so "empty" means
    /// "we have not asked", never "the account has no voices". Filtering on it
    /// would silence every agent at once.
    func testAnUnfetchedCatalogueFiltersNothing() {
        VoiceRoster.save(VoiceRoster.seed)
        XCTAssertEqual(VoiceRoster.load(), VoiceRoster.seed)
    }

    /// The same guard one step further in: a catalogue that agrees with nothing
    /// on the roster is a catalogue that is wrong — a fetch against the wrong
    /// account, or a truncated page — and emptying the cast on its word would
    /// take every voice away over a transient.
    func testACatalogueThatKnowsNoneOfThemIsDisbelieved() throws {
        VoiceRoster.save(VoiceRoster.seed)
        try catalogue(["some-unrelated-voice-id"])
        XCTAssertEqual(VoiceRoster.load(), VoiceRoster.seed,
                       "a roster with nothing left is evidence about the "
                       + "catalogue, not about the roster")
    }

    /// Order is the assignment sequence, so the filter must not disturb it.
    func testFilteringPreservesRosterOrder() throws {
        let ids = ["c-id", "a-id", "gone", "b-id"]
        VoiceRoster.save(ids)
        try catalogue(["a-id", "b-id", "c-id"])
        XCTAssertEqual(VoiceRoster.load(), ["c-id", "a-id", "b-id"])
    }
}
