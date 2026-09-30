import XCTest
@testable import TranquilityCore

/// The idle memos read a file once per change, not once per tick.
///
/// Each is asserted both ways, because each fails quietly: a memo that never
/// hits is the idle CPU it was written to remove (29 Sep), and one that hits
/// on a moved file shows a stale lamp or a missing link nothing corrects.
/// "Unchanged" is proven by swapping bytes at the same size and restoring the
/// mtime: only a memo can still give the old answer.
final class IdleMemoTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idle-memo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A whole second, so restoring it is exact; a read-back stamp loses the
    /// nanoseconds and the memo is right to call that a move.
    private let stamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 2)

    private func write(_ lines: [String], to url: URL, keepStamp: Bool = true) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
        if keepStamp {
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
    }

    // MARK: - SessionActivity.evidence

    private let done = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#
    private let asks = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do it"}]}}"#

    func testEvidenceDoesNotReReadAnUnchangedTranscript() throws {
        let file = root.appendingPathComponent("\(UUID().uuidString).jsonl")
        try write([done, asks], to: file)
        let first = SessionActivity.evidence(transcriptPath: file.path)?.activity

        try write([asks, done], to: file)      // same bytes, other order, same mtime
        XCTAssertEqual(SessionActivity.evidence(transcriptPath: file.path)?.activity, first)
    }

    func testEvidenceReReadsAGrownTranscript() throws {
        let file = root.appendingPathComponent("\(UUID().uuidString).jsonl")
        try write([asks], to: file, keepStamp: false)
        XCTAssertEqual(SessionActivity.evidence(transcriptPath: file.path)?.activity, .working)
        try write([asks, done], to: file, keepStamp: false)
        XCTAssertEqual(SessionActivity.evidence(transcriptPath: file.path)?.activity, .idle)
    }

    // MARK: - SessionLineage.scan

    private func record(_ from: String, _ to: String) -> String {
        #"{"type":"continued-in","sessionId":"\#(from)","continuedInSessionId":"\#(to)"}"#
    }

    func testLineageDoesNotReReadAnUnchangedTranscript() throws {
        let (a, b, c) = (UUID().uuidString.lowercased(), UUID().uuidString.lowercased(),
                         UUID().uuidString.lowercased())
        let dir = root.appendingPathComponent("-Users-x-Projects-a", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(a).jsonl")

        try write([done, record(a, b)], to: file)
        XCTAssertEqual(SessionLineage.scan(projects: root)[b], a)

        try write([done, record(a, c)], to: file)   // same length: both ids are UUIDs
        XCTAssertEqual(SessionLineage.scan(projects: root)[b], a, "re-read an unchanged file")
    }

    func testLineageReReadsAMovedTranscript() throws {
        let (a, b) = (UUID().uuidString.lowercased(), UUID().uuidString.lowercased())
        let dir = root.appendingPathComponent("-Users-x-Projects-a", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(a).jsonl")

        try write([done], to: file, keepStamp: false)
        XCTAssertNil(SessionLineage.scan(projects: root)[b])
        try write([done, record(a, b)], to: file, keepStamp: false)
        XCTAssertEqual(SessionLineage.scan(projects: root)[b], a)
    }

    // MARK: - SystemVoiceCatalog

    /// The key is a handful of stats over AssetsV2; asking twice with nothing
    /// installed in between must give the same key, or the memo never hits.
    func testTheVoiceCatalogueKeyIsStableWhileNothingIsInstalled() {
        XCTAssertEqual(SystemVoiceCatalog.installedSignature(),
                       SystemVoiceCatalog.installedSignature())
    }
}
