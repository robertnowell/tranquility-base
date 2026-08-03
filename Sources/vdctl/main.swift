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
      vdctl collapse            retire every session's stale unread turns
      vdctl reap [hours]        delete audio for confirmed/discarded rows (default 72h)
      vdctl hook-config         print the settings.json snippet to install the hook
      vdctl paths               show where everything lives

    dispatch:
      vdctl targets                       live sessions, with tty and enrolment
      vdctl enroll <sessionId>            allow dispatch into a session
                                      (normally unnecessary — the panel asks once)
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

    case "collapse":
    // One slot per session. Everything older than a session's newest unread turn
    // is retired — this is the same sweep the app runs before each announcement,
    // exposed so a queue that accumulated under the old FIFO rules can be cleaned.
    let pending = try store.events(limit: 1000)
        .filter { EventStatus.pendingAnnouncement.contains($0.status) }
    var newest: [String: Int64] = [:]
    for event in pending {
        newest[event.sessionId] = max(newest[event.sessionId] ?? .min, event.createdAtMs)
    }
    var retired = 0
    for (sessionId, latest) in newest {
        retired += try store.supersedePending(sessionId: sessionId, before: latest)
    }
    print("retired \(retired) stale turn(s); \(newest.count) session(s) still unread")
    for event in try store.events(limit: 1000)
    where EventStatus.pendingAnnouncement.contains(event.status) {
        let text = event.lastAssistantMessage?.prefix(56) ?? "—"
        print("  \(event.projectLabel)  \(text)")
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

    // MARK: summarize

    case "set-key":
        guard args.count > 1, let key = Secrets.Key(rawValue: args[1] + "-api-key")
            ?? Secrets.Key.allCases.first(where: { $0.rawValue.hasPrefix(args[1]) })
        else {
            print("usage: vdctl set-key <anthropic|elevenlabs|assemblyai>")
            exit(1)
        }
        let value: String
        if args.count > 3, args[2] == "--from-env" {
            // Lets a secret broker inject the value (e.g.
            //   claude-secrets run --inject NAME=VD_KEY -- vdctl set-key anthropic --from-env VD_KEY)
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
            print("no observations yet — run `vdctl gate-watch` first")
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
        let chain = RecoveryChain()
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
            print("The audio is untouched; retry with `vdctl retry-failed` once a provider is available.")
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
    FileHandle.standardError.write("vdctl: \(error)\n".data(using: .utf8)!)
    exit(1)
}
