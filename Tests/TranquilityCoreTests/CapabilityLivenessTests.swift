import XCTest
@testable import TranquilityCore

/// **Rule 5 of the provider seam: every declared capability is read by
/// production code.**
///
/// A declared capability nothing reads is worse than no capability, because it
/// reads as a guarantee. The standing example is in this repository:
/// `HarnessCapabilities.allowsConcurrentResume` carries forty lines of careful
/// measurement and its documentation ends "Nothing in Sources/ reads it today."
/// That is how a seam rots into a formality, and nothing would have told us.
///
/// A grep cannot answer this, which is why rule 3 ships as
/// `scripts/check-compat-comments.sh` and rule 5 ships here: deciding whether
/// code READS a field means reading Swift, not comment text.
///
/// The check is deliberately blunt. It looks for the field's name used as a
/// member access anywhere in `Sources/` outside the file that declares it. A
/// field mentioned only in its own declaration and initialiser is dead.
final class CapabilityLivenessTests: XCTestCase {

    /// **The debt list, and it may only ever shrink.**
    ///
    /// An allowlist that can grow is a rubber stamp, so this one works the way
    /// `scripts/test.sh` works with its test floor: a field in here is known
    /// debt with a reason and a date, a field NOT in here that goes dead fails
    /// the suite, and a field in here that becomes live ALSO fails, so the list
    /// cannot quietly describe a past that no longer exists.
    ///
    /// It was expected to hold one entry. Writing the detector found FOUR,
    /// which is the finding rather than an inconvenience: `HarnessCapabilities`
    /// has four dead fields and not the one its documentation confesses to.
    ///
    /// **Every entry carries a real marker**, so the expiry checker  compat:exempt
    /// this branch also ships can see it. The first draft wrote the dates in
    /// plain prose, which meant the debt created by the ruling was not governed
    /// by the ruling's own machinery. That is the precise failure the ruling
    /// was written to end, committed in the same pull request.
    private static let knownDead: [String: String] = [
        // The 21 Aug measurement, kept as a measurement. Coordinator's adoption
        // logic stopped branching on it on 23 Aug when the dual-live premise
        // was reversed, and `ResumeGuard` now refuses a second resume for EVERY
        // harness rather than consulting a per-harness flag. The value records
        // what the PROCESS does and no caller may read that as licence, which
        // is the whole reason it is not consulted. Deleting it would delete the
        // finding: 8,443 records stranded on unreachable branches, 3,982 in one
        // session. The one entry here that is arguably correct as it stands.
        // COMPAT(allowsConcurrentResume): kept measurement, remove after 2027-03-01
        "allowsConcurrentResume": "a kept measurement, deliberately not a switch",

        // The next three are NOT deliberate, and were not known before this
        // test existed. Each is a fact measured about a harness that no code
        // consults, which means the behaviour it describes is either hardcoded
        // somewhere or simply not implemented. Both are worth knowing and
        // neither is visible without this list.
        //
        // Measured live 23 Aug on both harnesses and consulted nowhere. The
        // landing checks that care about paste echo read `pasteChipPrefix`
        // instead, which IS live, so this is the half of a two-part
        // measurement that got left behind.
        // COMPAT(echoesPaste): superseded by pasteChipPrefix, remove after 2026-12-01
        "echoesPaste": "measured, superseded in practice by pasteChipPrefix",
        // Whether a harness queues input typed mid-turn. The reply pipeline
        // decides this by waiting rather than by asking, so the flag records
        // an answer nothing needs yet.
        // COMPAT(queuesInputMidTurn): pipeline waits instead, remove after 2026-12-01
        "queuesInputMidTurn": "recorded, and the pipeline decides by waiting instead",
        // Whether a harness has hooks at all. `HookManifest` enumerates
        // harnesses directly and `Prerequisites.Item.hooks` carries the id, so
        // both routes bypass the capability. This is the one most likely to be
        // a genuine bug rather than dead weight: a harness WITHOUT hooks would
        // still get a hooks row today. FILED AS #394 rather than left here: a
        // finding recorded only in a test allowlist is a finding nobody reads.
        // COMPAT(hasHooks): see #394, remove after 2026-12-01
        "hasHooks": "declared, and HookManifest answers the same question another way",
    ]

    /// The NEW seam's capabilities, which are pending rather than dead: every
    /// one of them is consumed by the checkpoint work (#368 to #374), and no
    /// adapter exists yet to consume them. Separated from `knownDead` because
    /// the two are different states and merging them would let genuine rot hide
    /// among work that has not happened yet.
    ///
    /// **This list must be empty when the checkpoint lands**, and it carries a
    /// date so that is enforced rather than remembered. The first draft left it
    /// undated, which would have made it the one debt list in this file with no
    /// expiry at all.
    ///
    /// Seven on 13 Sep. **Four after the first real provider landed** (#402):
    /// `canStart`, `canSend` and `canAnswer` are now consulted by
    /// `LocalOpenCodeProvider`, and this test is what made that visible rather
    /// than something anyone had to remember to check.
    ///
    /// COMPAT(pendingCapabilities): consumed by #368-#374, remove after 2026-11-15
    private static let pendingUntilTheCheckpoint: Set<String> = [
        // No abort route in the client's surface yet, and the provider refuses
        // rather than pretending. #368 or a later pass consumes it.
        "canCancel",
        // Nothing polls or sends often enough yet to care: #370's poller and
        // #373's reply path are what read these.
        "sendWhileWorking",
        // #371 reads this when remote rows are filtered to the user's own work.
        "listIsCallerScoped",
        // #374 reads this when the pull request lands in the hub as a receipt.
        "carriesPullRequest",
    ]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/TranquilityCoreTests/<this>.swift
            .deletingLastPathComponent()          // Tests/TranquilityCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Sources")
    }

    /// Every `var` declared inside `structName`, in declaration order.
    private func fields(of structName: String, in text: String) -> [String] {
        guard let start = text.range(of: "public struct \(structName)") else { return [] }
        var depth = 0
        var body = ""
        var started = false
        for ch in text[start.lowerBound...] {
            if ch == "{" { depth += 1; started = true }
            if started { body.append(ch) }
            if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        var names: [String] = []
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public var ") else { continue }
            let rest = trimmed.dropFirst("public var ".count)
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.append(String(name)) }
        }
        return names
    }

    /// Read by something other than the file that declares it.
    private func isRead(_ field: String, declaredIn declaringFile: String) throws -> Bool {
        let files = FileManager.default.enumerator(
            at: Self.sourcesRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        for file in files where file.lastPathComponent != declaringFile {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments are where a dead field is most eloquently discussed,
                // and that is precisely not a read.
                if trimmed.hasPrefix("//") { continue }
                // A WORD boundary, not a substring. `.canStartReply` contains
                // `.canStart`, and without this the detector reported a pending
                // capability as already consumed because an unrelated property
                // on StatusHUD happened to share a prefix. A matcher that is
                // wrong in the permissive direction is the worst kind here: it
                // reports the seam as healthy.
                var searched = Substring(trimmed)
                while let hit = searched.range(of: ".\(field)") {
                    let after = searched[hit.upperBound...].first
                    if after == nil || !(after!.isLetter || after!.isNumber || after! == "_") {
                        return true
                    }
                    searched = searched[hit.upperBound...]
                }
            }
        }
        return false
    }

    private func assertEveryFieldIsRead(of structName: String, file declaringFile: String) throws {
        let path = Self.sourcesRoot.appendingPathComponent("TranquilityCore/\(declaringFile)")
        let text = try String(contentsOf: path, encoding: .utf8)
        let declared = fields(of: structName, in: text)
        XCTAssertFalse(declared.isEmpty, "found no fields on \(structName): the parser is wrong")

        for field in declared {
            let read = try isRead(field, declaredIn: declaringFile)
            if let why = Self.knownDead[field] {
                // The list may only shrink. A field that became live must leave
                // it, or the list starts describing a past that is no longer
                // true, which is how an allowlist becomes a rubber stamp.
                XCTAssertFalse(read,
                               "\(field) is listed as known debt (\(why)) but production code "
                                   + "now reads it. Delete its entry.")
                continue
            }
            if Self.pendingUntilTheCheckpoint.contains(field) {
                XCTAssertFalse(read,
                               "\(field) is listed as pending but is already consumed. "
                                   + "Delete its entry: the pending list must reach empty.")
                continue
            }
            XCTAssertTrue(read,
                          "\(structName).\(field) is declared and nothing in Sources/ reads it. "
                              + "A capability nothing reads is worse than no capability, "
                              + "because it reads as a guarantee. Consume it, delete it, or "
                              + "list it as debt with a reason and a date.")
        }
    }

    /// The new seam, where this rule is meant to bite before anything rots.
    func testEveryAgentCapabilityIsConsultedByProductionCode() throws {
        try assertEveryFieldIsRead(of: "Capabilities", file: "AgentSession.swift")
    }

    /// And the old one, which is where the rule was learned.
    func testEveryHarnessCapabilityIsConsultedOrExemptedWithAReason() throws {
        try assertEveryFieldIsRead(of: "HarnessCapabilities", file: "HarnessAdapter.swift")
    }

    /// The check must be able to FAIL, or it is decoration. `allowsConcurrentResume`
    /// is the known-dead field, so it is the fixture: if this ever reports it as
    /// read, the detector has broken rather than the codebase improved.
    func testTheDetectorActuallyDetectsADeadField() throws {
        XCTAssertFalse(try isRead("allowsConcurrentResume", declaredIn: "HarnessAdapter.swift"),
                       "the known-dead field now reads as live: the detector is broken")
        // `promptGlyph` is read at fourteen sites and `registersWithLiveness` at
        // three, so a detector reporting either as dead is broken rather than
        // the codebase improved. This pairing is what caught the first draft:
        // it asserted `hasHooks` was live, on nothing but an assumption, and
        // `hasHooks` turned out to be one of the dead four.
        XCTAssertTrue(try isRead("promptGlyph", declaredIn: "HarnessAdapter.swift"),
                      "a field production code demonstrably reads was reported dead")
        XCTAssertTrue(try isRead("registersWithLiveness", declaredIn: "HarnessAdapter.swift"),
                      "a field production code demonstrably reads was reported dead")
    }

    /// The debt is bounded and named. If this number rises, somebody added a
    /// capability nothing reads and wrote themselves a permission slip.
    func testTheDebtListIsExactlyWhatWeKnowAbout() {
        XCTAssertEqual(Self.knownDead.count, 4,
                       "the known-dead list changed size: \(Self.knownDead.keys.sorted())")
        XCTAssertEqual(Self.pendingUntilTheCheckpoint.count, 4,
                       "every new capability is consumed by the checkpoint work, and this "
                           + "list must reach zero when it lands")
    }
}
