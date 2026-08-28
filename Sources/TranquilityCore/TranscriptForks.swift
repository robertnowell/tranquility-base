import Foundation

/// Finds transcripts whose parent-uuid chain has forked, and says how much of
/// the conversation a resume can no longer reach.
///
/// This is the observational counterpart to `ResumeGuard`. The guard stops THIS
/// app from creating a second writer; nothing stops a hand-run
/// `claude --resume`, another tool, or a zombie the harness never owned. The
/// format offers no help either: a transcript is a singly-linked chain of
/// parent uuids with no lock, no fork flag, and no error when it splits, so the
/// only way to know is to walk the graph and count.
///
/// It never fails a build. `relaunch.sh` runs `tbase doctor` on every deploy,
/// and the seven forked transcripts on this machine are historical damage that
/// will never be repaired — re-linking them is the one thing this must not do.
/// Wiring the fork count into that gate would have made every future deploy
/// fail, permanently, over something nobody can fix: the exact shape of the
/// archive check that sat red for eight days and taught everyone to scroll past
/// it. So `doctor` prints the number and `tbase forks` is the command that
/// judges.
///
/// It REPORTS RATHER THAN REPAIRS, the rule `HubIntegrity` already sets. That is
/// not timidity — re-linking a parent uuid under a process that may still be
/// appending is how you cause this bug while fixing it. Git draws the same line:
/// `fsck` finds unreachable objects and `--lost-found` sets them aside, and a
/// human decides what they meant.
///
/// ## Which leaf counts as reachable
///
/// MEASURED, 27 Aug 2026, not inferred: `--resume` follows the LAST
/// non-sidechain record in FILE ORDER. Three synthetic transcripts were built
/// with a deliberate fork and resumed, each separating the candidate rules:
///
///   probe 1 — winner had the newest timestamp, the SHORTEST chain, last in file
///   probe 2 — winner had the OLDEST timestamp, an equal chain, last in file
///   probe 3 — winner had the OLDEST timestamp, the SHORTEST chain, last in file
///
/// File order won all three, so neither "newest timestamp" nor "longest chain"
/// is the rule. This matters more than it sounds: it means a fork costs you the
/// LONG HISTORY and keeps whichever branch was written last, however little it
/// holds. Reading it the other way around — longest-chain-wins — is what made
/// this incident's first damage estimate roughly half the real figure.
///
/// The rule is a measurement of someone else's undocumented behaviour, so it can
/// change in any release without notice. `TranscriptForksTests` pins the
/// classifier against fixtures, but only a re-measurement against a live
/// `--resume` can catch the rule itself moving.
public enum TranscriptForks {

    /// Same shape as `HubIntegrity.Problem`, so `tbase doctor` prints both
    /// through one path.
    public struct Problem: Sendable, Equatable {
        public let session: String
        public let detail: String

        public init(session: String, detail: String) {
            self.session = session
            self.detail = detail
        }
    }

    /// What one transcript's graph looks like. Returned whole so a caller can
    /// report a count rather than only a yes/no.
    public struct Survey: Sendable, Equatable {
        public let sessionId: String
        /// Records participating in the chain (a parent that exists, or someone
        /// else's parent). Bookkeeping rows that link to nothing are ignored.
        public let linked: Int
        /// Records a resume can still walk back to from the real tip.
        public let reachable: Int
        /// Dead-end tips. One is healthy; more than one means a fork.
        public let leaves: Int

        public var unreachable: Int { max(0, linked - reachable) }
        public var isForked: Bool { leaves > 1 }

        public init(sessionId: String, linked: Int, reachable: Int, leaves: Int) {
            self.sessionId = sessionId
            self.linked = linked
            self.reachable = reachable
            self.leaves = leaves
        }
    }

    /// Below this, a fork is routine and not worth a red gate.
    ///
    /// Measured across 43 forked transcripts on 27 Aug, the population splits
    /// with nothing in between: seven sessions had 1,256–6,348 unreachable
    /// records apiece (17,124 total — the duplicate-writer bug), and the other
    /// thirty-six had 60 or fewer (293 total). The small ones are stranded
    /// subagent `tool_result` records, produced by a SINGLE process running
    /// parallel agents — a second fork mechanism that no writer-guard can
    /// prevent, because there is no second writer to refuse.
    ///
    /// So they are reported separately rather than as failures. A gate that
    /// goes red every time somebody runs parallel agents is a gate people learn
    /// to ignore, and this repo just spent eight days with the archive check red
    /// over a body fragment for exactly that reason. 200 sits in the empty
    /// middle of a gap that runs from 60 to 1,256.
    public static let significantUnreachable = 200

    // MARK: - Reading

    /// Survey every transcript under `projects`.
    ///
    /// Whole-file reads, so this belongs in `tbase doctor` and NOT on the 5s
    /// intake tick: finding a fork means building the whole uuid graph, and the
    /// largest transcript on this machine is 43MB. `SessionDiscovery` reads a
    /// head and a tail for a reason; this cannot.
    /// `modifiedWithin` skips transcripts untouched for longer than the given
    /// interval — the same mtime prefilter `SessionDiscovery.scan` uses, and for
    /// the same reason. A full sweep costs ~22s on this machine because it reads
    /// and parses every line of ~150MB; the deploy path cannot pay that and does
    /// not need to, because historical damage does not change. Pass nil for the
    /// whole archive.
    public static func surveyAll(projects: URL = TranscriptArchive.projectsDirectory,
                                 modifiedWithin: TimeInterval? = nil) -> [Survey] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        else { return [] }
        let cutoff = modifiedWithin.map { Date().addingTimeInterval(-$0) }
        var out: [Survey] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                if let cutoff,
                   let m = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                       .contentModificationDate,
                   m < cutoff { continue }
                let id = file.deletingPathExtension().lastPathComponent
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                if let s = survey(text: text, sessionId: id) { out.append(s) }
            }
        }
        return out.sorted { $0.unreachable > $1.unreachable }
    }

    /// The problems `tbase doctor` should fail on: forks big enough to mean
    /// lost conversation rather than routine parallel-agent branching.
    public static func check(projects: URL = TranscriptArchive.projectsDirectory,
                             minimumUnreachable: Int = significantUnreachable,
                             modifiedWithin: TimeInterval? = nil) -> [Problem] {
        surveyAll(projects: projects, modifiedWithin: modifiedWithin)
            .filter { $0.isForked && $0.unreachable >= minimumUnreachable }
            .map { s in
                Problem(session: String(s.sessionId.prefix(8)),
                        detail: "transcript has forked into \(s.leaves) branches; "
                            + "\(s.unreachable) of \(s.linked) records are not reachable "
                            + "from the branch a resume would load")
            }
    }

    // MARK: - The pure half

    /// Split-and-classify, testable with no filesystem — the same read-it /
    /// decide-it seam `ResumeGuard.classify` keeps.
    ///
    /// A trailing partial line is dropped rather than parsed: a live process may
    /// be mid-append, and half a record is not a record. Unparseable lines are
    /// skipped for the same reason rather than failing the whole survey.
    public static func survey(text: String, sessionId: String) -> Survey? {
        var records: [(uuid: String, parent: String?, sidechain: Bool)] = []
        var byUuid: Set<String> = []
        // `omittingEmptySubsequences` keeps a trailing newline from producing a
        // phantom record; a final line with no newline is still parsed, and is
        // simply skipped below if it does not decode.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uuid = obj["uuid"] as? String
            else { continue }
            records.append((uuid, obj["parentUuid"] as? String,
                            (obj["isSidechain"] as? Bool) ?? false))
            byUuid.insert(uuid)
        }
        guard !records.isEmpty else { return nil }

        var parentOf: [String: String?] = [:]
        var isSomeonesParent: Set<String> = []
        for r in records {
            parentOf[r.uuid] = r.parent
            if let p = r.parent, byUuid.contains(p) { isSomeonesParent.insert(p) }
        }

        // Only records wired into the chain are counted. A transcript carries
        // bookkeeping rows (mode, last-prompt, cost-state) with no parent and no
        // children; counting them as "unreachable" would report loss where there
        // is none — an early version of this analysis did exactly that.
        let linked = records.filter {
            ($0.parent.map { byUuid.contains($0) } ?? false) || isSomeonesParent.contains($0.uuid)
        }
        guard !linked.isEmpty else { return nil }
        let leaves = linked.filter { !isSomeonesParent.contains($0.uuid) }

        // The measured rule: last non-sidechain record in FILE ORDER — but it
        // must be a record wired INTO the chain.
        //
        // A transcript's final line is very often a detached bookkeeping row
        // (`mode`, `cost-state`, `last-prompt`) with a null parent and no
        // children. Taking one of those as the tip walks a chain of exactly
        // one and reports the entire conversation as unreachable, which is
        // false and alarming in equal measure — caught by
        // `testUnlinkedBookkeepingRowsAreNotCountedAsLoss` before it could
        // reach a gate. On real transcripts the distinction is invisible
        // (f6003743's last row is a `system` record that IS linked, and
        // restricting to linked records leaves its walk unchanged at 834),
        // which is exactly why it needed a fixture to surface.
        let linkedUuids = Set(linked.map(\.uuid))
        guard let tip = records.last(where: { !$0.sidechain && linkedUuids.contains($0.uuid) })
        else { return nil }
        var seen: Set<String> = []
        var cursor: String? = tip.uuid
        while let u = cursor, byUuid.contains(u), !seen.contains(u) {
            seen.insert(u)
            cursor = parentOf[u] ?? nil
        }

        return Survey(sessionId: sessionId,
                      linked: linked.count,
                      reachable: linked.filter { seen.contains($0.uuid) }.count,
                      leaves: leaves.count)
    }
}
