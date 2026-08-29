import Foundation
import XCTest
@testable import TranquilityCore

/// Every session is assigned TWO voices: the ElevenLabs voice it speaks in and
/// the system voice it falls back to. ElevenLabs is used whenever available, so
/// the second one is a redundancy — which is what lets the app behave the same
/// way with or without a key, and what keeps "the voice says who" true through a
/// fallback.
final class SessionVoicePairTests: XCTestCase {

    private var tmpDir: URL!
    private var store: QueueStore!

    private let cloud = ["cloud-a", "cloud-b", "cloud-c"]
    private let system = ["com.apple.voice.premium.en-US.Ava",
                          "com.apple.voice.enhanced.en-US.Tom"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    func testBothVoicesAreAssignedOnFirstAsk() throws {
        let pair = try store.voices(for: "s1", roster: cloud, systemRoster: system)
        XCTAssertEqual(pair.cloud, "cloud-a")
        XCTAssertEqual(pair.system, "com.apple.voice.premium.en-US.Ava")
    }

    /// The durability that makes a voice an identity rather than a coin flip. Both
    /// halves, because a fallback that changed between turns would undo the point
    /// of having one.
    func testThePairIsStableAcrossAsks() throws {
        let first = try store.voices(for: "s1", roster: cloud, systemRoster: system)
        let again = try store.voices(for: "s1", roster: cloud, systemRoster: system)
        XCTAssertEqual(first.cloud, again.cloud)
        XCTAssertEqual(first.system, again.system)
    }

    /// The rotation, on BOTH rosters: consecutive sessions must not become the
    /// same person. This is what the single machine-wide fallback voice got wrong
    /// — every session that degraded sounded identical.
    func testConsecutiveSessionsRotateThroughBothRosters() throws {
        let a = try store.voices(for: "s1", roster: cloud, systemRoster: system)
        let b = try store.voices(for: "s2", roster: cloud, systemRoster: system)
        XCTAssertNotEqual(a.cloud, b.cloud, "two sessions must not share a cloud voice")
        XCTAssertNotEqual(a.system, b.system, "nor a fallback voice")
    }

    /// The rosters are different lengths, so the shorter one wraps first. Neither
    /// may run off the end.
    func testTheShorterRosterWrapsRatherThanRunningOut() throws {
        _ = try store.voices(for: "s1", roster: cloud, systemRoster: system)
        _ = try store.voices(for: "s2", roster: cloud, systemRoster: system)
        let third = try store.voices(for: "s3", roster: cloud, systemRoster: system)
        XCTAssertEqual(third.cloud, "cloud-c")
        XCTAssertEqual(third.system, "com.apple.voice.premium.en-US.Ava",
                       "a two-entry roster wraps on the third session")
    }

    /// A session assigned before there was a system half gains one on next ask,
    /// rather than inheriting the machine default forever.
    func testAnOlderSessionIsBackfilled() throws {
        _ = try store.voiceId(for: "old", roster: cloud)          // single-voice path
        let pair = try store.voices(for: "old", roster: cloud, systemRoster: system)
        XCTAssertEqual(pair.cloud, "cloud-a", "the established voice must not move")
        XCTAssertNotNil(pair.system, "an older session still needs a fallback voice")
    }

    /// The row shape the mixed roster left behind: an APPLE id sitting in the
    /// cloud column. It must become the session's system voice — that is what it
    /// has actually been — and the session must gain a real cloud voice, because
    /// ElevenLabs is used whenever it is available.
    ///
    /// Left unmigrated these sessions would never reach the cloud again, which is
    /// the exact opposite of the rule.
    func testAnAppleIdInTheCloudColumnBecomesTheSystemVoice() throws {
        let legacy = "com.apple.voice.enhanced.en-US.Allison"
        _ = try store.assignVoice(legacy, to: "mixed")

        let pair = try store.voices(for: "mixed", roster: cloud, systemRoster: system)
        XCTAssertEqual(pair.system, legacy,
                       "the voice this session has been read in is its fallback, not a discard")
        XCTAssertNotNil(pair.cloud, "and it gains a real ElevenLabs voice")
        XCTAssertFalse(SystemVoiceCatalog.isSystemVoice(pair.cloud ?? ""),
                       "an Apple id must never be the cloud voice")
    }

    /// And it sticks, so the re-mint happens once rather than every announcement.
    func testTheRemintedPairIsStable() throws {
        _ = try store.assignVoice("com.apple.voice.premium.en-US.Ava", to: "mixed")
        let first = try store.voices(for: "mixed", roster: cloud, systemRoster: system)
        let again = try store.voices(for: "mixed", roster: cloud, systemRoster: system)
        XCTAssertEqual(first.cloud, again.cloud)
        XCTAssertEqual(first.system, again.system)
    }

    /// An empty system roster is a decision the user is allowed to make: no
    /// fallback voice is named and the provider uses its own default. It must not
    /// take the cloud voice down with it.
    func testAnEmptySystemRosterStillAssignsTheCloudVoice() throws {
        let pair = try store.voices(for: "s1", roster: cloud, systemRoster: [])
        XCTAssertEqual(pair.cloud, "cloud-a")
        XCTAssertNil(pair.system)
    }

    /// And the inverse, which is the no-key machine: no ElevenLabs roster at all,
    /// and the session still has a voice to be read in.
    func testAnEmptyCloudRosterStillAssignsTheSystemVoice() throws {
        let pair = try store.voices(for: "s1", roster: [], systemRoster: system)
        XCTAssertNil(pair.cloud)
        XCTAssertEqual(pair.system, "com.apple.voice.premium.en-US.Ava")
    }
}
