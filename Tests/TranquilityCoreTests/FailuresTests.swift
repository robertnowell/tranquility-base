import XCTest
@testable import TranquilityCore

/// A lock around a value, for closures the compiler rightly refuses to let
/// mutate a captured var.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

/// The failure record: what it carries, what it refuses, and that it never
/// blocks the caller. Ruled 6 Sep 2026 after a Codex launch died three times
/// with every explaining fact on the machine and none in the message.
final class FailuresTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        Failures.resetForTesting()
        Breadcrumbs.shared.clear()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-failures-\(UUID().uuidString)")
        Failures.configure(directory: dir)
    }

    override func tearDown() {
        Failures.resetForTesting()
        Breadcrumbs.shared.clear()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// The product mirror used to carry only kind and site, so a failure was a
    /// count with no cause off the user's machine. It now carries the reason
    /// too (scrubbed, bounded), which is what makes a failing self-update
    /// debuggable from telemetry.
    func testTheProductMirrorCarriesTheReasonNotJustTheKind() {
        Track.resetForTesting()
        Track.configure(directory: dir, installId: "install-x")
        let got = expectation(description: "failure mirror")
        let seen = Box<TrackEvent?>(nil)
        Track.attach { e in if e.name == "failure" { seen.update { $0 = e }; got.fulfill() } }
        Failures.report(.updateFailed,
                        reason: "update check failed: cannot verify feed signature [SUError 5]")
        wait(for: [got], timeout: 2)
        Track.detach()
        XCTAssertEqual(seen.value?.properties["kind"], .token("update_failed"))
        guard case .prose(let text)? = seen.value?.properties["reason"] else {
            return XCTFail("the failure mirror must carry a prose reason")
        }
        XCTAssertTrue(text.contains("cannot verify feed signature"), text)
    }

    private func records() -> [FailureEvent] {
        Failures.flush()
        guard let url = Failures.storeURL, let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(FailureEvent.self, from: Data($0.utf8)) }
    }

    // MARK: Scrubbing

    func testTheHomeDirectoryAndSecretsNeverReachTheRecord() {
        let home = "/Users/robert"
        let s = Scrub.text("cd /Users/robert/Projects && sk-abcdefghijklmnop mail rob@example.com Bearer abcdefghijklmnopqrstuvwxyz", home: home)
        XCTAssertEqual(s, "cd ~/Projects && [key] mail [email] Bearer [token]")
        XCTAssertEqual(Scrub.text("/private/Users/robert/x", home: home), "~/x")
    }

    func testScrubbingLeavesOrdinaryFactsAlone() {
        let line = "tmux session tb-111fd61a (tty /dev/ttys015) exited status 1: arch: posix_spawnp: codex: Bad CPU type in executable"
        XCTAssertEqual(Scrub.text(line, home: "/Users/robert"), line,
                       "a session name, a tty and a spawn error are the facts the record exists for")
    }

    // MARK: Breadcrumbs

    func testOnlyAllowedCategoriesBecomeBreadcrumbs() {
        let crumbs = Breadcrumbs(capacity: 5)
        XCTAssertTrue(crumbs.record("launcher: newSession: launched `codex` in /Users/robert/Projects"))
        XCTAssertFalse(crumbs.record("confirmAndSend -> dispatched(text: \"what I said\")"),
                       "the line that carries the transcript is not an allowed category")
        XCTAssertFalse(crumbs.record("HUD chrome: state.x=12"))
        XCTAssertFalse(crumbs.record("a line with no category at all"))
        XCTAssertEqual(crumbs.recent.count, 1)
        XCTAssertEqual(crumbs.recent.first?.category, "launcher")
        XCTAssertTrue(crumbs.recent.first!.message.hasPrefix("newSession: launched"))
    }

    func testAnAllowedCategoryIsStillRefusedWhenItCarriesContent() {
        let crumbs = Breadcrumbs(capacity: 5)
        XCTAssertFalse(crumbs.record("launcher: newSession: tb-1 stopped on a prompt. Its screen says: the words"),
                       "the pane's screen can be anything, including what an agent said")
        XCTAssertFalse(crumbs.record("routing: dispatched(text: hello)"))
    }

    func testTheRingKeepsOnlyTheNewest() {
        let crumbs = Breadcrumbs(capacity: 3)
        for i in 0..<10 { crumbs.record("state: \(i)") }
        XCTAssertEqual(crumbs.recent.map(\.message), ["7", "8", "9"])
    }

    // MARK: Mach-O

    func testAFatHeaderNamesEverySlice() {
        // FAT_MAGIC, 2 entries: x86_64 then arm64, each fat_arch 20 bytes.
        var bytes: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]
        for cputype: UInt32 in [0x01000007, 0x0100000C] {
            bytes += [UInt8(cputype >> 24), UInt8((cputype >> 16) & 0xFF), UInt8((cputype >> 8) & 0xFF), UInt8(cputype & 0xFF)]
            bytes += [UInt8](repeating: 0, count: 16)
        }
        XCTAssertEqual(MachOSlices.parse(Data(bytes)), ["x86_64", "arm64"])
    }

    func testAThinHeaderNamesItsOneSlice() {
        // MH_MAGIC_64 little-endian, cputype arm64 little-endian.
        let bytes: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(MachOSlices.parse(Data(bytes)), ["arm64"])
        XCTAssertEqual(MachOSlices.parse(Data([1, 2, 3])), [])
    }

    func testARealSystemBinaryReadsAsUniversalOnThisMac() throws {
        let slices = MachOSlices.of(path: "/bin/ls")
        XCTAssertFalse(slices.isEmpty, "/bin/ls must have at least one slice")
        XCTAssertTrue(slices.allSatisfy { ["arm64", "x86_64", "arm64e"].contains($0) || $0.hasPrefix("cputype") }, "\(slices)")
    }

    // MARK: The record

    func testAReportBecomesOneScrubbedRecordWithItsBreadcrumbs() {
        Breadcrumbs.shared.record("launcher: newSession: launched `codex` in /Users/\(NSUserName())/Projects")
        Failures.environment = EnvironmentSnapshot(
            appVersion: "0.1.0+abc", appBuild: "1", sourceCommit: "abc", appArch: "arm64",
            appTranslated: false, macOS: "26.5", harnesses: [], tmuxPath: nil, tmuxVersion: nil,
            permissions: [:])
        Failures.report(.launchFailed, reason: "died: Bad CPU type in /Users/\(NSUserName())/.local/bin/codex",
                        reproduction: "cd '/Users/\(NSUserName())/Projects' && codex", harness: "codex",
                        session: "0123456789abcdef")
        let all = records()
        XCTAssertEqual(all.count, 1)
        let e = all[0]
        XCTAssertEqual(e.kind, .launchFailed)
        XCTAssertEqual(e.reason, "died: Bad CPU type in ~/.local/bin/codex")
        XCTAssertEqual(e.reproduction, "cd '~/Projects' && codex")
        XCTAssertEqual(e.session, "01234567")
        XCTAssertEqual(e.harness, "codex")
        XCTAssertEqual(e.environment?.appArch, "arm64")
        XCTAssertTrue(e.site.hasSuffix(".swift:\(#line - 12)") || e.site.contains("FailuresTests"), e.site)
        XCTAssertEqual(e.breadcrumbs.count, 1)
        XCTAssertFalse(e.breadcrumbs[0].message.contains("/Users/"), "breadcrumbs are scrubbed too")
        XCTAssertEqual(e.installId, Failures.installId)
        XCTAssertNotEqual(e.installId, "unconfigured")
    }

    func testTheInstallIdIsMintedOnceAndKept() {
        let first = Failures.installId
        XCTAssertEqual(first.count, 36)
        Failures.resetForTesting()
        Failures.configure(directory: dir)
        XCTAssertEqual(Failures.installId, first, "the id lives in a file, so a relaunch keeps it")
    }

    func testTheReceiptDoesNotDuplicateASiteThatAlreadyReported() {
        Failures.report(.launchFailed, reason: "x", card: "Couldn't start an agent: x")
        Failures.notice("Couldn't start an agent: x")
        Failures.notice("Something else")
        let all = records()
        XCTAssertEqual(all.map(\.kind), [.launchFailed, .notice])
        XCTAssertEqual(all.map(\.reason), ["x", "Something else"],
                       "the site's own record wins; the panel's receipt covers only what nobody claimed")
    }

    func testSuppressedReportsAreCountedButNeverWritten() {
        Failures.suppressed = true
        let forwarded = Box<Int>(0)
        Failures.attach { _ in forwarded.update { $0 += 1 } }
        Failures.report(.microphone, reason: "drill")
        XCTAssertEqual(Failures.reportedCount, 1)
        XCTAssertEqual(Failures.suppressedCount, 1)
        XCTAssertEqual(records().count, 0)
        XCTAssertEqual(forwarded.value, 0)
        Failures.detach()
    }

    func testTheSinkSeesTheSameRecordTheFileGets() {
        let got = expectation(description: "sink")
        let seen = Box<FailureEvent?>(nil)
        Failures.attach { event in seen.update { $0 = event }; got.fulfill() }
        Failures.report(.deliveryFailed, reason: "verification timed out", session: "abcdefgh1234")
        wait(for: [got], timeout: 2)
        Failures.detach()
        XCTAssertEqual(seen.value?.kind, .deliveryFailed)
        XCTAssertEqual(records().first?.id, seen.value?.id)
    }

    func testReportingNeverBlocksTheCaller() {
        let started = Date()
        for i in 0..<200 { Failures.report(.notice, reason: "n\(i)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2,
                          "two hundred reports must cost the caller nothing visible; the writing is off-thread")
        XCTAssertEqual(records().count, 200)
    }

    func testTheSnapshotKnowsThisProcess() {
        let snap = EnvironmentProbe.snapshot(appVersion: "v", appBuild: "b", sourceCommit: nil,
                                             permissions: ["mic": "granted"], adapters: [], tmuxPath: nil)
        XCTAssertTrue(["arm64", "x86_64"].contains(snap.appArch))
        XCTAssertFalse(snap.macOS.isEmpty)
        XCTAssertEqual(snap.permissions["mic"], "granted")
        #if arch(arm64)
        XCTAssertFalse(snap.appTranslated, "an arm64 slice cannot be running under Rosetta")
        #endif
    }
}

/// Phase 1 additions: the crumb hook the crash reporter rides, and the
/// user's door out of an install id.
final class FailuresPhaseOneTests: XCTestCase {
    func testTheHookSeesEachAdmittedCrumbAndNoRefusedOne() {
        let crumbs = Breadcrumbs(capacity: 5)
        let seen = Counter()
        crumbs.onRecord = { _ in seen.bump() }
        crumbs.record("launcher: ok")
        crumbs.record("HUD chrome: not a category we admit")
        crumbs.record("routing: dispatched(text: refused)")
        XCTAssertEqual(seen.count, 1)
    }

    func testResettingTheInstallIdMintsADifferentOneAndKeepsIt() {
        Failures.resetForTesting()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); Failures.resetForTesting() }
        Failures.configure(directory: dir)
        let first = Failures.installId
        let second = Failures.resetInstallId()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Failures.installId, second)
        Failures.resetForTesting()
        Failures.configure(directory: dir)
        XCTAssertEqual(Failures.installId, second, "the reset is written, not just remembered")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
