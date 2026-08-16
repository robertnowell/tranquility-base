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
      tbase voices              installed free voices, and what is a download away
      tbase secrets             which credentials are readable, and from where
      tbase discover [days] [n] every session in the window, awake or not,
                                with what would bring each dead one back
      tbase agent-command [cmd] how new AND revived sessions are launched
      tbase revive <id> [--dry-run]
                                bring a dead session back, same path as the panel
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
      tbase send-raw <pid> <tty> <transcript> <text...>
                                          dispatch into the test harness
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

    case "revive":
        // The SAME path the panel's row takes, so exercising this exercises
        // what ships rather than a reimplementation of it: the fresh liveness
        // probe, the directory check, then SessionLauncher.resume.
        guard args.count > 1 else {
            print("usage: tbase revive <sessionId>   (8 chars is enough)")
            exit(1)
        }
        let needle = args[1]
        let found = SessionDiscovery.discover(ttl: 0).sessions
        guard let session = found.first(where: { $0.sessionId.hasPrefix(needle) }) else {
            print("no session in the window starts with \(needle)")
            print("(tbase discover 7 lists them)")
            exit(1)
        }
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
        switch SessionLauncher.resume(sessionId: session.sessionId, directory: command.cwd) {
        case .success:
            print("launched — Terminal should be opening it now")
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
        let dir = args.count > 1 ? (args[1] as NSString).expandingTildeInPath
                                 : SessionLauncher.defaultDirectory
        switch SessionLauncher.launch(directory: dir) {
        case .success:
            print("new Terminal window: `\(SessionLauncher.defaultCommand)` in \(dir)")
            print("its turns enter the loop as soon as the session first stops")
        case .failure(let error):
            print("couldn't launch: \(error.message)")
            print("(Terminal automation permission is the usual suspect)")
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
            print("no live session matching \(needle) — `tbase status` lists them")
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
            ids = (ClaudeAgentsCLI().sessions() ?? []).map(\.sessionId)
        default:
            ids = [args[1]]
        }
        let live = ClaudeAgentsCLI().sessions() ?? []
        for id in ids {
            guard let file = try HomeBase.write(sessionId: id, store: store, live: live)
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
        guard let live = ClaudeAgentsCLI().sessions() else {
            print("(liveness probe FAILED — the app is failing open right now)"); break
        }
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

        guard let live = (ClaudeAgentsCLI().sessions() ?? []).first(where: { $0.sessionId == sessionId }) else {
            print("not dispatched: session is not registered in `claude agents --json`.")
            print("  It is either blocked on a dialog or still starting. Injecting now")
            print("  would answer that dialog, so we refuse.")
            exit(2)
        }
        guard EnrolmentRegistry().isEnrolled(sessionId: sessionId, cwd: live.cwd) else {
            print("not dispatched: session is not enrolled. Run:  tbase enroll \(sessionId)")
            exit(2)
        }
        // Real Claude transcripts live at ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
        let encoded = (live.cwd ?? "").replacingOccurrences(of: "/", with: "-")
        let transcript = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)/\(sessionId).jsonl").path

        let target = DispatchTarget(
            sessionId: sessionId, pid: live.pid, tty: ProcessProbe.tty(of: live.pid),
            transcriptPath: transcript, label: live.name, readinessSource: .claudeAgents)
        report(await TerminalAppTransport().send(text: text, to: target))

    case "send-raw":
        guard args.count > 4, let pid = Int(args[1]) else { usage() }
        let target = DispatchTarget(
            sessionId: "harness-\(pid)", pid: pid, tty: args[2], transcriptPath: args[3],
            label: "test harness", readinessSource: .processAlive)
        report(await TerminalAppTransport().send(text: args.dropFirst(4).joined(separator: " "), to: target))

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
