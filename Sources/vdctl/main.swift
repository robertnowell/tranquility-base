import Foundation
import VoiceDispatchCore

// vdctl — inspect and exercise the voice-dispatch queue from the terminal.
// Step 1 of the build exists to prove the capture leg without any UI at all.

func usage() -> Never {
    print("""
    vdctl — voice dispatch queue inspector

      vdctl status              counts by status, plus spool depth
      vdctl drain               move spooled hook events into the queue
      vdctl events [status]     list events (optionally filtered)
      vdctl utterances [status] list utterances
      vdctl reconcile           run the boot reconciliation sweep
      vdctl reap [hours]        delete audio for confirmed/discarded rows (default 72h)
      vdctl hook-config         print the settings.json snippet to install the hook
      vdctl paths               show where everything lives

    dispatch:
      vdctl targets                       live sessions, with tty and enrolment
      vdctl enroll <sessionId>            allow dispatch into a session
      vdctl enroll --cwd <prefix>         allow dispatch into any session under a path
      vdctl enrolment                     show the allowlist
      vdctl send <sessionId> <text...>    dispatch into a real session (enrolled only)
      vdctl send-raw <pid> <tty> <transcript> <text...>
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
        print("pending total   \(try store.pendingCount())")
        print("")
        print("events by status:")
        for s in EventStatus.allCases {
            let n = try store.events(status: s, limit: 10_000).count
            if n > 0 { print("  \(pad(s.rawValue, 16)) \(n)") }
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

    case "drain":
        let r = try drainer.drain()
        print("inserted \(r.inserted)  duplicates \(r.duplicates)  malformed \(r.malformed)")

    case "events":
        let status = args.count > 1 ? EventStatus(rawValue: args[1]) : nil
        let rows = try store.events(status: status, limit: 40)
        if rows.isEmpty { print("(none)"); break }
        print("\(pad("WHEN", 14))  \(pad("KIND", 6))  \(pad("PROJECT", 18))  \(pad("STATUS", 11))  LAST MESSAGE")
        for e in rows {
            print("\(pad(ms(e.createdAtMs), 14))  "
                + "\(pad(String(e.hookEvent.rawValue.prefix(6)), 6))  "
                + "\(pad(truncate(e.projectLabel, 18), 18))  "
                + "\(pad(e.status.rawValue, 11))  "
                + truncate(e.summaryText ?? e.lastAssistantMessage, 60))
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

    case "hook-config":
        let hookPath = FileManager.default.currentDirectoryPath + "/hooks/voice-dispatch-hook.sh"
        print("""
        Add to ~/.claude/settings.json (merge with existing hooks):

        "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "\(hookPath)"}]}],
        "Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "\(hookPath)"}]}]
        """)

    // MARK: dispatch

    case "targets":
        let enrolment = EnrolmentRegistry()
        let live = ClaudeAgentsCLI().sessions()
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

        guard let live = ClaudeAgentsCLI().sessions().first(where: { $0.sessionId == sessionId }) else {
            print("not dispatched: session is not registered in `claude agents --json`.")
            print("  It is either blocked on a dialog or still starting. Injecting now")
            print("  would answer that dialog, so we refuse.")
            exit(2)
        }
        guard EnrolmentRegistry().isEnrolled(sessionId: sessionId, cwd: live.cwd) else {
            print("not dispatched: session is not enrolled. Run:  vdctl enroll \(sessionId)")
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

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write("vdctl: \(error)\n".data(using: .utf8)!)
    exit(1)
}
