import XCTest
@testable import TranquilityCore

/// The product-event funnel: no text by type, hashed identity, off-thread
/// writing, and the lamp spine's diffing.
final class TrackTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        Track.resetForTesting()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-track-\(UUID().uuidString)")
        Track.configure(directory: dir, installId: "install-a")
    }

    override func tearDown() {
        Track.resetForTesting()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func lines() -> [[String: Any]] {
        Track.flush()
        guard let url = Track.eventsURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func testATokenIsAVocabularyWordAndNothingElse() {
        XCTAssertTrue(TrackValue.token("ctrl_option").isAdmissible)
        XCTAssertTrue(TrackValue.token("result.failed").isAdmissible)
        XCTAssertFalse(TrackValue.token("what I said to the agent").isAdmissible, "spaces are prose")
        XCTAssertFalse(TrackValue.token("").isAdmissible)
        XCTAssertFalse(TrackValue.token(String(repeating: "a", count: 49)).isAdmissible)
        XCTAssertTrue(TrackValue.int(3).isAdmissible)
        XCTAssertTrue(Track.hash("anything").isAdmissible)
        XCTAssertFalse(TrackValue.hash("not-hex").isAdmissible)
    }

    func testAnEventWithProseIsDroppedWholeAndCounted() {
        Track.record("gesture", ["chord": "ctrl_option", "decision": .token("ignored, microphone is open")])
        Track.record("gesture", ["chord": "ctrl_option", "decision": "ignored_mic_open"])
        let all = lines()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0]["decision"] as? String, "ignored_mic_open")
        XCTAssertEqual(Track.refusedCount, 1)
        XCTAssertEqual(Track.recordedCount, 2)
    }

    func testHashesAreStablePerInstallAndDifferentAcrossInstalls() {
        let a1 = Track.hash("session-1"), a2 = Track.hash("session-1")
        XCTAssertEqual(a1, a2)
        if case .hash(let h) = a1 { XCTAssertEqual(h.count, 16) } else { XCTFail() }
        Track.resetForTesting()
        Track.configure(directory: dir, installId: "install-b")
        XCTAssertNotEqual(Track.hash("session-1"), a1, "another install cannot correlate the same agent")
    }

    func testCommonPropertiesRideEveryEventAndTheSinkSeesIt() {
        Track.setCommon(["build": "1096", "arch": "arm64"])
        let got = expectation(description: "sink")
        let seen = Box<TrackEvent?>(nil)
        Track.attach { e in seen.update { $0 = e }; got.fulfill() }
        Track.record("face_changed", ["from": "idle", "to": "speaking", "reason": "announce_requested"])
        wait(for: [got], timeout: 2)
        XCTAssertEqual(seen.value?.properties["arch"], .token("arm64"))
        XCTAssertEqual(seen.value?.properties["to"], .token("speaking"))
        XCTAssertEqual(lines().first?["build"] as? String, "1096")
    }

    func testAReplyOutcomeCarriesCountsOfTheTextAndNeverTheText() {
        Track.replyOutcome("dispatched", stage: "capture", agent: "sess-1",
                           text: "please rename the flag to dry-run", extra: ["latency_ms": 41])
        let line = lines().first
        XCTAssertEqual(line?["event"] as? String, "reply_outcome")
        XCTAssertEqual(line?["outcome"] as? String, "dispatched")
        XCTAssertEqual(line?["stage"] as? String, "capture")
        XCTAssertEqual(line?["chars"] as? Int, 33)
        XCTAssertEqual(line?["words"] as? Int, 6)
        XCTAssertEqual(line?["latency_ms"] as? Int, 41)
        XCTAssertEqual((line?["agent_id"] as? String)?.count, 16)
        // The words themselves are not in the record, under any key.
        let raw = (try? String(contentsOf: Track.eventsURL!, encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("rename"))
        XCTAssertFalse(raw.contains("sess-1"))
    }

    func testTheMicMachineRecordsEachStateChangeOnce() {
        var mic = MicMachine()
        mic.submit(.unitPrepared)          // cold -> warm
        mic.submit(.unitPrepared)          // warm -> warm: not a change
        let names = lines().map { $0["event"] as? String }
        XCTAssertEqual(names, ["mic_state"])
        XCTAssertEqual(lines().first?["from"] as? String, "cold")
        XCTAssertEqual(lines().first?["to"] as? String, "warm")
    }

    func testAPhraseKeepsTheAppsWordsAndDropsWhatFollowsTheColon() {
        XCTAssertEqual(Track.phrase("Install id copied: ad8eb762-5a5a"), .token("install_id_copied"))
        XCTAssertEqual(Track.phrase("could not save. The operation failed for /Users/kristen/x"), .token("could_not_save"))
        XCTAssertEqual(Track.phrase("Typed into Terminal."), .token("typed_into_terminal"))
        XCTAssertEqual(Track.phrase("working"), .token("working"))
    }

    func testADispatchFailureNamesItsCaseAndNeverItsTab() {
        let failure = DispatchFailure.tabNotFound("kristen-project-window")
        XCTAssertEqual(failure.trackName, "tab_not_found")
        Track.replyOutcome("dispatch_failed", stage: "confirm", extra: ["failure": .token(failure.trackName)])
        let raw = (try? String(contentsOf: Track.eventsURL!, encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("kristen"))
    }

    func testARowsReasonBecomesAVocabularyWordAndNeverItsOwnWords() {
        XCTAssertEqual(LampWatch.reasonToken("waiting on you"), "waiting")
        XCTAssertEqual(LampWatch.reasonToken("working 3m"), "working")
        XCTAssertEqual(LampWatch.reasonToken("429 rate limit exceeded"), "rate_limit")
        XCTAssertEqual(LampWatch.reasonToken("stream disconnected before completion: error sending request for url (https://api.openai.com/v1/responses)"), "network")
        XCTAssertEqual(LampWatch.reasonToken("Cannot read /Users/kristen/secret-project"), "other")
        XCTAssertEqual(LampWatch.reasonToken("4394c0ec"), "none")
        XCTAssertEqual(LampWatch.reasonToken(""), "none")
    }

    func testProseIsScrubbedAndBoundedAtTheDoor() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Track.record("launch_question_shown", [
            "text": .prose("Do you trust the files in \(home)/Projects/secret? Mail rob@example.com key sk-abcdefgh12345678"),
        ])
        let line = lines().first
        let text = line?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("~/Projects/secret"), "the home path becomes a tilde")
        XCTAssertFalse(text.contains(home), "the home path never survives")
        XCTAssertTrue(text.contains("[email]"))
        XCTAssertTrue(text.contains("[key]"))
    }

    func testProseIsTruncatedSoAPaneCannotFillTheRecord() {
        Track.record("launch_unregistered", ["screen": .prose(String(repeating: "x", count: 4000))])
        let text = lines().first?["screen"] as? String ?? ""
        XCTAssertEqual(text.count, 240)
    }

    func testTheLampSpineCarriesTheAgentsOwnSentenceBesideTheWord() {
        var watch = LampWatch()
        _ = watch.observe([(id: "s1", harness: "codex", lamp: "working", read: "opened", reason: "working")])
        let events = watch.observe([(id: "s1", harness: "codex", lamp: "fault", read: "unread",
                                     reason: "stream disconnected before completion: error sending request")])
        XCTAssertEqual(events.first?.properties["reason"], .token("network"))
        XCTAssertEqual(events.first?.properties["detail"],
                       .prose("stream disconnected before completion: error sending request"))
    }

    func testEventsRecordedBeforeASinkExistsReplayOnAttach() {
        Track.record("app_launched", ["launched_by": "login_or_user"])
        Track.record("face_changed", ["from": "hidden", "to": "idle"])
        Track.flush()
        let seen = Box<[String]>([])
        Track.attach { e in seen.update { $0.append(e.name) } }
        Track.flush()   // the replay rides the funnel's own queue
        XCTAssertEqual(seen.value, ["app_launched", "face_changed"], "in order, nothing lost")
        Track.record("gesture", ["chord": "ctrl_option"])
        Track.flush()
        XCTAssertEqual(seen.value.count, 3, "after attach, events go straight through")
    }

    func testSuppressedEventsAreCountedNotWrittenNotForwarded() {
        Track.suppressed = true
        let forwarded = Box<Int>(0)
        Track.attach { _ in forwarded.update { $0 += 1 } }
        Track.record("gesture", ["chord": "option"])
        Track.flush()
        XCTAssertEqual(Track.recordedCount, 1)
        XCTAssertEqual(Track.suppressedCount, 1)
        XCTAssertEqual(lines().count, 0)
        XCTAssertEqual(forwarded.value, 0)
    }

    func testDetachSendsEventsBackToTheBacklogUntilTheNextAttach() {
        let first = Box<Int>(0)
        Track.attach { _ in first.update { $0 += 1 } }
        Track.record("gesture", ["chord": "option"])
        Track.flush()
        Track.detach()
        XCTAssertFalse(Track.hasSink)
        Track.record("gesture", ["chord": "option"])
        Track.flush()
        let second = Box<Int>(0)
        Track.attach { _ in second.update { $0 += 1 } }
        Track.flush()
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 1, "the event recorded with no sink waited for the next one")
    }

    func testRecordingNeverBlocksTheCaller() {
        let started = Date()
        for i in 0..<500 { Track.record("tick", ["n": .int(i)]) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        XCTAssertEqual(lines().count, 500)
    }

    func testTheLampSpineEmitsOnePerChangeAndOneWhenARowLeaves() {
        var watch = LampWatch()
        let t0 = Date(timeIntervalSince1970: 1000)
        // The first feed is a census, not a change.
        var events = watch.observe([("s0", "claude-code", "running", "none", "quiet")], now: t0)
        XCTAssertTrue(events.isEmpty)
        // A new row after that is a change from nothing.
        events = watch.observe([("s0", "claude-code", "running", "none", "quiet"),
                                ("s1", "codex", "ready", "unread", "waiting on you")], now: t0)
        XCTAssertEqual(events.map { $0.properties["to"] }, [.token("ready")])
        XCTAssertEqual(events[0].properties["from"], .token("none"))
        // Same again: nothing.
        events = watch.observe([("s0", "claude-code", "running", "none", "quiet"),
                                ("s1", "codex", "ready", "unread", "waiting on you")], now: t0.addingTimeInterval(5))
        XCTAssertTrue(events.isEmpty)
        // Opened, then working, then gone.
        events = watch.observe([("s0", "claude-code", "running", "none", "quiet"),
                                ("s1", "codex", "ready", "opened", "waiting on you")], now: t0.addingTimeInterval(10))
        XCTAssertEqual(events[0].properties["read"], .token("opened"))
        XCTAssertEqual(events[0].properties["seconds_in_previous"], .int(10))
        events = watch.observe([("s0", "claude-code", "running", "none", "quiet"),
                                ("s1", "codex", "working", "none", "working 3m")], now: t0.addingTimeInterval(20))
        XCTAssertEqual(events[0].properties["from"], .token("ready"))
        XCTAssertEqual(events[0].properties["reason"], .token("working"), "prose reduces to a vocabulary word")
        events = watch.observe([("s0", "claude-code", "running", "none", "quiet")], now: t0.addingTimeInterval(30))
        XCTAssertEqual(events[0].properties["to"], .token("gone"))
        XCTAssertEqual(events[0].properties["reason"], .token("left_the_grid"))
        for e in events { for (_, v) in e.properties { XCTAssertTrue(v.isAdmissible) } }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock(); private var v: T
        init(_ v: T) { self.v = v }
        var value: T { lock.lock(); defer { lock.unlock() }; return v }
        func update(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
    }
}
