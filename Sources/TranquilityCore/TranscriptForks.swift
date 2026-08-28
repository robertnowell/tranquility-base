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
        /// Dead-end tips. NOT a fork test on its own: a compacted conversation
        /// continues in a new segment, so an old healthy session has one tip per
        /// compaction and nothing has diverged. Kept because "14 branches" is
        /// still the most legible way to say how chopped-up a file is.
        public let leaves: Int

        public var unreachable: Int { max(0, linked - reachable) }

        /// Forked means conversation was ABANDONED — a record with two children
        /// where one lineage was continued and the other left behind.
        ///
        /// This read `leaves > 1` until 28 Aug, which flagged every session that
        /// had ever been compacted. Combined with the reachability metric it
        /// replaced, that put "262 forked transcript(s), 32,299 record(s)
        /// unreachable" in the deploy gate's output over a real figure of two
        /// transcripts — and a gate that overstates by two orders of magnitude
        /// is one people learn to read past, which costs more than the check is
        /// worth.
        public var isForked: Bool { unreachable > 0 }

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
    public static let significantUnreachable = 100

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

        // COMPACTION IS NOT A FORK, and reading `parentUuid` alone cannot tell
        // the difference.
        //
        // When Claude Code compacts a conversation it starts a new segment: a
        // `compact_boundary` record with a NULL `parentUuid` — a fresh root —
        // and the real link back into the previous segment stashed in a
        // different field, `logicalParentUuid`. Following parents only, every
        // compaction reads as a severed component, and everything behind it
        // counts as lost.
        //
        // Measured 28 Aug, over all 262 sessions this survey flags. The error
        // is not a rounding error: f37aaddd reported 16,703 unreachable and has
        // 162; 4394c0ec reported 9,114 and has 109; bd28a0a1 reported 3,705 and
        // has 25. Between 8x and 148x, and the factor grows with the session's
        // AGE and compaction count rather than with anything that went wrong —
        // so the sessions shouting loudest were simply the oldest.
        //
        // That is the failure that matters. A detector whose headline number is
        // two orders of magnitude high is one people learn to scroll past, and
        // it was already sitting in the deploy gate's output saying "32,299
        // records unreachable" over a real total closer to a thousand. The one
        // genuine competing-writer fork in f37aaddd — 146 records, 33 minutes,
        // a session whose own transcript recorded `duplicate sessionId
        // f37aaddd — pids 21081 and 98887` while it happened — was buried under
        // 16,541 records of ordinary rolled-off context.
        //
        // The logical edge is used only where the plain one is absent, so a
        // record that has a real parent is unaffected, and a transcript with no
        // compaction surveys exactly as it did before.
        // `logicalParentUuid` IS NOT A TREE EDGE, and using it as one is worse
        // than ignoring it.
        //
        // It was the obvious fix and it was wrong. A manual `/compact` writes
        // its boundary record BEFORE replaying the resume preamble, and the
        // boundary's `logicalParentUuid` points at the last pre-compact record —
        // which, in the physical `parentUuid` chain, is a DESCENDANT of that
        // preamble. Following the logical edge closes a ten-record loop, and a
        // subtree walk around it hands both children of the branch point the
        // same 2,450 records. The file then reports a near-perfect 50/50 fork
        // over three days of work that never diverged at all. Measured on
        // f30bb890: 2,490 abandoned records with the logical edge, 44 without;
        // 50124c48, 2,946 against 27; cdeb1038, 2,519 against 14. Sessions with
        // no manual compaction were identical either way, which is exactly why
        // spot-checking three of them agreed with it.
        //
        // The tree is built on `parentUuid` alone. Compaction then leaves each
        // segment as its own root, and that is CORRECT for this measurement: a
        // root is not a branch point, so sequential segments contribute nothing,
        // which is the answer we wanted from the logical edge in the first
        // place — without inventing a fork to get it.
        var parentOf: [String: String?] = [:]
        var childrenOf: [String: [String]] = [:]
        var isSomeonesParent: Set<String> = []
        for r in records {
            parentOf[r.uuid] = r.parent
            if let p = r.parent, byUuid.contains(p) {
                isSomeonesParent.insert(p)
                childrenOf[p, default: []].append(r.uuid)
            }
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

        // ABANDONED, NOT MERELY UNREACHED. The two are different questions and
        // only the first one is about loss.
        //
        // "Not reachable from the newest leaf" counts every record in every
        // earlier SEGMENT of the conversation. A compaction ends one segment and
        // opens another, and even with the logical edge honoured above, older
        // transcripts carry boundaries that record no edge at all — so the walk
        // stops and the entire history behind it is called lost. It is not lost
        // and it did not diverge: segment N's last record precedes segment N+1's
        // first, sequentially, with no overlap. Nothing forked. The conversation
        // simply continued.
        //
        // A FORK is divergence: one record with two children, where one lineage
        // was continued and the other was left behind. So that is what gets
        // counted — the descendants of every non-surviving child of a real
        // branch point. A separate root chain has no branch point above it and
        // contributes nothing, which is the whole correction.
        //
        // Measured over the 45 largest flagged sessions, 28 Aug: the old
        // question answered 115,987; honouring the logical edge brought it to
        // 13,627; asking about divergence instead brings it to the low hundreds.
        // f37aaddd's real fork is 146 records over 33 minutes, and its own
        // transcript recorded `duplicate sessionId f37aaddd — pids 21081 and
        // 98887` while it was happening. That is the signal, and it was buried
        // under 16,541 records of ordinary rolled-off context.
        //
        // This is not pedantry about a number. The old figure was already in the
        // deploy gate's output — "32,299 record(s) unreachable" — and a gate
        // that overstates by two orders of magnitude is one people learn to read
        // past, which costs more than the check is worth. Same lesson as the
        // 27 Aug drill gate, one layer along.
        // ONE set, not a sum per branch point. An abandoned branch can contain
        // branch points of its own, and counting each subtree separately counts
        // the records below them once per ancestor — which first reported 89,380
        // abandoned records in a 6,782-record file. A record is abandoned or it
        // is not; it cannot be abandoned twice.
        // WHICH CHILD SURVIVED is decided per branch point, not by the file's
        // single newest leaf.
        //
        // Asking "is this child on the path to the final record" only works
        // inside the LAST segment. In an earlier segment no child is on that
        // path, so every child looks abandoned — including the lineage that
        // actually continued, which reported 4,307 abandoned records in a
        // session whose real divergence is nil.
        //
        // The rule that holds everywhere is the one a resume itself follows:
        // the branch written LAST wins. So for each branch point, the surviving
        // child is whichever child's subtree reaches furthest down the file, and
        // its siblings are what was left behind.
        var orderOf: [String: Int] = [:]
        for (i, r) in records.enumerated() { orderOf[r.uuid] = i }
        func subtree(_ root: String) -> Set<String> {
            var out: Set<String> = []
            var stack = [root]
            while let u = stack.popLast() {
                guard !out.contains(u) else { continue }
                out.insert(u)
                stack.append(contentsOf: childrenOf[u] ?? [])
            }
            return out
        }
        var abandonedUuids: Set<String> = []
        for r in linked where (childrenOf[r.uuid]?.count ?? 0) > 1 {
            let subtrees = (childrenOf[r.uuid] ?? []).map { ($0, subtree($0)) }
            guard let survivor = subtrees.max(by: { a, b in
                (a.1.compactMap { orderOf[$0] }.max() ?? -1)
                    < (b.1.compactMap { orderOf[$0] }.max() ?? -1)
            })?.0 else { continue }
            for (child, nodes) in subtrees where child != survivor {
                abandonedUuids.formUnion(nodes)
            }
        }
        let abandoned = linked.filter { abandonedUuids.contains($0.uuid) }.count

        return Survey(sessionId: sessionId,
                      linked: linked.count,
                      reachable: linked.count - abandoned,
                      leaves: leaves.count)
    }
}
