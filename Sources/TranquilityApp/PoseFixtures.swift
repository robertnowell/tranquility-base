import Foundation
import AppKit
import TranquilityCore

/// The pose driver: `pose(_:)` (the fixture switch `--pose <name>`,
/// main.swift, calls in place of the normal launch tail — renders exactly
/// ONE state with representative data and holds it, no timers advancing,
/// so a screenshot harness can photograph each face) and `poseSnapshot()`
/// (the posed panel's own view hierarchy rendered to PNG bytes, needing
/// no Screen Recording grant). Split out of `StatusHUD.swift` 23 Aug
/// (App-lane P4) — see `SelfTestDriver.swift`'s own doc comment for why
/// this is a straight `extension StatusHUD`, not a `TestSurface` rewrite.
extension StatusHUD {

    /// Render exactly ONE state with representative data and hold it — no timers
    /// advancing state, no repaints. `--pose <name>` (main.swift) calls this in
    /// place of the normal launch tail, so a screenshot harness can photograph
    /// each face without racing intake, hotkeys, or the clock.
    ///
    /// Same driving idea as `selfTest()`: every pose goes through the exact show*
    /// entry point production uses, then the state-advancing machinery (meter,
    /// elapsed ticker, countdown, auto-hide) is frozen and the mid-flight facts a
    /// still photograph needs (highlight position, elapsed label, countdown
    /// fraction) are patched on. Data follows the product's own grammar: two-word
    /// callsigns (Callsign.swift), composed 3–6-word topics, ≤19-word spoken
    /// summaries ending in a question.
    func pose(_ name: String) -> Bool {
        let callsign = "promotions copy"
        let spoken = "Promotions copy. Hero image binding is fixed across the "
            + "stack, and every composed variant passes validation. Rerun the "
            + "backfill now?"
        // The depth-1 rationale, in the brief's own composition: "We propose X
        // because Y. The risk is Z." — ~40 words, no callsign prefix (ruled).
        let rationale = "We propose rerunning the hero backfill only for emails "
            + "shipped after the edge-fade fix, because earlier sends composed "
            + "against the old header and would double-fade. The risk is a brand "
            + "whose header changed since; the backfill logs every skipped send "
            + "for review."

        func adopt() {
            adoptTarget(sessionId: "pose", pid: nil, label: callsign,
                        cwd: NSHomeDirectory() + "/Projects/kopi/promotions")
        }
        func announce(project: String,
                      spoken text: String, highlightFraction: Double,
                      placard: String? = nil,
                      cwd: String = NSHomeDirectory() + "/Projects/kopi/promotions") {
            let sanitized = SpokenTextSanitizer().sanitize(text)
            showAnnouncement(spoken: sanitized,
                             sessionId: "pose", pid: 1, project: project, cwd: cwd,
                             placard: placard)
            highlight(upTo: Int(Double(sanitized.text.count) * highlightFraction))
        }
        // A mid-level frozen waveform: speech-shaped, never pinned at full.
        func seedMeter() {
            for i in 0..<80 { meter.push(CGFloat(0.18 + 0.42 * abs(sin(Double(i) / 3.2)))) }
        }

        switch name {
        // The display/speech split, in the case that motivated it: a findings
        // line whose whole content is column names. The voice says "a variable"
        // once; the card must show all four, and the highlight must be sitting
        // at the END of the name whose stand-in is mid-utterance — not part-way
        // through it, and not still behind it. Verbatim prose before the names
        // is character-identical in both forms, so the cursor there is exact.
        case "redacted":
            let findings = SpokenTextSanitizer().sanitize(  // house-copy:exempt — a fixture, fed to the sanitizer
                "Transcription succeeded; dispatch was queued behind the running "
                + "turn and never landed. The utterances table already carries "
                + "audioPath, audioBytes, transcriptText and dispatchAttempts "
                + "— no migration needed.")
            _ = showAnnouncement(
                spoken: findings,
                sessionId: "pose", pid: 1, project: callsign,
                cwd: NSHomeDirectory() + "/Projects/tranquility-base",
                placard: "\(StateLegend.Glyph.speaking) "
                    + SpokenComposition.RungKind.findings.rawValue)
            // Three characters into the spoken stand-in — far enough that the
            // name it replaces must be fully lit.
            let stand = findings.text.range(of: "a variable")
            let cursor = stand.map { findings.text.distance(from: findings.text.startIndex,
                                                            to: $0.lowerBound) + 3 }
            highlight(upTo: cursor ?? findings.text.count / 2)

        // The other half of the split: a brief long enough that the clamp drops
        // its tail. Held at the END of the spoken text, so everything the voice
        // said is lit and everything it will never say is not — the open
        // question being whether "never spoken" and "not yet spoken" should
        // really look the same.
        case "redacted-long":
            let long = SpokenTextSanitizer().sanitize(
                "Transcription succeeded; dispatch was queued behind the running "
                + "turn and never landed. The utterances table already carries "
                + "audioPath, audioBytes, transcriptText and dispatchAttempts, so "
                + "no migration is needed for the retry work. The sweep turned up "
                + "six defects: two are ordering bugs in the announce path, three "
                + "are stale rows the reconciliation never retired, and the last "
                + "is a race between the intake timer and the boot sweep that only "
                + "reproduces on a cold start. None of them explain the dropped "
                + "dispatch, which the logs now attribute to the running-turn "
                + "guard rather than to transport. The audio itself was recovered "
                + "intact and replayed cleanly.")
            _ = showAnnouncement(
                spoken: long,
                sessionId: "pose", pid: 1, project: callsign,
                cwd: NSHomeDirectory() + "/Projects/tranquility-base",
                placard: "\(StateLegend.Glyph.speaking) "
                    + SpokenComposition.RungKind.findings.rawValue)
            highlight(upTo: long.text.count)

        case "grid":
            showIdle(rows: [
                .init(id: "s1", name: "Validate hero image binding",
                      aux: "a8323d60", lamp: .ready),
                .init(id: "s2", name: "Render pose driver states",
                      aux: "a8323d60", lamp: .ready),
                .init(id: "s3", name: "Cite featured report in daily thread",
                      aux: "9ca8815c", lamp: .running),
                .init(id: "s4", name: "Green the hybrid retrieval eval",
                      aux: "9ca8815c", lamp: .running),
                .init(id: "s5", name: "Ship Track A provenance fix",
                      aux: "6bfb2087", lamp: .running),
                .init(id: "s6", name: "Stage footer flag migration",
                      aux: "0f2ea0d4", lamp: .running),
                .init(id: "s7", name: "Ship Shopify-only filter",
                      aux: "148bb467", lamp: .running),
                .init(id: "s8", name: "Draft personality prompt criteria",
                      aux: "d882f184", lamp: .running),
            ])

        // The grid with a row lit, because a hover is a face too and it was
        // the one state nobody could photograph. Every other treatment on this
        // panel has been decided by looking at a picture of it; this one was
        // decided twice by argument, which is how it took three passes.
        case "grid-hover":
            _ = pose("grid")
            panel?.contentView?.layoutSubtreeIfNeeded()
            waitingRows.arrangedSubviews
                .compactMap { $0 as? GridRowView }
                .dropFirst(2).first?
                .setHovered(true)

        // The read state, both halves on one stage: two unread rows against
        // two opened ones, same lamp, so the only difference on screen is the
        // one being claimed. Weight-only failed exactly here — it looked like
        // four identical rows — and a pose is the cheapest way to be told so
        // before shipping rather than after.
        case "read-state":
            showIdle(rows: [
                .init(id: "u0", name: "Unread, full ink, solid lamp",
                      aux: "unread", lamp: .ready, read: .unread),
                .init(id: "o0", name: "Opened, resting ink, hollow",
                      aux: "opened", lamp: .ready, read: .opened),
                .init(id: "w0", name: "Working, unread",
                      aux: "working", lamp: .working, read: .unread),
                .init(id: "w1", name: "Working, opened",
                      aux: "working", lamp: .working, read: .opened),
                .init(id: "i0", name: "Idle, alive, asking nothing",
                      aux: "idle", lamp: .running, read: .none),
                .init(id: "d0", name: "Gone, turned off is turned off",
                      aux: "closed", lamp: .unlit, read: .none),
            ])
            return true

        case "read-state-old":
            showIdle(rows: [
                .init(id: "u1", name: "Validate hero image binding",
                      aux: "a8323d60", lamp: .ready, read: .unread),
                .init(id: "u2", name: "Render pose driver states",
                      aux: "9ca8815c", lamp: .ready, read: .unread),
                .init(id: "o1", name: "Ship Track A provenance fix",
                      aux: "6bfb2087", lamp: .ready, read: .opened),
                .init(id: "o2", name: "Stage footer flag migration",
                      aux: "0f2ea0d4", lamp: .ready, read: .opened),
            ])

        case "empty":
            showIdle(rows: [])

        // The card + NEW AGENT paints before a session exists to hang it on
        // (`showGreeting`'s own doc comment), now carrying the "Starting
        // agent..." pill (26 Aug) so this state stops looking identical to a
        // bound, ready agent's card. Held still here the same way "waiting"
        // holds the shimmer still: normally five to nine seconds, otherwise
        // unobservable long enough to actually look at.
        case "greeting":
            _ = showGreeting(line: "What would you like to work on?", label: "Projects")

        case "preparing":
            _ = showPreparing()

        case "speaking":
            announce(project: callsign,
                     spoken: spoken, highlightFraction: 0.6)

        // The card up, the audio not here yet — the state the shimmer exists
        // for, held still so it can actually be looked at. It is otherwise
        // almost unobservable by design: the clip is normally prefetched, so
        // playback starts before the 400ms arm and no frame is ever drawn.
        case "waiting":
            announce(project: callsign,
                     spoken: spoken, highlightFraction: 0)

        case "depth1":
            // Exactly the ⌃⌃ path: the same announcement card, the rationale as
            // the spoken text, karaoke highlight and all — with the rung-naming
            // pill main.swift sends ("◀ WHY", the ladder's own convention).
            announce(project: callsign,
                     spoken: rationale, highlightFraction: 0.4,
                     placard: "\(StateLegend.Glyph.speaking) "
                        + SpokenComposition.RungKind.why.rawValue)

        case "arming":
            // Instant-arm: the grayed listening pill, meter flat by design —
            // nothing seeds it; the resting floor IS the arming look.
            adopt()
            showArming(target: callsign)

        case "listening":
            adopt()
            showListening(level: { 0.35 })
            seedMeter()

        case "transcribing":
            adopt()
            showTranscribing("Transcribing your reply…", onCancel: {}, onRetry: {})
            stateLabel.stringValue = StateLegend.row(for: .workingFor(seconds: 3)).stateText

        case "transcribing-slow":
            adopt()
            showTranscribing("Transcribing your reply…", onCancel: {}, onRetry: {})
            stateLabel.stringValue = StateLegend.row(for: .workingFor(seconds: 25)).stateText
            cancelTranscriptionButton.isHidden = false
            retryTranscriptionButton.isHidden = false
            updateActionRowVisibility()
            note(StateLegend.slowTranscriptionNote)

        case "receipt-card":
            // The receipt over a CARD, not the grid — the state a real send
            // actually resolves under when ⌃⌃ or an announcement is on stage.
            _ = pose("speaking")
            panel?.orderFrontRegardless()
            showReceipt(.sent)
            receiptFade?.cancel(); receiptFade = nil
            return true

        case "receipt-sent", "receipt-sending":
            // The send receipt over the grid it lands on — the ordinary case,
            // since a send resolves after the panel has returned home. The
            // panel is ordered front first because showReceipt refuses a
            // hidden panel (a send is not a summons).
            _ = pose("grid")
            panel?.orderFrontRegardless()
            showReceipt(name == "receipt-sent" ? .sent : .sending("home summarizer"))
            // Pin it for the photograph, the same way the readback pose
            // freezes its countdown: a pose is a still, and an outcome that
            // fades on its own timer cannot be photographed reliably.
            receiptFade?.cancel()
            receiptFade = nil
            return true

        case "readback":
            adopt()
            showPendingSend(
                text: "Ship the Shopify-only filter and rerun the poller",
                label: callsign, seconds: 8, send: {}, cancel: { _ in })
            // Frozen mid-window: 40% elapsed. The freeze below kills the timer;
            // this pins the bar's fill so the photograph shows a real mid-state.
            panel?.contentView?.layoutSubtreeIfNeeded()
            countdownBar.freeze(fraction: 0.4)

        case "recent-audio":
            showRecentAudio(events: [
                .init(id: "e1", timeLabel: "Aug 13 07:05", durationLabel: "39s",
                      transcript: "I'm not sure I fully understand, but please recommend "
                          + "what the specific course of action should be.",
                      playing: true),
                .init(id: "e2", timeLabel: "Aug 12 20:52", durationLabel: "27m14s",
                      transcript: nil),
                .init(id: "e3", timeLabel: "Aug 12 14:26", durationLabel: "2s",
                      transcript: "Okay, proceed."),
                .init(id: "e4", timeLabel: "Aug 12 14:09", durationLabel: "1m36s",
                      transcript: "So, something else that I basically want to see is, "
                          + "for Mirai, for every major decision.", retrying: true),
            ], note: "Captures over a second, newest first.")

        case "needsyou":
            adopt()
            showResult("promotions copy's tab is gone, copied your words to the clipboard.")

        case "no-audio":
            // The third tier. No adopted target on purpose: the fault is the
            // machine's, so no agent's name goes at the top of it. The device is
            // the one this machine would actually bind — a pose photographs the
            // real condition, the same way the grid poses real callsigns.
            showDeviceFault(StateLegend.noAudioMessage(device: AudioInputDevice.resolve()))

        case "notice":
            // What the silence gate looks like now (ruled 08 Aug): the grid you
            // were already on, one amber line in the strip where AGENTS sits,
            // and no card at all. Pinned — the notice's own clock would clear it
            // out from under the photograph.
            _ = pose("grid")
            flashNotice(StateLegend.noWordsNotice)
            noticeExpiry?.cancel()
            noticeExpiry = nil
            return true

        case "collapsed":
            setCollapsed(true)
            showIdle(rows: [
                .init(id: "a", name: "promotions copy", aux: "a8323d60", lamp: .ready),
                .init(id: "b", name: "tranquility base", aux: "6bfb2087", lamp: .working),
                .init(id: "c", name: "bookmarks", aux: "bookmarks", lamp: .fault),
            ])
            return true

        case "receipt":
            // The dictation receipt (ui-pass-7, ruling 5). No adopted target:
            // dictation is exactly the path with no agent, so the Delivered
            // pill and the body carry the whole story.
            showDictationReceipt("Copied to clipboard: \u{201C}Ship the "
                + "Shopify-only filter and rerun the poller\u{201D}")

        case "settings":
            // Representative of what the pane actually holds now: paid and free
            // interleaved, size rather than tier in the right column, and a voice that
            // is NOT installed. The old pose was four ElevenLabs voices, so it could
            // not have shown any of the faults in the free-voice work — a pose that
            // cannot fail is not evidence.
            showSettings(
                voices: [Voice(id: "a", name: "Archer", category: "professional"),
                         Voice(id: "sys1", name: "Ava (Premium)", category: "479 MB"),
                         Voice(id: "sys2", name: "Alex", category: "885 MB"),
                         Voice(id: "b", name: "My Clone", category: "cloned"),
                         Voice(id: "sys3", name: "Allison (Enhanced)", category: "99 MB"),
                         Voice(id: SystemVoiceCatalog.downloadPrefix + "Susan",
                               name: "Susan", category: "132 MB")],
                roster: ["sys1", "a"],
                note: "Pick one to hear it.")

        case "agents-settings":
            // The default-launcher work (25 Aug): the harness picker above
            // LAUNCH/DIRECTORY, showing whichever is default with its ★.
            showAgentSettings()

        default:
            return false
        }

        // Freeze: a pose is a photograph, not a running instrument. Everything
        // that would advance the picture dies here; the pixels it already
        // painted stay. (The countdown's own pixels were re-set above.)
        meterTimer?.invalidate(); meterTimer = nil
        transcribingTimer?.invalidate(); transcribingTimer = nil
        countdownTimer?.invalidate(); countdownTimer = nil

        // The capture harness reads this one line: the panel frame in AppKit's
        // bottom-left origin, the full screen frame to convert with, and the
        // window number (the CGWindowID `screencapture -l` takes — window-id
        // capture is immune to overlays that pollute a region capture).
        Permissions.log("pose: \(name) frame=\(panel?.frame ?? .zero) "
                        + "screenFrame=\(NSScreen.main?.frame ?? .zero) "
                        + "window=\(panel?.windowNumber ?? -1)")
        return true
    }

    /// The posed panel, rendered from its own view hierarchy — the capture
    /// path that needs no Screen Recording grant and no awake display
    /// (screencapture returned solid black against a sleeping panel lid,
    /// 13 Aug, which is how this came to exist). PNG bytes, or nil when no
    /// panel is up.
    func poseSnapshot() -> Data? {
        guard let view = panel?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
