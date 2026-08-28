import AVFoundation
import Foundation
import TranquilityCore

// tbase — inspect and exercise the voice-dispatch queue from the terminal.
// Step 1 of the build exists to prove the capture leg without any UI at all.

func usage() -> Never {
    print("""
    tbase — Tranquility Base queue inspector

      tbase status              counts by status, plus spool depth
      tbase drain               move spooled hook events into the queue
      tbase events [status]     list events (optionally filtered)
      tbase utterances [status] list utterances
      tbase reconcile           run the boot reconciliation sweep
      tbase reap [hours]        delete audio for confirmed/discarded rows (default 72h)
      tbase install-hooks       merge the hooks into ~/.claude/settings.json (backup kept)
      tbase hook-config         print the settings.json snippet to install the hook
      tbase paths               show where everything lives
      tbase hooks               which hooks are wired, broken, or missing
      tbase forks               transcripts whose history a resume can no longer reach
      tbase voices              installed free voices, and what is a download away
      tbase secrets             which credentials are readable, and from where
      tbase check-keys          ask each provider whether its stored key works
      tbase discover [days] [n] every session in the window, awake or not,
                                with what would bring each dead one back —
                                Claude Code, then a Codex table underneath
      tbase agent-command [cmd] how new AND revived sessions are launched
      tbase revive <id> [--dry-run]
                                bring a dead session back, same path as the panel;
                                falls back to Codex (attemptCodexResume) if the id
                                isn't a Claude Code session
      tbase end <id|prefix|name>
                                end a live session, same path as the grid's
                                right-click: SIGTERM to its process group, and
                                SIGKILL only if it has to. Never touches the tab
      tbase cursors             how far you have got with each session
      tbase calls [n]           full input and output of the last n model calls
      tbase dogfood [days]      WS-E counters summary (default 7 days)
      tbase dogfood record <kind> [note...]
                                append a dogfood event by hand (e.g. attribution_error)
      tbase transcribe <wav> [--apple-only|--openai-only|--assemblyai-only]
                                run the file-based recovery chain, optionally
                                pinned to one rung so it can be probed alone
      tbase transcribe-stream <wav> [--chunk-ms N]
                                replay a saved recording through the AssemblyAI
                                streaming provider in pseudo-realtime; --chunk-ms
                                replays a capture stack's real feed cadence
                                (the AUHAL render callback delivers ~10)

    interruption gate:
      tbase gate                what the interrupt gate would decide right now
      tbase gate-watch [secs]   log-only observation; suppresses nothing

    dispatch:
      tbase targets                       live sessions, with tty and enrolment
      tbase enroll <sessionId>            allow dispatch into a session
                                      (normally unnecessary — the panel asks once)
      tbase enroll --cwd <prefix>         allow dispatch into any session under a path
      tbase enrolment                     show the allowlist
      tbase send <sessionId> <text...>    dispatch into a real session (enrolled only)
    """)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

func ms(_ v: Int64?) -> String {
    guard let v else { return "—" }
    let d = Date(timeIntervalSince1970: Double(v) / 1000)
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f.string(from: d)
}

func truncate(_ s: String?, _ n: Int) -> String {
    guard let s, !s.isEmpty else { return "—" }
    let flat = s.replacingOccurrences(of: "\n", with: " ")
    return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
}

/// Left-pad to a fixed column width.
///
/// Deliberately not `String(format:)` with `(s as NSString).utf8String` — that
/// hands `printf` a pointer to a temporary that is already deallocated, which
/// segfaults intermittently depending on the string.
func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// Print a dispatch result and exit with a code that scripts can branch on.
func report(_ outcome: DispatchOutcome) -> Never {
    switch outcome {
    case .queued:
        print("queued: typed into a session that is mid-turn; it sends when that turn ends")
        exit(0)
    case .confirmed(let ms):
        print("confirmed — text landed and was read back in \(ms)ms")
        exit(0)
    case .deferred(let readiness):
        print("deferred — \(readiness). Nothing was injected; the reply stays queued.")
        exit(3)
    case .failed(.verificationTimedOut):
        print("""
        AMBIGUOUS — keystrokes were sent but the text never appeared in the transcript.
        It may or may not have landed. Deliberately NOT retried: a duplicate injection
        into a live session is worse than a dropped one. Check the tab.
        """)
        exit(4)
    case .failed(let failure):
        print("failed — \(failure)")
        exit(5)
    }
}

do {
    let store = try QueueStore()
    let drainer = SpoolDrainer(store: store)

    switch command {
    case "migrate-secrets":
        let moved = try Secrets.migrateFromKeychain()
        print(moved.isEmpty
            ? "nothing left in the keychain to move"
            : "moved to \(Secrets.fileURL.path): \(moved.map(\.rawValue).joined(separator: ", "))")

    case "paths":
        print("support   \(QueueStore.supportDirectory.path)")
        print("database  \(QueueStore.databaseURL.path)")
        print("audio     \(QueueStore.audioDirectory.path)")
        print("spool     \(QueueStore.supportDirectory.appendingPathComponent("spool.jsonl").path)")

    case "status":
        let spool = QueueStore.supportDirectory.appendingPathComponent("spool.jsonl")
        let spoolLines = (try? String(contentsOf: spool, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        print("spool pending   \(spoolLines)")
        let open = try store.waitingSessions()
        print("waiting         \(open.count) on you"
            + " (\(open.filter { !$0.heard }.count) unannounced)")
        print("events total    \(try store.events(limit: 100_000).count)")
        print("")
        print("waiting sessions:")
        for w in try store.waitingSessions() {
            print("  \(pad(truncate(w.projectLabel, 22), 22)) event \(w.latestId)")
        }
        let utts = try store.utterances(limit: 10_000)
        if !utts.isEmpty {
            print("")
            print("utterances by status:")
            for s in UtteranceStatus.allCases {
                let n = utts.filter { $0.status == s }.count
                if n > 0 { print("  \(pad(s.rawValue, 22)) \(n)") }
            }
        }

    case "discover":
        // Read-only. Every session on this machine inside the window, awake or
        // not, because an agent does not stop existing when its process ends.
        // Nothing here writes to the store or speaks.
        let days = args.count > 1 ? Double(args[1]) ?? 7 : 7
        let limit = args.count > 2 ? Int(args[2]) ?? SessionDiscovery.defaultLimit
                                   : SessionDiscovery.defaultLimit
        let started = Date()
        let found = SessionDiscovery.discover(window: days * 86_400, limit: limit)
        let elapsed = Date().timeIntervalSince(started)

        let candidates = found.scanned
        print("window \(Int(days))d · \(found.sessions.count) interactive of \(candidates) "
            + "transcripts (\(found.headless) headless, \(found.unclassifiable) unclassifiable)"
            + (found.beyondLimit > 0 ? " · \(found.beyondLimit) past the cap" : ""))
        if found.livenessUnavailable {
            print("LIVENESS PROBE FAILED — every row reads unknown and none offers a resume")
        }
        print("")
        print("\(pad("STATE", 9))\(pad("LAMP", 9))\(pad("ANSWERED", 10))"
            + "\(pad("AGE", 8))\(pad("SESSION", 10))\(pad("TITLE", 34))CWD")
        for s in found.sessions {
            let lamp: String
            switch s.activity {
            case .working: lamp = "working"
            case .blocked: lamp = "STOPPED"
            case .stalled: lamp = "SILENT"
            case .idle, nil: lamp = "idle"
            }
            let age = Date().timeIntervalSince(s.lastActivityAt)
            let ageText = age < 3600 ? "\(Int(age / 60))m"
                        : age < 86_400 ? "\(Int(age / 3600))h" : "\(Int(age / 86_400))d"
            let state = s.revivable ? "gone ↺" : s.liveness.rawValue
            print("\(pad(state, 9))\(pad(lamp, 9))\(pad(s.answered ? "yes" : "no", 10))"
                + "\(pad(ageText, 8))\(pad(String(s.sessionId.prefix(8)), 10))"
                + "\(pad(truncate(s.title, 32), 34))\(truncate(s.cwd, 40))")
        }

        // The gate, printed rather than asserted: for sessions the app has been
        // watching all along, does the disk-derived `answered` agree with the
        // store's own waiting set?
        //
        // Reworded 12 Aug for the one-list model: `waiting()` now means ON YOU
        // (latest Stop, live, not dismissed) and carries `heard` as a separate
        // bit, so "on the list" no longer implies "unheard". `answered` is a
        // third thing again — whether you TYPED at it, read from the transcript.
        //
        // Only one combination is a conflict: the list says a turn is on you
        // while the disk says you already answered it in the terminal. That is
        // the case the one-list change handles by consulting SessionActivity
        // for the lamp; this is an independent read of the same truth from the
        // other side, which is exactly what a gate is for.
        let onYou = try store.waitingSessions(limit: 500)
        let waitingIds = Set(onYou.map(\.sessionId))
        let unheardIds = Set(onYou.filter { !$0.heard }.map(\.sessionId))
        let knownIds = Set(try store.allKnownSessions(limit: 1000).map(\.sessionId))
        let overlap = found.sessions.filter { knownIds.contains($0.sessionId) }
        func count(waiting: Bool, answered: Bool) -> Int {
            overlap.filter { waitingIds.contains($0.sessionId) == waiting && $0.answered == answered }
                .count
        }
        let conflicts = overlap.filter { waitingIds.contains($0.sessionId) && $0.answered }
        print("")
        print("revivable       \(found.sessions.filter(\.revivable).count)")
        print("known to store  \(overlap.count) of \(found.sessions.count)")
        print("")
        print("  on you + unanswered    \(count(waiting: true, answered: false))   agree: the row is right")
        print("  on you + ANSWERED      \(conflicts.count)   CONFLICT: on you for a turn you answered")
        print("  off list + unanswered  \(count(waiting: false, answered: false))   dismissed or gone, never replied to")
        print("  off list + answered    \(count(waiting: false, answered: true))   retired both ways")
        print("  of the on-you rows, "
            + "\(overlap.filter { unheardIds.contains($0.sessionId) }.count) still unannounced")
        for s in conflicts.prefix(10) {
            print("    \(s.sessionId.prefix(8))  \(truncate(s.title, 48))")
        }
        print("")
        print(String(format: "scanned in %.2fs", elapsed))

        // Codex's own half — a separate table, not merged into the one above:
        // `discoverCodex` never joins a store (no waiting/known/enrolled
        // concepts exist for Codex yet) and never guesses liveness (the
        // settled design, 2026-08-22-tb-codex-hand-started-adoption) — every
        // row prints `idle`, whether it is actually running somewhere or
        // genuinely gone, on purpose. `tbase revive` is how you find out.
        let codexFound = SessionDiscovery.discoverCodex(window: days * 86_400, limit: limit)
        if codexFound.scanned > 0 {
            print("")
            print("codex: \(codexFound.sessions.count) of \(codexFound.scanned) rollouts "
                + "(\(codexFound.unclassifiable) unclassifiable)"
                + (codexFound.beyondLimit > 0 ? " · \(codexFound.beyondLimit) past the cap" : ""))
            print("")
            print("\(pad("STATE", 9))\(pad("ANSWERED", 10))\(pad("AGE", 8))"
                + "\(pad("SESSION", 10))CWD")
            for s in codexFound.sessions {
                let age = Date().timeIntervalSince(s.lastActivityAt)
                let ageText = age < 3600 ? "\(Int(age / 60))m"
                            : age < 86_400 ? "\(Int(age / 3600))h" : "\(Int(age / 86_400))d"
                let state = s.revivable ? "idle ↺" : "gone"
                print("\(pad(state, 9))\(pad(s.answered ? "yes" : "no", 10))"
                    + "\(pad(ageText, 8))\(pad(String(s.sessionId.prefix(8)), 10))"
                    + "\(truncate(s.cwd, 60))")
            }
        }

    case "lamps":
        // The audit Robert asked for on 18 Aug: "every 30 seconds or so we
        // should be auditing and getting clarity on the current state of all
        // of our agents." The panel already recomputes every 5s — being stale
        // was never the failure. Being CONFIDENTLY WRONG was: a lamp read blue
        // for a session that had finished two hours earlier, and no amount of
        // recomputing fixes a verdict dated by the wrong clock.
        //
        // So this prints both clocks side by side. EVIDENCE is the timestamp of
        // the transcript entry the verdict was read from; FILE is the mtime.
        // They diverge constantly and harmlessly — Claude Code writes
        // snapshots, titles, bridge rows and pr-links to a finished session's
        // transcript for days. The bug was reading FILE as the age of the
        // verdict. The gate at the bottom is the tripwire, and it must stay 0.
        //
        // Runs the SHIPPING classifier (SessionActivity.evidence), never a
        // second implementation of it — an audit that reimplements the thing it
        // audits only ever measures itself.
        let lampDays = args.count > 1 ? Double(args[1]) ?? 2 : 2
        let lampFound = SessionDiscovery.discover(window: lampDays * 86_400,
                                                  limit: SessionDiscovery.defaultLimit)
        let lampBoundaries = (try? store.latestTurnBoundaries()) ?? [:]
        let lampNow = Date()
        func ageText(_ seconds: TimeInterval?) -> String {
            guard let seconds else { return "—" }
            let s = abs(seconds)
            let sign = seconds < 0 ? "-" : ""
            if s < 90 { return "\(sign)\(Int(s))s" }
            if s < 5400 { return "\(sign)\(Int(s / 60))m" }
            if s < 172_800 { return "\(sign)\(Int(s / 3600))h" }
            return "\(sign)\(Int(s / 86_400))d"
        }
        print("window \(Int(lampDays))d · \(lampFound.sessions.count) sessions · "
            + "stalled-at \(Int(SessionActivity.stalled / 60))m")
        print("")
        print("\(pad("LAMP", 9))\(pad("EVIDENCE", 10))\(pad("FILE", 8))\(pad("DRIFT", 8))"
            + "\(pad("SESSION", 10))TITLE")
        var litByFile = 0, drifted = 0
        var drifts: [TimeInterval] = []
        for s in lampFound.sessions {
            guard let e = SessionActivity.evidence(transcriptPath: s.transcriptPath,
                                                   boundary: lampBoundaries[s.sessionId],
                                                   now: lampNow) else { continue }
            let lamp: String
            switch e.activity {
            case .working: lamp = "working"
            case .blocked: lamp = "STOPPED"
            case .stalled: lamp = "SILENT"
            case .idle: lamp = "idle"
            }
            let evidenceAge = e.observedAt.map { lampNow.timeIntervalSince($0) }
            let fileAge = e.modifiedAt.map { lampNow.timeIntervalSince($0) }
            if let d = e.drift, d > SessionActivity.stalled { drifted += 1; drifts.append(d) }
            // The tripwire: a lit lamp whose evidence is older than the
            // stall window can only have been lit by the file.
            if e.activity == .working, let a = evidenceAge, a > SessionActivity.stalled {
                litByFile += 1
            }
            guard e.activity != .idle || (e.drift ?? 0) > SessionActivity.stalled else { continue }
            print("\(pad(lamp, 9))\(pad(ageText(evidenceAge), 10))\(pad(ageText(fileAge), 8))"
                + "\(pad(ageText(e.drift), 8))\(pad(String(s.sessionId.prefix(8)), 10))"
                + truncate(s.title ?? "—", 44))
        }
        print("")
        let sortedDrifts = drifts.sorted()
        let medianDrift = sortedDrifts.isEmpty ? nil : sortedDrifts[sortedDrifts.count / 2]
        print("  files touched past their last word   \(drifted) of \(lampFound.sessions.count)"
            + "   normal — the file is not the conversation")
        print("    median \(ageText(medianDrift))  ·  max \(ageText(sortedDrifts.last))"
            + "   how far a lamp dated by mtime could be wrong")
        print("  lamps lit by the file                \(litByFile)"
            + "   \(litByFile == 0 ? "clean" : "LYING — a lamp is dated by an mtime")")

    case "revive":
        // The SAME path the panel's row takes, so exercising this exercises
        // what ships rather than a reimplementation of it: the fresh liveness
        // probe, the directory check, then SessionLauncher.resume — Claude
        // Code first, Codex as a fallback if the needle isn't a Claude Code
        // session (see below; a genuinely different mechanism, not a
        // reimplementation of the same one).
        guard args.count > 1 else {
            print("usage: tbase revive <sessionId>   (8 chars is enough)")
            exit(1)
        }
        let needle = args[1]
        let found = SessionDiscovery.discover(ttl: 0).sessions
        if let session = found.first(where: { $0.sessionId.hasPrefix(needle) }) {
        print("session    \(session.sessionId)")
        print("title      \(truncate(session.title, 60))")
        print("cwd        \(session.cwd ?? "—")")
        print("liveness   \(session.liveness.rawValue)")
        guard let command = session.reviveCommand else {
            // The refusal that keeps the app alive: resuming a session that is
            // still running puts two processes under one id.
            print("")
            print(session.liveness == .live
                ? "REFUSED — it is already running. Go to its tab instead."
                : "REFUSED — its directory is gone, so --resume would land nowhere.")
            exit(2)
        }
        print("would run  \(AgentDefaults.load()) \(command.arguments.joined(separator: " "))")
        print("in         \(command.cwd)")
        if args.contains("--dry-run") { print(""); print("dry run — nothing launched"); break }
        print("")
        switch SessionLauncher.resume(sessionId: session.sessionId, directory: command.cwd,
                                      launch: HarnessLaunch(harness: session.harness)) {
        case .success:
            print("resumed in a detached tmux pane — `tbase targets` finds it, "
                + "or click Go to Agent")
        case .failure(let error):
            print("failed — \(error.message)")
            exit(3)
        }
        break
        }

        // Not a Claude Code session — check Codex history. A separate
        // branch, not a merged lookup: Codex rows carry no liveness verdict
        // to print (the settled design never guesses one, 2026-08-22-tb-
        // codex-hand-started-adoption), and attaching one is a genuinely
        // different mechanism — attemptCodexResume, not SessionLauncher.
        // resume — because Codex's own single-writer lock is what answers
        // "already live", not a probe run beforehand.
        let codexFound = SessionDiscovery.discoverCodex().sessions
        guard let codexSession = codexFound.first(where: { $0.sessionId.hasPrefix(needle) }) else {
            print("no session in the window starts with \(needle)")
            print("(tbase discover 7 lists them)")
            exit(1)
        }
        print("session    \(codexSession.sessionId)  (codex)")
        print("cwd        \(codexSession.cwd ?? "—")")
        guard codexSession.revivable, let cwd = codexSession.cwd else {
            print("")
            print("REFUSED — its directory is gone, so `codex resume` would land nowhere.")
            exit(2)
        }
        if args.contains("--dry-run") {
            print("")
            print("would attempt  codex resume \(codexSession.sessionId)")
            print("in             \(cwd)")
            print("")
            print("dry run — nothing launched")
            break
        }
        print("")
        print("attempting codex resume \(codexSession.sessionId.prefix(8)) …")
        switch SessionLauncher.attemptCodexResume(sessionId: codexSession.sessionId, directory: cwd) {
        case .success(.attached(let tty)):
            print("attached — tmux pane is live on tty \(tty)")
            print("  tmux attach to continue the conversation directly")
        case .success(.alreadyLive):
            print("REFUSED — it is already running somewhere TB does not control.")
            print("  End it in that terminal, then run this again.")
            exit(2)
        case .failure(let error):
            print("failed — \(error.message)")
            exit(3)
        }

    case "agent-command":
        // The settings pane does not own this yet (see the branch notes), so
        // the CLI is how it gets set. One value, read by every path that starts
        // an agent: the menu item, the grid's "+" row, and revival.
        if args.count > 1 {
            AgentDefaults.save(args.dropFirst().joined(separator: " "))
        }
        print("agent command   \(AgentDefaults.load())")
        print("start directory \(AgentDefaults.directory())"
            + (AgentDefaults.directoryAsTyped().isEmpty ? "  (unset — home)" : ""))
        print("default         \(AgentDefaults.fallback)")
        print("stored at       \(AgentDefaults.fileURL.path)")
        print("")
        print("both are editable in the panel: gear → LAUNCH / DIRECTORY")
        print("")
        print("new sessions launch this; revived sessions launch")
        print("`\(AgentDefaults.load()) --resume <id>` — the same agent, pointed at")
        print("a conversation that already exists.")

    case "drain":
        let r = try drainer.drain()
        print("inserted \(r.inserted)  duplicates \(r.duplicates)  malformed \(r.malformed)")

    case "events":
        // The log, as it is: no status, because events do not have one.
        let rows = try store.events(limit: 40)
        if rows.isEmpty { print("(none)"); break }
        print("\(pad("WHEN", 14))  \(pad("KIND", 8))  \(pad("PROJECT", 18))  LAST MESSAGE")
        for e in rows {
            let when = pad(ms(e.createdAtMs), 14)
            let kind = pad(String(e.hookEvent.rawValue.prefix(8)), 8)
            let project = pad(truncate(e.projectLabel, 18), 18)
            let message = truncate(e.summaryText ?? e.lastAssistantMessage, 56)
            print(when + "  " + kind + "  " + project + "  " + message)
        }

    case "cursors":
        // The only mutable state left, so it gets its own command.
        for w in try store.allKnownSessions(limit: 100) {
            guard let c = try store.cursor(for: w.sessionId) else { continue }
            let heard = c.heardThrough.map(String.init) ?? "-"
            let dismissed = c.dismissedThrough.map(String.init) ?? "-"
            print("  \(pad(truncate(w.projectLabel, 22), 22)) latest \(pad(String(w.latestId), 7)) "
                + "heard \(pad(heard, 7)) dismissed \(dismissed)")
        }

    case "utterances":
        let status = args.count > 1 ? UtteranceStatus(rawValue: args[1]) : nil
        let rows = try store.utterances(status: status, limit: 40)
        if rows.isEmpty { print("(none)"); break }
        for u in rows {
            let audio = u.audioPath.map { FileManager.default.fileExists(atPath: $0) ? "audio✓" : "audio✗" } ?? "no-audio"
            print("\(ms(u.createdAtMs))  \(u.status.rawValue)  \(audio)  \(truncate(u.transcriptText, 50))")
            if let e = u.lastError { print("    error: \(truncate(e, 90))") }
        }

    case "doctor":
        // The seam check. Unit tests cover each piece; this asks whether the
        // pieces still add up on real data, which is where every hub failure
        // this month actually lived.
        var failures = 0

        let problems = HubIntegrity.check()
        if problems.isEmpty {
            print("hub integrity: every recorded page is on its hub, "
                  + "every hub names its session, one footer per page")
        } else {
            for problem in problems {
                print("\(problem.session): \(problem.detail)")
            }
            print("")
            print("\(problems.count) problem(s) — `tbase homebase <id>` rewrites a hub; "
                  + "a missing page means the record never happened")
            failures += problems.count
        }

        // Transcript forks. Read-only, and DELIBERATELY NOT A GATE.
        //
        // relaunch.sh runs this command on every deploy. The forked transcripts
        // on this machine are historical damage that will never be repaired,
        // because re-linking a parent uuid is the one thing the detector must
        // not do — so failing here would block every future deploy over
        // something nobody can fix. That is the archive check that sat red for
        // eight days, rebuilt on purpose. `tbase forks` is the command that
        // judges; this one just says the number.
        //
        // Scoped to the last week for the same reason it does not fail: a full
        // sweep parses ~150MB and costs ~22s, and old damage does not change.
        let recent = TranscriptForks.surveyAll(modifiedWithin: 7 * 24 * 3600)
        let forked = recent.filter(\.isForked)
        if forked.isEmpty {
            print("transcript integrity: no forked transcripts this week")
        } else {
            let serious = forked.filter { $0.unreachable >= TranscriptForks.significantUnreachable }
            let stranded = forked.reduce(0) { $0 + $1.unreachable }
            print("transcript integrity: \(forked.count) forked transcript(s) this week, "
                  + "\(stranded) record(s) unreachable"
                  + (serious.isEmpty
                     ? " (all minor — parallel-agent branching, which no writer guard prevents)"
                     : " — \(serious.count) SIGNIFICANT; run `tbase forks`"))
        }

        if failures > 0 { exit(1) }

    case "forks":
        // The judging half of the fork check. Separate from `doctor` because
        // doctor runs on the deploy path and must not fail over damage that
        // cannot be repaired; this is the command you run deliberately.
        let all = TranscriptForks.surveyAll().filter(\.isForked)
        if all.isEmpty {
            print("no forked transcripts — every session resumes its whole history")
            break
        }
        let significant = all.filter { $0.unreachable >= TranscriptForks.significantUnreachable }
        let minor = all.filter { $0.unreachable < TranscriptForks.significantUnreachable }
        for s in significant {
            print("\(s.sessionId.prefix(8))  \(s.leaves) branches  "
                  + "\(s.unreachable) of \(s.linked) records unreachable")
        }
        if !minor.isEmpty {
            let n = minor.reduce(0) { $0 + $1.unreachable }
            print("")
            print("plus \(minor.count) transcript(s) with \(n) stranded record(s) below the "
                  + "\(TranscriptForks.significantUnreachable) threshold — parallel-agent "
                  + "branching from a single process, which no writer guard can prevent")
        }
        if !significant.isEmpty {
            print("")
            print("\(significant.count) transcript(s) lost conversation to a second writer. "
                  + "Nothing is deleted and every branch is still on disk; a resume follows "
                  + "the branch written LAST, so export before resuming.")
            exit(1)
        }

    case "hooks":
        // The audit that did not exist: what is wired, what points at a file that is
        // gone, and what was never installed at all.
        guard let statuses = HookManifest.audit() else {
            print("cannot read \(HookManifest.settingsURL.path)"); exit(1)
        }
        print("\(pad("EVENT", 18))  \(pad("HOOK", 20))  STATE")
        for s in statuses {
            let state: String
            switch s.state {
            case .installed: state = "ok"
            case .brokenPath(let p): state = "BROKEN — \(p) does not exist"
            case .staleMatcher(let found):
                state = "STALE MATCHER — fires on \(found ?? "everything"), "
                    + "should be \(s.hook.matcher ?? "everything")"
            case .missing: state = "NOT INSTALLED — \(s.hook.purpose)"
            }
            print("\(pad(s.hook.event, 18))  \(pad(s.hook.script, 20))  \(state)")
        }
        if let problem = HookManifest.problemSummary() { print(""); print(problem) }
        else { print(""); print("all hooks installed and reachable") }

    case "voices":
        // Free voices, their quality, and what is one download away. Exists because
        // the picker could not show any of this and the machine looked empty.
        let installed = SystemVoiceCatalog.voices()
        let chosen = SystemVoiceCatalog.downloadedNames()
        print("installed (en-US), best first  [↓ = you downloaded it]:")
        for v in installed.prefix(12) {
            let tier = SystemVoiceCatalog.rank(v.quality) == 3 ? "PREMIUM"
                     : SystemVoiceCatalog.rank(v.quality) == 2 ? "enhanced" : "compact"
            let base = (v.name.split(separator: " ").first.map(String.init) ?? v.name).lowercased()
            let mark = chosen.contains(base) ? "↓" : " "
            let size = SystemVoiceCatalog.sizeMB(named: v.name).map { String(format: "%.0f MB", $0) } ?? ""
            print("  \(mark) \(pad(tier, 9)) \(pad(v.name, 22)) \(size)")
        }
        if installed.count > 12 { print("  … and \(installed.count - 12) more") }
        print("")
        print("speaking with: \(SystemVoiceCatalog.preferredIdentifier() ?? "(system default)")")
        let status = SystemVoiceCatalog.recommendationStatus()
        print("")
        print("recommended free voices:")
        for name in status.installed { print("  ✓ \(name)") }
        for entry in status.missing { print("  ↓ \(entry.name) — \(entry.note)") }
        if !status.missing.isEmpty {
            print("")
            print("to get them: open \(SystemVoiceCatalog.settingsURL)")
            print("then:        \(SystemVoiceCatalog.remainingSteps)")
        }

    case "secrets":
    Secrets.trace = { print("  trace: \($0)") }
    print("file: \(Secrets.fileURL.path)")
    for key in Secrets.Key.allCases {
        let value = Secrets.read(key)
        print("  \(key.rawValue): \(value == nil ? "MISSING" : "present (\(value!.count) chars)")")
    }
    exit(0)

case "check-keys":
    // Asks each provider whether the stored key works, and prints only the
    // verdict. The value is read from the keychain, used for one read-only
    // request, and never printed -- which is what makes this safe to run while
    // somebody is watching the terminal.
    var anyBad = false
    for key in Secrets.Key.allCases {
        guard Secrets.read(key) != nil else {
            print("  \(pad(key.rawValue, 22)) not set")
            continue
        }
        let outcome = await KeyCheck.verifyStored(key)
        let verdict = outcome?.summary ?? "not set"
        print("  \(pad(key.rawValue, 22)) \(verdict)")
        if outcome?.isBad == true { anyBad = true }
    }
    if anyBad {
        print("")
        print("A rejected key is the one worth acting on: the provider looked at it")
        print("and said no. Unreachable says nothing about the key.")
        exit(1)
    }

case "calls":
    // Every model call, whole. A summary that reads wrong is otherwise
    // undebuggable: the inputs come from four places and the output is opaque.
    let count = Int(CommandLine.arguments.dropFirst(2).first ?? "") ?? 3
    let text = (try? String(contentsOf: ModelCallLog.url, encoding: .utf8)) ?? ""
    let lines = text.split(separator: "\n").suffix(count)
    if lines.isEmpty { print("no model calls recorded yet at \(ModelCallLog.url.path)") }
    for line in lines {
        guard let data = line.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        print(String(repeating: "=", count: 78))
        print("\(entry["at"] as? String ?? "?")  \(entry["model"] as? String ?? "?")  "
              + "status \(entry["status"] as? Int ?? -1)  \(entry["elapsedMs"] as? Int ?? -1)ms")
        print("\n--- SYSTEM ---\n\(entry["system"] as? String ?? "")")
        print("\n--- USER ---\n\(entry["user"] as? String ?? "")")
        print("\n--- RESPONSE ---\n\(entry["response"] as? String ?? "")")
    }

case "dogfood":
    // WS-E counters. Counts are computed by query over the append-only
    // dogfood_event log; `record` exists for the kinds a human reports
    // (attribution errors above all) before the app wires its own calls.
    if args.count > 1, args[1] == "record" {
        guard args.count > 2, let kind = DogfoodEventKind(rawValue: args[2]) else {
            print("usage: tbase dogfood record <kind> [note...]")
            print("kinds: \(DogfoodEventKind.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(1)
        }
        let note = args.count > 3 ? args.dropFirst(3).joined(separator: " ") : nil
        try store.recordDogfood(kind, note: note)
        print("recorded \(kind.rawValue)")
        break
    }
    let days = args.count > 1 ? Int(args[1]) ?? 7 : 7
    let summary = try store.dogfoodSummary(days: days)
    print("dogfood counters, last \(days) day(s):")
    for kind in DogfoodEventKind.allCases {
        print("  \(pad(kind.rawValue, 24)) \(summary.counts[kind] ?? 0)")
    }
    if let rate = summary.actionability {
        print("  \(pad("actionability", 24)) \(String(format: "%.0f%%", rate * 100))  (acted-on / spoken)")
    } else {
        print("  \(pad("actionability", 24)) —  (nothing spoken in the window)")
    }

case "reconcile":
        let r = try store.reconcileOnBoot()
        print("requeued for transcription  \(r.requeuedForTranscription.count)")
        print("needs delivery check        \(r.needsDeliveryCheck.count)   <- never auto-resent")
        print("orphaned audio files        \(r.orphanedAudio.count)")
        print("rows whose audio vanished   \(r.missingAudio.count)")
        for id in r.needsDeliveryCheck { print("  ambiguous: \(id)") }

    case "reap":
        let hours = args.count > 1 ? Double(args[1]) ?? 72 : 72
        let n = try store.reapAudio(olderThan: hours * 3600)
        print("deleted \(n) audio file(s) older than \(Int(hours))h (confirmed/discarded only)")

    case "new":
        // Kick off an investigation instead of reacting to one (ruled 05 Aug).
        // Optional argument overrides the directory; the command is fixed in v1.
        SessionLauncher.trace = { print($0) }
        // --codex: a door onto the exact fresh-launch-and-register path the
        // panel's own newSession() uses (default launcher, 26 Aug) — the
        // same reasoning as `tbase end` below, a headless way to exercise a
        // REAL launch without deploying a build. This is what proved the
        // registration fix live: a fresh, message-less Codex launch never
        // wrote a rollout to discover (Codex only writes one after the
        // FIRST TURN), so the old poll timed out on every single launch,
        // silently. Now polls CodexRollout.threadWriterLocksDirectory
        // instead, which Codex writes to immediately.
        let useCodex = args.contains("--codex")
        let adapter: any HarnessAdapter = useCodex ? CodexAdapter() : ClaudeCodeAdapter()
        let dirArg = args.first(where: { $0 != "--codex" && $0 != "new" })
        let dir = dirArg.map { ($0 as NSString).expandingTildeInPath }
            ?? AgentDefaults.directory(for: adapter.id)
        let command = AgentDefaults.load(for: adapter.id)
        let before = useCodex ? Set(CodexRollout.liveThreadIds())
                              : Set((ClaudeAgentsCLI().sessions() ?? [])
                                    .filter { $0.cwd == dir }.map(\.sessionId))
        switch SessionLauncher.launch(
            directory: dir, launch: HarnessLaunch(adapter: adapter, command: command)) {
        case .success(let tty):
            print("detached tmux session (attach on demand): `\(command)` in \(dir)")
            print("waiting for it to register…")
            let sessionId = useCodex
                ? LaunchGreeting.awaitCodexRegistration(excluding: before)
                : LaunchGreeting.awaitRegistration(directory: dir, excluding: before)
            guard let sessionId else {
                print("did not register within 30s (see the trace lines above)")
                break
            }
            print("registered: \(sessionId)")
            // --wait-live: the fuller proof, not just registration — the
            // exact gap that shipped 26 Aug: a fresh Codex session
            // registered fine but read as permanently "gone" the instant
            // Coordinator.waiting() (announce/sweep, not this file's own
            // dispatch code) first polled it, because that function's
            // liveness came from `agents` alone (claude agents --json,
            // which never carries Codex) with no ownership record written
            // at fresh-launch to answer it otherwise. Mirrors newSession()'s
            // own sequence: record ownership (if Codex), write the
            // greeting, then ask a REAL Coordinator whether it's live —
            // the same question the panel's announce/sweep pipeline asks.
            if args.contains("--wait-live") {
                if useCodex, let pid = ProcessProbe.pid(onTty: tty, containing: command) {
                    let pane = TmuxOwnership.pane(forTty: tty)
                    FileSessionOwnershipStore.shared.record(SessionOwnershipRecord(
                        sessionId: sessionId, harness: CodexAdapter().id, pid: pid,
                        paneId: pane?.paneId, socketName: pane?.socketName,
                        sessionName: pane?.sessionName, paneTty: tty, cwd: dir))
                    print("ownership recorded: pid \(pid)")
                }
                try LaunchGreeting.record(sessionId: sessionId, directory: dir,
                                          line: "tbase new --wait-live probe", store: store)
                print("greeting recorded — sleeping 3s (past the window the bug fired in)…")
                try await Task.sleep(nanoseconds: 3_000_000_000)
                Coordinator.trace = { print("  coordinator: \($0)") }
                let coordinator = Coordinator(store: store)
                let stillWaiting = try coordinator.waiting().map(\.sessionId)
                if stillWaiting.contains(sessionId) {
                    print("✓ still live in Coordinator.waiting() after 3s")
                } else {
                    print("✗ NOT in Coordinator.waiting() — this is the bug")
                }
            }
        case .failure(let error):
            print("couldn't launch: \(error.message)")
            print("(a missing tmux binary or `new-session` failing is the usual suspect —")
            print(" launches stopped touching Terminal automation 21 Aug)")
        }

    case "end":
        // The grid's right-click, headless — and the same code path, for the
        // same reason `tbase new` exists beside the launcher's menu item: the
        // panel has no unit tests (rule 7), so the only way to exercise the
        // ladder against a REAL process without deploying a build is to give it
        // a door that is not the GUI. What this proves and the drill cannot:
        // that the group signal takes the MCP children, and that the terminal
        // tab is still sitting at its shell prompt afterwards.
        guard args.count > 1 else {
            print("usage: tbase end <sessionId | id-prefix | name>")
            print("       SIGTERM first, SIGKILL only if it has to; never touches the tab")
            break
        }
        let needle = args[1]
        SessionTermination.trace = { print($0) }
        guard let live = (ClaudeAgentsCLI().sessions() ?? []).first(where: {
            $0.sessionId == needle || $0.sessionId.hasPrefix(needle) || $0.name == needle
        }) else {
            // Not a live Claude Code session — check the ownership record.
            // Kill is only ever offered on a pid TB currently holds through
            // that record; there is no code path that guesses a Codex pid
            // to end, matching the resolved design
            // (2026-08-22-tb-codex-hand-started-adoption).
            let matchedId = FileSessionOwnershipStore.shared.all()
                .first(where: { $0.sessionId == needle || $0.sessionId.hasPrefix(needle) })?.sessionId
            guard let matchedId,
                  let record = FileSessionOwnershipStore.shared.verifiedCurrent(sessionId: matchedId)
            else {
                print("no live session matching \(needle) — `tbase status` lists Claude Code, "
                    + "`tbase discover` lists Codex")
                break
            }
            let label = String(record.sessionId.prefix(8))
            switch SessionTermination.end(pid: record.pid, named: label,
                                          expectedTty: ProcessProbe.tty(of: record.pid),
                                          expectedCommand: CodexAdapter().processCommandFragment) {
            case .alreadyGone:
                print("\(label) was already gone")
                FileSessionOwnershipStore.shared.remove(sessionId: record.sessionId)
            case .died(let rung, let ms, let target):
                print("\(label) died on \(rung.rawValue) after \(ms)ms "
                    + "(\(SessionTermination.describe(target)))")
                // The record no longer names anything alive — removed so a
                // later `send`/`end` fails honestly rather than finding a
                // pid `ProcessProbe.isAlive` happens to have reused.
                FileSessionOwnershipStore.shared.remove(sessionId: record.sessionId)
            case .survived:
                print("\(label) SURVIVED both signals")
            case .refused(let why):
                print("refused: \(why)")
            }
            break
        }
        let label = live.name ?? String(live.sessionId.prefix(8))
        switch SessionTermination.end(pid: live.pid, named: label,
                                      expectedTty: ProcessProbe.tty(of: live.pid)) {
        case .alreadyGone:      print("\(label) was already gone")
        case .died(let rung, let ms, let target):
            print("\(label) died on \(rung.rawValue) after \(ms)ms "
                + "(\(SessionTermination.describe(target)))")
        case .survived:         print("\(label) SURVIVED both signals")
        case .refused(let why): print("refused: \(why)")
        }

    case "homebase":
        // One page per agent, generated from the briefs that every turn already
        // writes. Nothing is narrated and nothing is asked of the session: the
        // page is a projection of a table that fills itself.
        guard args.count > 1 else {
            print("usage: tbase homebase <agentId> [--open]")
            print("       tbase homebase --live     (every agent running now)")
            print("       tbase homebase --all      (every agent ever summarized)")
            break
        }
        let wantsOpen = args.contains("--open")
        let ids: [String]
        switch args[1] {
        case "--all":
            ids = Array(Set(try store.recentBriefs(limit: 2000).map(\.sessionId)))
        case "--live":
            // A hub is for an agent you are still working with. The archive is
            // the transcript's job — building a page for every session that
            // ever ran fills the directory with agents nobody will open again,
            // which is the same mess in a different window.
            ids = ((ClaudeAgentsCLI().sessions() ?? [])
                + FileSessionOwnershipStore.shared.liveNonRegistrySessions()).map(\.sessionId)
        default:
            ids = [args[1]]
        }
        let live = (ClaudeAgentsCLI().sessions() ?? [])
            + FileSessionOwnershipStore.shared.liveNonRegistrySessions()
        for id in ids {
            // Priming: the CLI is not the main actor, and somebody typing
            // `tbase homebase` is asking for the finished page — a hub written
            // here with a cold snapshot has no pull request rows at all, which
            // is how this shipped looking empty the first time it was rendered
            // after the rewrite.
            guard let file = try HomeBase.write(sessionId: id, store: store, live: live,
                                                priming: true)
            else { print("no briefs for \(id.prefix(8)) — nothing to write yet"); continue }
            print(file.path)
            if wantsOpen, ids.count == 1 {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"),
                                     arguments: [file.path])
            }
        }

    case "install-hooks":
    // One command instead of JSON surgery, now the same code path the app runs
    // at launch. Run from the repo root: records the hooks directory, then
    // repairs settings against the shared manifest — a moved repo's stale
    // paths are REWRITTEN, not kept (the old presence test matched on the
    // basename, printed "already installed; nothing changed", and preserved
    // the dead command — issue 09).
    let hooksDir = FileManager.default.currentDirectoryPath + "/hooks"
    let allPresent = HookManifest.expected.map(\.script).allSatisfy {
        FileManager.default.isExecutableFile(atPath: hooksDir + "/" + $0)
    }
    guard allPresent else {
        print("run from the repo root: hooks/*.sh not found or not executable"); exit(1)
    }
    try? hooksDir.write(to: HookManifest.recordedDirectoryURL,
                        atomically: true, encoding: .utf8)
    switch HookManifest.repair() {
    case .healthy:
        print("already installed and reachable; nothing changed")
    case .repaired(let rewired, let added):
        print("repaired: \(rewired) rewired, \(added) added; "
              + "backup at settings.json.tbase-backup")
        print("restart Claude Code sessions (or open /hooks once) to load them")
    case .unavailable(let reason):
        print("could not repair: \(reason)"); exit(1)
    }

    case "hook-config":
        let hookPath = FileManager.default.currentDirectoryPath + "/hooks/tbase-hook.sh"
        let visualPath = FileManager.default.currentDirectoryPath + "/hooks/visual-output-hook.sh"
        let artifactPath = FileManager.default.currentDirectoryPath + "/hooks/artifact-hook.sh"
        print("""
        Add to ~/.claude/settings.json (merge with existing hooks):

        "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "\(hookPath)"}]}],
        "Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "\(hookPath)"}]}],
        "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "\(hookPath)"}]}],
        "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "\(visualPath)"}]}],
        "PostToolUse": [{"matcher": "Write", "hooks": [{"type": "command", "command": "\(artifactPath)"}]}]
        """)

    // MARK: dispatch

    case "targets":
        let enrolment = EnrolmentRegistry()
        guard let claudeLive = ClaudeAgentsCLI().sessions() else {
            print("(liveness probe FAILED — the app is failing open right now)"); break
        }
        // Codex has no probe to fail — its half of this list is whatever
        // `ownership` currently verifies as alive, unconditionally.
        let live = claudeLive + FileSessionOwnershipStore.shared.liveNonRegistrySessions()
        if live.isEmpty { print("(no live sessions)"); break }
        print("\(pad("STATUS", 8))  \(pad("PID", 7))  \(pad("TTY", 14))  \(pad("ENROLLED", 9))  PROJECT")
        for s in live.sorted(by: { ($0.cwd ?? "") < ($1.cwd ?? "") }) {
            let tty = ProcessProbe.tty(of: s.pid) ?? "—"
            let ok = enrolment.isEnrolled(sessionId: s.sessionId, cwd: s.cwd) ? "yes" : "no"
            let project = (s.cwd as NSString?)?.lastPathComponent ?? "—"
            print("\(pad(s.status ?? "?", 8))  \(pad(String(s.pid), 7))  \(pad(tty, 14))  \(pad(ok, 9))  \(project)")
            print("         \(s.sessionId)")
        }

    case "enrolment":
        let (sessions, prefixes, all) = EnrolmentRegistry().summary()
        print("allowAll: \(all)")
        print("sessions: \(sessions.isEmpty ? "(none)" : sessions.joined(separator: ", "))")
        print("prefixes: \(prefixes.isEmpty ? "(none)" : prefixes.joined(separator: ", "))")

    case "enroll":
        guard args.count > 1 else { usage() }
        let registry = EnrolmentRegistry()
        if args[1] == "--cwd", args.count > 2 {
            try registry.enrol(cwdPrefix: args[2])
            print("enrolled all sessions under \(args[2])")
        } else {
            try registry.enrol(sessionId: args[1])
            print("enrolled session \(args[1])")
        }

    case "send":
        guard args.count > 2 else { usage() }
        let sessionId = args[1]
        let text = args.dropFirst(2).joined(separator: " ")

        // The same per-target selection Coordinator makes: a duplicate
        // sessionId (Claude Code tolerates two processes dual-live on one
        // conversation) resolves to TB's own tmux-owned row when one exists,
        // never an arbitrary one of the two — this CLI is a second real
        // dispatch door onto the same targets, per CLAUDE.md rule 7.
        guard let (live, resolvedPane) = (ClaudeAgentsCLI().sessions() ?? [])
            .preferringTmuxOwned(sessionId: sessionId) else {
            // Not a live Claude Code session — check the ownership record
            // before refusing outright. A real branch, not a fallback
            // guess: TB only ever comes to hold a Codex pid through a
            // resume that already succeeded (`attemptCodexResume`), so a
            // hit here is never inferred the way a hand-started session's
            // liveness would be.
            guard let record = FileSessionOwnershipStore.shared.verifiedCurrent(sessionId: sessionId),
                  record.harness == CodexAdapter().id, let pane = record.pane else {
                print("not dispatched: session is not registered in `claude agents --json`,")
                print("  and TB holds no ownership record for it either (not attached, or the")
                print("  attach exited since). Run  tbase revive \(sessionId)  first.")
                exit(2)
            }
            guard EnrolmentRegistry().isEnrolled(sessionId: sessionId, cwd: record.cwd) else {
                print("not dispatched: session is not enrolled. Run:  tbase enroll \(sessionId)")
                exit(2)
            }
            let target = DispatchTarget(
                kind: .tmux, sessionId: sessionId, pid: record.pid, tty: record.paneTty,
                pane: pane, transcriptPath: CodexRollout.rolloutPath(forSessionId: sessionId),
                label: nil, readinessSource: .rolloutTail,
                promptGlyph: CodexAdapter().capabilities.promptGlyph,
                // Found live, 22 Aug: without this, Codex's own idle hint
                // text reads as someone's unsent message and every
                // dispatch is refused — floorHeld, permanently, on an
                // otherwise-idle composer. See classifyPromptLine's doc
                // comment.
                idlePlaceholder: CodexAdapter().trustPrompt?.settledBannerNeedle)
            report(await TmuxTransport().send(text: text, to: target))
            break
        }
        guard EnrolmentRegistry().isEnrolled(sessionId: sessionId, cwd: live.cwd) else {
            print("not dispatched: session is not enrolled. Run:  tbase enroll \(sessionId)")
            exit(2)
        }
        // FOUND, not derived (codebase audit, 21 Aug): a hand-rolled `/` → `-`
        // encoding lived here and was wrong for exactly this repo's own
        // worktrees — Claude Code also maps `.` → `-`, so a session running
        // under `.claude/worktrees/…` (every session working this arc, per
        // CLAUDE.md rule 5) resolved to a path that does not exist. The text
        // still landed; delivery just could never confirm it, burning every
        // retry and the extra one-Return attempt each time before timing out.
        // See TranscriptArchive.transcriptPath's own doc for why this must
        // never be reproduced by hand a second time.
        let transcript = TranscriptArchive.transcriptPath(forSessionId: sessionId)

        if live.isBackground {
            print("not dispatched: this is a first-party background session")
            print("  (claude --bg-pty-host) with no tab and no supported input channel.")
            exit(2)
        }
        // Reused from selection above rather than re-resolved: two live
        // lookups for the same pid, moments apart, can disagree if a pane
        // closes in between (the 19 Aug misfire's shape).
        var pane = resolvedPane
            ?? TmuxOwnership.pane(forSessionId: live.sessionId, pid: live.pid)
        var dispatchPid = live.pid
        if pane == nil, let cwd = live.cwd {
            // Same transfer the real app's `Coordinator.dispatch` makes —
            // this CLI is a second real dispatch door onto the same
            // targets (CLAUDE.md rule 7), not a lesser one, so a
            // hand-started session gets the same ownership TRANSFER here,
            // not a different refusal.
            if let transferred = SessionLauncher.OwnershipTransfer.toTmux(
                sessionId: sessionId,
                // `live` came from `ClaudeAgentsCLI`, so this session is a
                // Claude Code one by construction; Codex targets never reach
                // this branch. Named rather than defaulted, because a default
                // here is exactly what ended a session with the wrong binary.
                launch: HarnessLaunch(harness: ClaudeCodeAdapter().id),
                directory: cwd) {
                pane = transferred.pane
                dispatchPid = transferred.pid
            }
        }
        guard let pane else {
            print("not dispatched: tmux is unavailable for this session (no pane, and "
                + "resuming one under tmux failed)")
            exit(2)
        }
        let target = DispatchTarget(
            kind: .tmux,
            sessionId: sessionId, pid: dispatchPid, tty: ProcessProbe.tty(of: dispatchPid),
            pane: pane, transcriptPath: transcript, label: live.name,
            readinessSource: .claudeAgents)
        report(await TmuxTransport().send(text: text, to: target))

    case "send-raw-tmux":
        // The tmux twin of send-raw, and what scripts/test-dispatch-tmux.sh
        // drives: <pid> <pane-id> <transcript> <text…> against the app's own
        // socket (TB_TMUX_SOCKET overrides for throwaway drill servers).
        guard args.count > 4, let pid = Int(args[1]) else { usage() }
        let socket = ProcessInfo.processInfo.environment["TB_TMUX_SOCKET"] ?? Tmux.socketName
        let pane = TmuxPaneAddress(socketName: socket, paneId: args[2],
                                   sessionName: "harness", paneTty: "")
        let target = DispatchTarget(
            kind: .tmux, sessionId: "harness-\(pid)", pid: pid, pane: pane,
            transcriptPath: args[3], label: "test harness", readinessSource: .processAlive)
        // The drill's own eyes. Without this, a failing send in
        // test-dispatch-tmux.sh reports only its outcome, and working out WHY
        // meant adding a print, rebuilding, and hoping the flake recurred —
        // which is how three rounds of timeout-tuning got argued from noise.
        // stderr, so the drill's stdout parsing is untouched.
        if ProcessInfo.processInfo.environment["TB_TRACE"] != nil {
            TmuxTransport.trace = { line in
                FileHandle.standardError.write(Data(("trace: " + line + "\n").utf8))
            }
        }
        report(await TmuxTransport().send(text: args.dropFirst(4).joined(separator: " "), to: target))

    // MARK: summarize

    case "set-key":
        guard args.count > 1, let key = Secrets.Key(rawValue: args[1] + "-api-key")
            ?? Secrets.Key.allCases.first(where: { $0.rawValue.hasPrefix(args[1]) })
        else {
            print("usage: tbase set-key <anthropic|elevenlabs|assemblyai>")
            exit(1)
        }
        let value: String
        if args.count > 3, args[2] == "--from-env" {
            // Lets a secret broker inject the value (e.g.
            //   claude-secrets run --inject NAME=VD_KEY -- tbase set-key anthropic --from-env VD_KEY)
            // so it never appears in argv, in a terminal, or in scrollback.
            guard let injected = ProcessInfo.processInfo.environment[args[3]], !injected.isEmpty else {
                print("environment variable \(args[3]) is empty or unset")
                exit(1)
            }
            value = injected
        } else {
            // getpass keeps the value off the terminal and out of any process argv.
            guard let entered = getpass("Paste \(key.rawValue) (input hidden): ").map({ String(cString: $0) }),
                  !entered.isEmpty
            else { print("nothing entered"); exit(1) }
            value = entered
        }
        try Secrets.write(key, value: value)
        print("stored \(key.rawValue) in the login keychain (service: \(Secrets.service))")

    case "summarize":
        guard args.count > 1 else { usage() }
        let text = args.dropFirst().joined(separator: " ")
        let summary = await SummarizerChain().summarize(
            SummaryRequest(lastAssistantMessage: text, projectLabel: "scratch"))
        print("[\(summary.provider), \(summary.latencyMs)ms, \(summary.spoken.wordCount) words]")
        print(summary.spoken.text)
        if !summary.spoken.redactions.isEmpty {
            print("redacted: \(Set(summary.spoken.redactions).sorted().joined(separator: ", "))")
        }

    case "summarize-corpus":
        let n = args.count > 1 ? Int(args[1]) ?? 10 : 10
        let showInput = args.contains("--show-input")
        let speakIt = args.contains("--speak")
        let samples = TranscriptArchive.recentSamples(limit: n)
        guard !samples.isEmpty else { print("no archived transcripts found"); break }

        let chain = SummarizerChain()
        var overBudget = 0, withRedactions = 0, totalWords = 0, totalMs = 0
        print("running \(samples.count) real transcripts through the summarizer\n")

        for sample in samples {
            let summary = await chain.summarize(SummaryRequest(
                lastAssistantMessage: sample.lastAssistantMessage,
                projectLabel: sample.projectLabel,
                firstUserMessage: sample.firstUserMessage,
                gitBranch: sample.gitBranch))
            let w = summary.spoken.wordCount
            totalWords += w
            totalMs += summary.latencyMs
            if w > SpokenTextSanitizer.maxWords { overBudget += 1 }
            if !summary.spoken.redactions.isEmpty { withRedactions += 1 }

            // ~13s of speech at 35 words; scale linearly from the measured rate.
            let seconds = Double(w) * 0.39

            if showInput {
                print(String(repeating: "─", count: 100))
                print("PROJECT  \(sample.projectLabel)   (\(sample.lastAssistantMessage.count) chars in)")
                print("")
                print("INPUT — the agent's final message:")
                let input = sample.lastAssistantMessage
                let shown = input.count > 900 ? String(input.prefix(900)) + "\n[… \(input.count - 900) more chars]" : input
                for line in shown.split(separator: "\n", omittingEmptySubsequences: false) {
                    print("  \(line)")
                }
                print("")
                print("OUTPUT — \(w) words, ~\(String(format: "%.0f", seconds))s spoken, \(summary.latencyMs)ms, via \(summary.provider):")
                print("  \(summary.spoken.text)")
                if !summary.spoken.redactions.isEmpty {
                    print("  redacted: \(Set(summary.spoken.redactions).sorted().joined(separator: ", "))")
                }
                print("")
            } else {
                // Render the actual audio to get a real duration, not an estimate —
                // "how long does this take to say" is the whole question.
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vd-\(UUID().uuidString).aiff")
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-r", "200", "-o", tmp.path, summary.spoken.text]
                try? say.run(); say.waitUntilExit()
                var spokenSeconds = "?"
                let info = Process()
                info.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
                info.arguments = [tmp.path]
                let pipe = Pipe(); info.standardOutput = pipe; info.standardError = Pipe()
                try? info.run()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                info.waitUntilExit()
                if let line = out.split(separator: "\n").first(where: { $0.contains("estimated duration") }),
                   let value = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: " ").first {
                    spokenSeconds = String(format: "%.1f", Double(value) ?? 0)
                }
                try? FileManager.default.removeItem(at: tmp)

                print("── \(sample.projectLabel)  ·  \(w) words, \(spokenSeconds)s to say, \(summary.latencyMs)ms to generate")
                if let recap = summary.brief.recap {
                    print("   RECAP:    \(recap)   [\(recap.split(separator: " ").count)w]")
                }
                if let proposal = summary.brief.proposal {
                    print("   PROPOSAL: \(proposal)   [\(proposal.split(separator: " ").count)w]")
                }
                if summary.brief.recap == nil {
                    print("   HEARD:    \(summary.spoken.text)")
                }
                print("   card:     " + summary.brief.cardLines()
                    .filter { $0.0 != "topic" }
                    .map { "\($0.0)=\($0.1)" }.joined(separator: " · "))
                if speakIt {
                    let voice = await SpeechChain(preferred: ElevenLabsSpeechProvider())
                        .speak(summary.spoken)
                    print("   → spoken via \(voice)")
                }
                print("")
            }
        }

        print("")
        print("mean \(totalWords / samples.count) words (~\(String(format: "%.0f", Double(totalWords) / Double(samples.count) * 0.39))s), \(totalMs / samples.count)ms")
        print("over budget: \(overBudget)/\(samples.count)   needed redaction: \(withRedactions)/\(samples.count)")

    // MARK: speech + gate

    case "speak":
        guard args.count > 1 else { usage() }
        let spoken = SpokenTextSanitizer().sanitize(args.dropFirst().joined(separator: " "))
        print("[\(spoken.wordCount) words, ~\(String(format: "%.0f", Double(spoken.wordCount) * 0.39))s]")
        print(spoken.text)
        let start = Date()
        let used = await SpeechChain(preferred: ElevenLabsSpeechProvider()).speak(spoken)
        print("spoken via \(used) in \(Int(Date().timeIntervalSince(start) * 1000))ms")

    case "gate":
        let decision = InterruptGate().evaluate()
        print("allowed:      \(decision.allowed)")
        print("reason:       \(decision.reason)")
        print(String(format: "idle:         %.1fs", decision.idleSeconds))
        print("frontmost:    \(decision.frontmostApp ?? "unknown")")
        print("screenLocked: \(decision.screenLocked)")
        


    case "gate-watch":
        // Log-only observation. Records what the gate WOULD decide, and acts on
        // nothing — thresholds picked in the abstract are usually wrong, so this
        // runs for a day before the gate is allowed to suppress anything.
        let seconds = args.count > 1 ? Double(args[1]) ?? 3600 : 3600
        let gate = InterruptGate()
        let log = GateObservationLog()
        let deadline = Date().addingTimeInterval(seconds)
        print("observing for \(Int(seconds))s, sampling every 15s -> \(log.url.path)")
        print("(nothing is suppressed; this only records what would have happened)")
        var samples = 0, wouldAllow = 0
        while Date() < deadline {
            let d = gate.evaluate()
            log.record(d, context: "watch")
            samples += 1
            if d.allowed { wouldAllow += 1 }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
        print("\(samples) samples, would have allowed \(wouldAllow) (\(samples > 0 ? wouldAllow * 100 / samples : 0)%)")

    case "gate-report":
        let log = GateObservationLog()
        guard let raw = try? String(contentsOf: log.url, encoding: .utf8), !raw.isEmpty else {
            print("no observations yet — run `tbase gate-watch` first")
            break
        }
        var total = 0, allowed = 0
        var reasons: [String: Int] = [:]
        var apps: [String: Int] = [:]
        for line in raw.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            total += 1
            if (o["allowed"] as? Bool) == true { allowed += 1 }
            reasons[(o["reason"] as? String) ?? "?", default: 0] += 1
            if let a = o["frontmostApp"] as? String, !a.isEmpty { apps[a, default: 0] += 1 }
        }
        print("\(total) observations, \(allowed) would have been allowed (\(total > 0 ? allowed * 100 / total : 0)%)")
        print("\nveto reasons:")
        for (r, n) in reasons.sorted(by: { $0.value > $1.value }).prefix(6) { print("  \(pad(String(n), 6)) \(r)") }
        print("\nfrontmost apps:")
        for (a, n) in apps.sorted(by: { $0.value > $1.value }).prefix(6) { print("  \(pad(String(n), 6)) \(a)") }

    // MARK: transcription

    case "transcribe":
        guard args.count > 1 else { usage() }
        let url = URL(fileURLWithPath: args[1])
        AppleSpeechRecovery.trace = { print("  apple-speech: \($0)") }
        // Provider filters, born of the 12 Aug truncation: the chain's order
        // hid each rung's individual behaviour — OpenAI answered every probe
        // short enough to check, so the Apple floor's 60-second stop was never
        // once seen until it was the last rung standing under a 27-minute
        // recording. A rung you cannot exercise alone is a rung you know
        // nothing about.
        AssemblyAIFileRecovery.trace = { print("  assemblyai-file: \($0)") }

        // --churn recreates the 12 Aug interference in-process while the
        // chain runs: brief (~120ms) input-engine opens on a cadence — the
        // arm window's mic, which opened twice during the incident's
        // recognition — over a continuously rendering silent output, which
        // is what the TTS was doing. The recogniser stopped at 60.21s of
        // 1690.86s under two such opens in 27 minutes; this cycles every 8
        // SECONDS, so a floor that survives here has survived far worse
        // than the field. The lab for "can't we force that fallback?".
        var churn: Task<Void, Never>?
        if args.contains("--churn") {
            let out = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: args[1]))
            out?.volume = 0
            out?.numberOfLoops = -1
            out?.play()
            print("churn: silent output \(out == nil ? "FAILED" : "rendering"), "
                + "input engine cycling every 8s")
            churn = Task.detached {
                var cycles = 0
                while !Task.isCancelled {
                    // No tap: installTap races the very format churn this
                    // harness generates and aborts the process on the ObjC
                    // exception (crashed cycle 4 of the first run). Opening
                    // the input HAL device is the churn; a muted passthrough
                    // is enough to make the engine start it.
                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    if input.outputFormat(forBus: 0).sampleRate > 0 {
                        engine.connect(input, to: engine.mainMixerNode, format: nil)
                        engine.mainMixerNode.outputVolume = 0
                        try? engine.start()
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        engine.stop()
                        cycles += 1
                        print("  churn: input engine cycle \(cycles)")
                    } else {
                        print("  churn: input unavailable")
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                }
                _ = out
            }
        }
        defer { churn?.cancel() }

        let chain: RecoveryChain
        if args.contains("--apple-only") {
            chain = RecoveryChain(providers: [AppleSpeechRecovery()])
        } else if args.contains("--openai-only") {
            chain = RecoveryChain(providers: [OpenAIRecovery()])
        } else if args.contains("--assemblyai-only") {
            chain = RecoveryChain(providers: [AssemblyAIFileRecovery()])
        } else {
            chain = RecoveryChain()
        }
        print("providers: " + chain.providers
            .map { "\($0.name)\($0.isConfigured ? "" : " (unconfigured)")" }
            .joined(separator: " → "))
        let start = Date()
        let outcome = await chain.transcribe(fileAt: url)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        for attempt in outcome.attempts { print("  \(attempt)") }
        if let result = outcome.result {
            print("\n[\(result.provider), \(result.finality.rawValue), \(ms)ms]")
            print(result.text)
        } else {
            print("\nno provider succeeded — \(outcome.lastFailure.map { "\($0)" } ?? "unknown")")
            print("The audio is untouched; retry with `tbase retry-failed` once a provider is available.")
            exit(6)
        }

    case "lexicon":
        // What the app is actually biasing toward right now. A vocabulary
        // feature nobody can inspect is a vocabulary feature nobody can trust.
        let lex = Lexicon.harvest(store: store)
        print("\(lex.terms.count) term(s), priority order "
              + "(callsigns and project labels first, then recency-weighted):")
        for (i, term) in lex.terms.enumerated() {
            print(String(format: "  %3d. %@", i + 1, term))
        }
        if args.count > 1 {
            let needle = args[1].lowercased()
            let hit = lex.terms.first { $0.lowercased() == needle }
            print("\n\"\(args[1])\": \(hit != nil ? "PRESENT as \"\(hit!)\"" : "ABSENT")")
        }

    case "transcribe-stream":
        // Chunk a saved recording through the AssemblyAI streaming provider in
        // pseudo-realtime — verification of the live path without a live mic.
        // The file-based chain is untouched by design: in the app this provider
        // only ever runs ALONGSIDE the always-saved audio file.
        guard args.count > 1 else { usage() }
        AssemblyAIStreaming.trace = { print("  assemblyai: \($0)") }
        StreamedUtterance.trace = { print("  stream: \($0)") }
        let provider = AssemblyAIStreaming()
        guard provider.isConfigured else {
            print("assemblyai key is not configured — run: tbase set-key assemblyai")
            exit(2)
        }
        let fileURL = URL(fileURLWithPath: args[1])
        guard let pcm = BuddyPCM16Converter.pcm16Data(contentsOf: fileURL) else {
            print("could not read audio at \(fileURL.path)")
            exit(1)
        }
        // `--no-lexicon` is the A/B control: the same audio through the same
        // provider with the vocabulary withheld, which is the only way to say
        // what the lexicon is actually worth rather than assuming it works.
        let withoutLexicon = args.contains("--no-lexicon")
        let lexicon = withoutLexicon ? Lexicon(terms: []) : Lexicon.harvest(store: store)
        let keyterms = AssemblyAIStreaming.keyterms(from: lexicon.terms)
        print("streaming \(String(format: "%.1f", Double(pcm.count) / 32_000))s of audio "
              + "with \(keyterms.count) keyterm(s)")

        let stream = StreamedUtterance(
            provider: provider, lexicon: lexicon.terms,
            onPartial: { print("  partial: \($0)") })
        await stream.start()

        // 100ms feeds by default, paced near realtime as the API asks for
        // pre-recorded audio — faster makes Turn boundaries unreliable.
        // `--chunk-ms N` overrides the FEED cadence to replay a capture
        // stack's real delivery (the AUHAL render callback hands ~10ms — the
        // 12 Aug outage's cadence); whatever is fed, the session owns the
        // wire's 50–1000ms contract and re-chunks before sending.
        let chunkMs = args.firstIndex(of: "--chunk-ms")
            .flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 100
        let chunkBytes = max(2, chunkMs * 32)  // 16kHz PCM16: 32 bytes/ms
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            stream.feed(pcm16: pcm.subdata(in: offset..<end))
            offset = end
            try? await Task.sleep(nanoseconds: UInt64(chunkMs) * 900_000)
        }
        let finalStarted = Date()
        if let result = await stream.finish(timeout: 15) {
            let waitMs = Int(Date().timeIntervalSince(finalStarted) * 1000)
            print("\n[\(result.provider), \(result.finality.rawValue), final \(waitMs)ms after end-of-audio]")
            print(result.text)
        } else {
            print("\nstream produced no trustworthy final — in the app this utterance")
            print("falls back to the file-based recovery chain (the audio is always saved first).")
            exit(6)
        }

    case "retry-failed":
        let recovered = try await store.retryFailedTranscriptions()
        if recovered.isEmpty { print("nothing to recover"); break }
        for u in recovered {
            print("recovered \(u.id) via \(u.transcriptProvider ?? "?"): \(truncate(u.transcriptText, 70))")
        }

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write("tbase: \(error)\n".data(using: .utf8)!)
    exit(1)
}
