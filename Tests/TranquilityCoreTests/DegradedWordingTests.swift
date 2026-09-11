import Foundation
import XCTest
@testable import TranquilityCore

/// What the hint line is allowed to say when the good voice fails.
///
/// Earned 11 Sep. The catch-all arm was `degraded = "\(error)"`, so an
/// ElevenLabs 404 put its whole response body — braces, escaped quotes and a
/// request id — onto a single truncating line with no tooltip. Reported as
/// "it was read in a system voice, strangely enough… I can't even see it".
/// The app had diagnosed itself correctly and then said so unreadably.
///
/// These assert the CONTRACT rather than the exact wording: short, no raw
/// error, no JSON, and — for the one failure a human can act on — the voice
/// named in words instead of as an id.
final class DegradedWordingTests: XCTestCase {

    private var savedCatalogURL: URL!
    private var savedNamesURL: URL!

    override func setUp() {
        super.setUp()
        savedCatalogURL = VoiceCatalog.cacheURL
        savedNamesURL = VoiceCatalog.namesURL
        let unique = UUID().uuidString
        VoiceCatalog.cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(unique).json")
        VoiceCatalog.namesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-names-\(unique).json")
    }

    override func tearDown() {
        VoiceCatalog.cacheURL = savedCatalogURL
        VoiceCatalog.namesURL = savedNamesURL
        super.tearDown()
    }

    /// The actual body from app.log, 11 Sep 21:15:43.
    private let realBody = """
        http 404: {"detail":{"type":"not_found","code":"voice_not_found",\
        "message":"A voice with voice_id 'EGxJIQ5TF187oclOp8aT' was not found.",\
        "status":"voice_not_found","request_id":"477bff88531a7845d12cba10b027fb11"}}
        """

    // MARK: - Nothing raw reaches the line

    func testAFailureNeverCarriesTheResponseBody() {
        let line = SpeechChain.plainly(SpeechError.synthesisFailed(realBody))
        XCTAssertFalse(line.contains("{"), "no JSON on the hint line")
        XCTAssertFalse(line.contains("request_id"))
        XCTAssertFalse(line.contains("synthesisFailed"), "no Swift error names")
        XCTAssertLessThan(line.count, 60, "the hint truncates; a clause or nothing")
    }

    func testAnHTTPStatusSurvivesBecauseItIsWorthKnowing() {
        XCTAssertEqual(SpeechChain.plainly(SpeechError.synthesisFailed("http 500: upstream")),
                       "ElevenLabs returned 500.")
    }

    func testAnUnreachableServiceSaysSo() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(SpeechChain.plainly(offline), "Could not reach ElevenLabs.")
    }

    func testAnythingElseStillGetsASentence() {
        struct Odd: Error {}
        let line = SpeechChain.plainly(Odd())
        XCTAssertEqual(line, "ElevenLabs could not render it.")
    }

    // MARK: - Naming a voice that no longer exists

    func testADeletedVoiceIsStillNamedFromTheLedger() throws {
        let gone = "EGxJIQ5TF187oclOp8aT"
        // The account listed it once; the ledger remembers after it is dropped.
        VoiceCatalog.rememberNames([Voice(id: gone, name: "Kay", category: "cloned")])
        XCTAssertEqual(VoiceCatalog.spokenName(for: gone), "\u{201C}Kay\u{201D}")
    }

    /// Catalogue names carry a sales tail — "Sarah - Mature, Reassuring,
    /// Confident" — which is right in a picker row and wrong mid-sentence.
    func testTheSalesTailIsDroppedForProse() {
        VoiceCatalog.rememberNames([
            Voice(id: "v1", name: "Sarah - Mature, Reassuring, Confident", category: "premade"),
        ])
        XCTAssertEqual(VoiceCatalog.spokenName(for: "v1"), "\u{201C}Sarah\u{201D}")
    }

    func testTheLedgerOutlivesACatalogueRefreshThatDropsTheVoice() throws {
        let gone = "EGxJIQ5TF187oclOp8aT"
        VoiceCatalog.rememberNames([
            Voice(id: gone, name: "Kay", category: "cloned"),
            Voice(id: "still-here", name: "Amelia", category: "professional"),
        ])
        // A later fetch no longer returns Kay — the account deleted it.
        VoiceCatalog.rememberNames([Voice(id: "still-here", name: "Amelia", category: "professional")])
        XCTAssertEqual(VoiceCatalog.spokenName(for: gone), "\u{201C}Kay\u{201D}",
                       "the entries worth keeping are the ones a fetch stops returning")
    }

    /// An id this install has genuinely never seen degrades to something that
    /// can still be matched against the log and the settings pane.
    func testAnUnknownIdFallsBackToItsPrefixRatherThanNothing() {
        let line = VoiceCatalog.spokenName(for: "ZZZZunknownZZZZ")
        XCTAssertEqual(line, "voice ZZZZunkn")
    }

    func testNoVoiceAtAllStillReadsAsASentenceFragment() {
        XCTAssertEqual(VoiceCatalog.spokenName(for: nil), "that agent's voice")
    }
}
