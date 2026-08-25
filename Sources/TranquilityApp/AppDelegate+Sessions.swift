import AppKit
import TranquilityCore

/// AppDelegate's deep-link handling and session lifecycle -- opening a
/// tranquilitybase:// URL, sending a reply, starting/reviving/going to a
/// session -- split out of main.swift (App-lane P7, 24 Aug). Named for
/// what it actually holds, not the old "Deep links" MARK it grew under:
/// that comment undersold it by the time this pass found it, sitting
/// alongside `sendReply`, `newSession`, `goToSession`, `revive` and the
/// rest of session management with no MARK of their own.

extension AppDelegate {
    // MARK: - Deep links

    /// tranquilitybase://discuss?session=ID&ref=PATH   open that agent
    /// tranquilitybase://hear?session=ID               speak that session's summary
    /// tranquilitybase://reply?session=ID              open the mic, route the reply there
    /// tranquilitybase://show                          raise the panel
    ///
    /// `discuss` is the one a generated page links to, and it is deliberately
    /// the calmest of the four: it puts you in front of the agent — panel up,
    /// its card, its last summary spoken — and stops there. Opening a
    /// microphone because someone clicked a link in a document would be the app
    /// deciding you had something to say; the card already carries the reply
    /// and the tab for when you do.
    ///
    /// This is what lets a local HTML page carry live buttons: an <a href> to a
    /// custom scheme needs no server and no CORS, and the browser confirms before
    /// launching the app, which is the guard against drive-by pages. A reply link
    /// only ever OPENS the microphone with the panel visibly listening — nothing
    /// records silently, and nothing sends without the usual undo window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // Parsing lives in Core, where it is tested. This layer only acts.
            let parsed = DeepLink.parse(url)
            let action = url.host ?? ""
            let session: String?
            let ref: String?
            switch parsed {
            case let .discuss(s, r): session = s; ref = r
            case let .home(s, r):    session = s; ref = r
            case let .hear(s):       session = s; ref = nil
            case let .reply(s):      session = s; ref = nil
            case .show, .unknown:    session = nil; ref = nil
            }
            Permissions.log("deeplink: \(action) session=\(session?.prefix(8) ?? "-")")
            // A deeplink is an instruction that arrived and is being carried
            // out, so it reads as recognized — the same green a gesture gets.
            hud.acknowledge(.recognized)

            switch action {
            case "discuss":
                discuss(session: session, ref: ref)
            case "hear":
                announceNext(only: session)
            case "reply":
                // A deep link may not record. It is the one rule this surface
                // has that the others do not need: any page in any browser can
                // fire one of these, and a link that opens a live microphone is
                // a page deciding you had something to say. The browser's
                // consent sheet is not consent to be recorded — it is consent
                // to open an app.
                //
                // So this lands you on the agent with the reply ARMED and waits
                // for a gesture you make yourself. One ⌥ tap and you are
                // speaking, which is the same gesture the card has always used;
                // the link's job ends at putting the target in front of you.
                _ = try? coordinator?.intake()
                // The page names its session; that is the whole point of the
                // button. Unknown id → say so, never fall back to a guess about
                // which agent your words belong to.
                guard let session,
                      let target = try? store?.allKnownSessions()
                          .first(where: { $0.sessionId == session }) else {
                    hud.showResult("That page's agent isn't in the log.")
                    break
                }
                guard !recorder.isRecording else { break }
                let live = (ClaudeAgentsCLI().sessions() ?? [])
                    .first(where: { $0.sessionId == session })
                let name = tabDisplayName(for: target, live: live)
                hud.adoptTarget(sessionId: session, pid: live?.pid,
                                label: name, cwd: target.cwd)
                recordingDestination = .session(session)
                activeConversation = (session, name, target.cwd)
                showPanel()
                announceNext(only: session)
                if !micGranted {
                    // Said once, on arrival, rather than discovered at the press.
                    hud.note("The microphone isn't granted: Settings ▸ Privacy ▸ "
                             + "Microphone before you can reply.")
                }
            case "home":
                // The agent's own page. Written after every turn, so it exists
                // for any session that has ever been summarized; for one that
                // has not, there is nothing to show and the invitation is the
                // honest answer.
                if session.map({ openHub(session: $0) }) != true {
                    inviteNewSession(for: ref)
                }
            case "show":
                showPanel()
            default:
                Permissions.log("deeplink: unknown action \(action)")
            }
        }
    }

    /// The one report this turn just wrote, if any: the newest recorded
    /// artifact, on disk, stamped after the PREVIOUS turn's brief — which is
    /// when this turn began. An artifact from an earlier turn is the hub's
    /// job; an artifact re-touched but first recorded long ago keeps its
    /// first stamp and stays with the hub too, deliberately.
    func freshReport(session: String) -> String? {
        guard let store,
              let latest = ArtifactStore.history(
                  for: session, root: QueueStore.supportDirectory.path).last
        else { return nil }
        let briefs = (try? store.briefs(for: session, limit: 2)) ?? []
        let turnBegan = briefs.count > 1
            ? Date(timeIntervalSince1970: Double(briefs[1].atMs) / 1000)
            : .distantPast
        return latest.at > turnBegan ? latest.path : nil
    }

    /// The hub, rewritten fresh and then shown. One code path for both of its
    /// doors — the card's second door and the `home` deep link — so the page
    /// the button opens and the page the link opens cannot drift. Returns
    /// false when the session has no briefs yet, and the caller decides what
    /// an absent hub means (the card hides the door; the deep link invites).
    @discardableResult
    func openHub(session: String) -> Bool {
        guard let store,
              let file = try? HomeBase.write(sessionId: session, store: store)
        else {
            Permissions.log("openHub: no briefs for \(session.prefix(8))")
            return false
        }
        if BrowserFocus.focusExistingTab(file) == .notFound {
            NSWorkspace.shared.open(file)
        }
        return true
    }

    /// "Discuss with agent", from a page that agent wrote.
    ///
    /// Two outcomes and no third: either the agent is here, in which case you
    /// land on it exactly as if you had clicked its row in the grid, or it is
    /// not, in which case you are offered one. The second is not an error path
    /// — it is what EVERY page does eventually, and what every page does
    /// immediately on a machine that is not the one that made it.
    func discuss(session: String?, ref: String?) {
        // Sweep first, for the same reason `reply` now does: a page can be
        // clicked before its own session has been filed.
        _ = try? coordinator?.intake()
        let known = session.flatMap { id in try? store?.latestStop(for: id) } ?? nil
        guard let session, known != nil else {
            Permissions.log("deeplink: discuss, no agent for \(session?.prefix(8) ?? "-")")
            inviteNewSession(for: ref)
            return
        }
        // The grid row's own move: raise the panel, then read that session's
        // last summary onto the stage. `announceNext(only:)` is deliberately
        // outside the unheard filter, so this answers however many times you
        // click it.
        showPanel()
        announceNext(only: session)
    }

    /// The invitation. Without a `ref` there is nothing to open with and
    /// nothing to say about it, so this stays silent rather than offering a
    /// blank session — the grid's own NEW AGENT row is the door for that.
    func inviteNewSession(for ref: String?) {
        // A page can put any string in a URL; it cannot put a file on your
        // disk. Everything the invitation goes on to build — a directory, a
        // prompt, a shell command — is derived from a path that got past this,
        // which is why the check lives in Core with tests around it.
        guard let subject = DeepLink.subject(
            from: ref, exists: { FileManager.default.fileExists(atPath: $0) })
        else {
            Permissions.log("invitation: refused ref \(ref ?? "-")")
            hud.showResult("That page names an agent this Mac has no record of, "
                           + "and nothing this Mac can open instead.")
            return
        }
        hud.showNewSessionInvitation(
            artifact: subject.name,
            directory: abbreviatingHome(subject.directory),
            ref: subject.reference)
    }

    /// `~` back, for display only: an absolute home path eats the width the
    /// artifact's own name needs, and the grid abbreviates the same way.
    func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The one answer to every way a recording can come back with no words in
    /// it — the silence gate below, and the `nothingRecorded` throw in
    /// `.replyEnded`, which is the same event seen one layer down and used to be
    /// answered completely differently ("Nothing recorded." over the grid, or a
    /// failure card, depending on which threshold you happened to trip).
    ///
    /// Three tiers, and the axis is how long the microphone was OPEN — never how
    /// much audio came back. `Recorder.lastOpenSeconds` says why: a dead device
    /// reports a zero-length recording however long you held the key, so buffer
    /// length cannot tell a slip of the thumb from broken hardware.
    ///
    ///   under 2s           nothing at all. You tapped the key or changed your
    ///                      mind. You did not make an error, and a screen that
    ///                      appears for a slip teaches you to fear the key.
    ///   2s+, some signal   one amber line in the grid's strip, on its own
    ///                      clock. You meant to speak, the room was quiet, and
    ///                      saying it again fixes it — so nothing to dismiss.
    ///   5s+, NO signal     a card. The one tier saying it again will not fix:
    ///                      the input is dead, the fix is a setting, so it holds
    ///                      the stage and offers the door out.
    func reportNothingHeard(because reason: String) {
        let held = recorder.lastOpenSeconds
        let signal = recorder.peakLevel > 0
        Permissions.log(String(format: "nothing heard (%@): held %.2fs, peak %.4f",
                               reason, held, recorder.peakLevel))
        // Home first, through the user door: the capture state owns the stage,
        // so a plain idle repaint is (correctly) refused from it.
        hud.endCapture(because: reason)
        if held >= Self.deviceFaultHold, !signal {
            let device = AudioInputDevice.resolve()
            lastStatusLine = "\(StateLegend.Glyph.needsYou) no audio from "
                + (device?.name ?? "the input device")
            hud.showDeviceFault(StateLegend.noAudioMessage(device: device))
        } else {
            lastStatusLine = "nothing heard"
            showIdleGrid()
            if held >= Self.notionalUtterance {
                hud.flashNotice(StateLegend.noWordsNotice)
            }
        }
        rebuildMenu()
    }

    /// Hold: transcribe and route the reply back to whichever session last
    /// spoke.
    ///
    /// `isRetry` marks a re-run of a capture the panel's Retry superseded: the
    /// silence gate is skipped (these bytes already passed it once, and the
    /// recorder's peak may belong to a later arm by now) and the face says
    /// "Retrying" — re-entering `.transcribing` restarts the elapsed clock,
    /// which is the visible acknowledgment the first Retry never had.
    func sendReply(_ capture: Recorder.Capture, isRetry: Bool = false) {
        guard let coordinator else { return }
        // Unpacked once, at the top, from the value stop() returned. Both of
        // these used to be read separately — the samples from the return, the
        // file from mutable state on the recorder — which is how a later capture
        // could have replaced one without the other.
        let pcm = capture.pcm16
        let capturedFile = capture.fileURL
        // This utterance's live stream, if one opened. finish() is nil on any
        // stream trouble, and the file path below recovers exactly as before.
        let liveStream = recorder.takeStream()
        // Silence gate. Whisper transcribes near-empty audio into training-data
        // boilerplate — a 765ms accidental capture became "MBC 뉴스 이덕영입니다."
        // and was SENT. A recording that is too short or never rose above the
        // noise floor is refused before any model touches it: hallucinated words
        // in a real terminal are worse than asking you to speak again.
        let seconds = Double(pcm.count) / 2.0 / 16_000.0
        if !isRetry, seconds < 0.5 || recorder.peakLevel < 0.005 {
            Permissions.log(String(format:
                "send: refused, silence gate (%.2fs, peak %.4f)", seconds, recorder.peakLevel))
            recordingDestination = nil
            reportNothingHeard(because: "silence gate")
            return
        }
        let mine = replyGeneration
        // Pre-minted so the attempt's row is addressable BEFORE the attempt
        // resolves — the panel's Retry retires it by this id (issue: the two
        // 19 Aug retry taps that could not reach the capture on screen).
        let attemptId = UUID().uuidString
        inFlightTranscription = InFlightTranscription(
            capture: capture, utteranceId: attemptId,
            destination: recordingDestination, task: nil)
        lastStatusLine = "transcribing…"
        // Sanctioned change (open issue #4): the transcribing panel shows elapsed
        // seconds, and past 20s offers Cancel and Retry rather than looking hung.
        hud.showTranscribing(isRetry ? "Retrying transcription…" : "Transcribing your reply…",
                             onCancel: { [weak self] in self?.cancelTranscription() },
                             onRetry: { [weak self] in self?.retryTranscriptionFromPanel() })
        rebuildMenu()

        let attempt = Task { @MainActor in
            // The attempt clears its own tracking on the way out — unless a
            // retry already replaced it with a newer attempt's record.
            defer {
                if self.inFlightTranscription?.utteranceId == attemptId {
                    self.inFlightTranscription = nil
                }
            }
            do {
                // Address exactly what the panel showed while you spoke — captured
                // at mic-open, consumed here. Re-deriving at send time is how the
                // HTML button's reply reached the wrong session, so a recording
                // with no captured address REFUSES rather than falling back to a
                // derivation: the audio is kept, and nothing is guessed.
                if case .dictation = recordingDestination {
                    // Dictation: transcribe, copy, done. No terminal is touched.
                    recordingDestination = nil
                    hud.showTranscribing(isRetry ? "Retrying transcription…" : "Transcribing…",
                                         onCancel: { [weak self] in self?.cancelTranscription() },
                                         onRetry: { [weak self] in self?.retryTranscriptionFromPanel() })
                    guard let store = self.store else { return }
                    let streamed = await liveStream?.finish()
                    let utterance = try await store.captureAndTranscribe(
                        pcm16: pcm, sampleRate: 16_000, chain: RecoveryChain(), eventId: nil,
                        streamed: streamed, preWritten: capturedFile, utteranceId: attemptId)
                    // Cancelled (or replaced) while transcribing: the words must not
                    // be pasted anywhere. The audio row is durable and stays.
                    guard mine == replyGeneration else {
                        Permissions.log("dictation: superseded or cancelled mid-transcription; dropped")
                        return
                    }
                    guard let text = utterance.transcriptText, !text.isEmpty else {
                        hud.showResult("Couldn't transcribe that. Audio kept.")
                        return
                    }
                    // Wispr's rule: a focused text field wins; clipboard otherwise.
                    // Dictation success shows its RECEIPT (ui-pass-7, ruling 5
                    // — re-ruled from the blanket Sent-face deletion): the card
                    // tells you where the words went, which nothing else does.
                    // Reply-send success stays silent as ruled. The receipt
                    // dwells, then the grid returns on ruling 14's clock.
                    if let app = FocusedInput.focusedEditableApp() {
                        FocusedInput.paste(text)
                        Permissions.log("dictation: typed \(text.count) chars into \(app)")
                        lastStatusLine = "typed into \(app)"
                        hud.showDictationReceipt("Typed into \(app).")
                    } else {
                        if !FocusedInput.trusted { FocusedInput.requestTrustOnce() }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        Permissions.log("dictation: copied \(text.count) chars to clipboard")
                        lastStatusLine = "copied to clipboard"
                        hud.showDictationReceipt(
                            "Copied to clipboard: \u{201C}\(text.prefix(80))\u{201D}")
                    }
                    scheduleReturnToGrid()
                    rebuildMenu()
                    return
                }
                // The words wait for the agent they were spoken to.
                //
                // A capture that began on a greeting card carries the LAUNCH,
                // not a session id, because there was no session when you
                // started talking. By the time a reply has been spoken and
                // transcribed the agent has almost always registered — five to
                // nine seconds, against a reply that takes at least as long —
                // so this usually returns instantly. When it does not, waiting
                // is still the right answer: the alternative that shipped was
                // typing your words into the previous agent without saying so.
                let spokenTo: String
                switch recordingDestination {
                case .session(let id):
                    spokenTo = id
                case .launch(let launch):
                    lastStatusLine = "waiting for \(launch.label) to come up…"
                    rebuildMenu()
                    let arrived = await launch.session(timeout: 30)
                    let waited = Int(Date().timeIntervalSince(launch.startedAt))
                    Permissions.log("launch: reply waited \(waited)s for \(launch.label) — "
                        + (arrived.map { "went to \($0.prefix(8))" } ?? "never came up"))
                    guard let arrived else {
                        // The agent is genuinely absent — the one failure this
                        // path exists for. The words go where you can still get
                        // at them rather than into somebody else's tab.
                        recordingDestination = nil
                        Permissions.log("send: \(launch.label) never registered; nothing sent")
                        hud.showResult("\(launch.label) never came up, nothing was sent. "
                                       + "Your words are kept; check Terminal for a prompt.")
                        rebuildMenu()
                        return
                    }
                    spokenTo = arrived
                case .dictation, .none:
                    // `.dictation` was handled above and cannot reach here;
                    // `.none` is a capture that lost its address, which refuses
                    // rather than falling back to a derivation.
                    Permissions.log("send: recording has no captured address; refusing")
                    hud.showResult("This recording lost its address. Audio kept; nothing sent.")
                    rebuildMenu()
                    return
                }
                recordingDestination = nil
                // The delivery window opens HERE — at the capture's close, not
                // at the dispatch — because this is the moment the words become
                // ours to deliver, and every second from here to the outcome is
                // a second the grid used to call that session idle.
                // Which turn this answers, read at the capture's close rather
                // than at dispatch: the whole point is to be right about the
                // row DURING the wait, and a turn that lands while the user is
                // still talking must not be swallowed by their reply to the
                // previous one.
                let answering = (try? coordinator.waiting())?
                    .first { $0.sessionId == spokenTo }?.latestId
                delivering.began(sessionId: spokenTo, answering: answering)
                // One clear-site, not eight. Every exit below closes the window
                // — the supersede return, the six terminal outcomes, the catch —
                // except `.readyToSend`, which hands the delivery to the undo
                // countdown and `send()` to finish. Enumerating exits is how a
                // lamp gets stuck on; a defer keyed to the single hand-off
                // cannot miss one.
                var handedToCountdown = false
                defer { if !handedToCountdown { delivering.finished(sessionId: spokenTo) } }
                let streamed = await liveStream?.finish()
                let outcome = try await coordinator.submitReply(
                    pcm16: pcm, to: spokenTo, streamed: streamed,
                    preWritten: capturedFile, utteranceId: attemptId)

                // You started saying it again while this was still transcribing.
                // Drop it rather than offering it: the words you replaced must never
                // reach the session, and they must not queue up behind the new ones.
                if mine != replyGeneration {
                    if case .readyToSend(let staleId, _, _, _) = outcome {
                        try? coordinator.cancelSend(utteranceId: staleId)
                    }
                    lastStatusLine = "replaced by a newer reply"
                    rebuildMenu()
                    return
                }

                switch outcome {
                // Success says nothing on the panel (ruled — the Sent face is
                // dead): status line + log, straight back to the grid.
                case .dispatched(let text, let ms, let dispatchedSessionId, let dispatchedPid):
                    lastStatusLine = "\(StateLegend.Glyph.sent) sent (\(ms)ms): \(text.prefix(48))"
                    if let dispatchedPid {
                        hud.attachLivePid(dispatchedPid, sessionId: dispatchedSessionId)
                    }
                    hud.endCapture(because: "sent")
                    showIdleGrid()
                case .queued(let text, let dispatchedSessionId, let dispatchedPid):
                    lastStatusLine = "\(StateLegend.Glyph.sent) queued: \(text.prefix(48))"
                    if let dispatchedPid {
                        hud.attachLivePid(dispatchedPid, sessionId: dispatchedSessionId)
                    }
                    hud.endCapture(because: "queued")
                    showIdleGrid()
                case .noTarget:
                    lastStatusLine = "nothing to reply to yet"
                    hud.showResult("Nothing to reply to yet. Tap ⌃⌥ to hear one first.")
                case .readyToSend(let utteranceId, let text, let coreLabel, let sessionId):
                    // One identity: Core's outcome still carries the project
                    // label; the visual "Sending to X" upgrades it to the minted
                    // callsign when one exists.
                    let label = (try? store?.callsign(for: sessionId)).flatMap { $0 } ?? coreLabel
                    // Sending is the default. The window exists to stop it, not to
                    // permit it: approving every correct transcript is a toll.
                    lastStatusLine = "sending to \(label)…"
                    // The countdown and the send own the window from here.
                    handedToCountdown = true
                    hud.showPendingSend(
                        text: text, label: label, seconds: 4,
                        send: { [weak self] in
                            self?.send(utteranceId: utteranceId, label: label,
                                       sessionId: sessionId)
                        },
                        cancel: { [weak self] restartListening in
                            guard let self else { return }
                            // The recording is kept, just taken out of the sendable
                            // set — you rejected these words, not the audio.
                            try? self.coordinator?.cancelSend(utteranceId: utteranceId)
                            // Nothing is on its way any more: the lamp goes back
                            // to whatever the transcript honestly says.
                            self.delivering.finished(sessionId: sessionId)
                            guard restartListening else { return }
                            // Straight back to listening: you stopped it because the
                            // words were wrong, so the next thing you want is to say
                            // them again, not to hunt for a button.
                            self.hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 })
                            if self.micGranted, !self.recorder.isRecording {
                                try? self.recorder.start()
                                self.isBusy = true
                                self.updateTitle()
                            }
                        })
                case .sessionNotReady(let readiness):
                    // Sanctioned change (b): plain words for the actual condition.
                    let why = StateLegend.plainWords(for: readiness)
                    lastStatusLine = "can't send, \(why); audio kept"
                    hud.showResult("Can't send yet, \(why). Recording kept. Try again shortly.")
                case .transcriptionFailed:
                    lastStatusLine = "couldn't transcribe, audio kept"
                    hud.showResult("Couldn't transcribe that. The audio is saved. Retry from the menu.")
                case .dispatchFailed(.verificationTimedOut, _):
                    lastStatusLine = "\(StateLegend.Glyph.needsYou) unconfirmed. Check the tab before resending"
                    hud.showResult(
                        "Sent, but never confirmed. It may or may not have landed. "
                        + "check the tab before resending.")
                case .dispatchFailed(.tabNotFound, let utteranceId),
                     .dispatchFailed(.targetGone, let utteranceId):
                    // This path painted nothing at all before — a silently lost
                    // reply. Same rescue as the confirm path: clipboard + card.
                    let copied = copyTranscriptToClipboard(utteranceId: utteranceId)
                    lastStatusLine = copied ? "tab gone, words on the clipboard"
                                            : "tab gone, words kept in the log"
                    hud.showResult(StateLegend.tabGoneRescueMessage(label: nil, copied: copied))
                case .dispatchFailed(let failure, _):
                    lastStatusLine = "send failed: \(failure), audio kept"
                }
            } catch {
                lastStatusLine = "reply failed: \(error)"
            }
            rebuildMenu()
        }
        inFlightTranscription?.task = attempt
    }

    /// A reply that cannot be delivered goes to the clipboard — the one place the
    /// user can immediately use it. Deliberately NOT FocusedInput.paste (which
    /// restores the previous clipboard after 0.7s); this is a handoff, not a paste.
    /// What a failure card says about the words the user just spoke — after
    /// putting them somewhere the user can actually use them.
    ///
    /// "Your words are kept" was true and useless: kept in a log the reader
    /// has no path to from a card. The clipboard is the one place "kept"
    /// means "one paste away", and it costs a pasteboard write on a path
    /// that has already failed.
    func wordsKept(utteranceId: String) -> String {
        copyTranscriptToClipboard(utteranceId: utteranceId)
            ? "Copied your words to the clipboard."
            : "Your words are kept in the log."
    }

    func copyTranscriptToClipboard(utteranceId: String) -> Bool {
        guard let text = (try? store?.utterances(limit: 500))?
                .first(where: { $0.id == utteranceId })?.transcriptText,
              !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Permissions.log("dispatch rescue: copied \(text.count) chars to clipboard")
        return true
    }

    /// Say what to do, not just that something broke.
    ///
    /// "Try again" is false comfort when the input is Bluetooth: those devices
    /// re-rate themselves the moment the mic opens, so the next press fails
    /// identically, and what the user learns is that the app is unreliable rather
    /// than that the earbuds are. Name the device, name the fix.
    func micFailureMessage(_ error: Error) -> String {
        // Only advise the built-in mic if capture has not already tried it. Once
        // the open loop has retreated there and STILL failed, telling the user to
        // switch to the device that just failed is worse than no advice.
        if recorder.fellBackToBuiltIn {
            return "Couldn't open the built-in microphone either, try again. (\(error))"
        }
        if let device = AudioInputDevice.resolve(), device.isBluetooth {
            return "Couldn't open \(device.name). Bluetooth mics change their own "
                + "sample rate when they open, switch to the built-in mic under "
                + "Microphone in the menu bar."
        }
        return "Couldn't open the microphone, try again. (\(error))"
    }

    @objc func chooseInput(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preference = AudioInputPreference(rawValue: raw) else { return }
        AudioInputPreference.current = preference
        let resolved = AudioInputDevice.resolve(preference)
        lastStatusLine = "mic: \(resolved?.name ?? preference.title)"
        Permissions.log("mic: preference \(preference.rawValue) "
            + "→ \(resolved?.name ?? "engine default")")
        // Rebuild now rather than on the next press, for the same reason launch
        // does: a preference change means a new device, and a gesture is the
        // one place that cannot absorb the unit rebuild. Still the single code
        // path — warmUp prepares the unit and remains the only thing that
        // decides which device is live (and it retires any built-in retreat).
        recorder.warmUp()
        rebuildMenu()
    }

    @objc func chooseVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Two catalogues, two settings. Writing a macOS identifier into
        // `selectedVoiceId` would store it where only ElevenLabs reads, so the pick
        // would appear to take and change nothing audible — the same class of silent
        // no-op as the preview that played one voice for every row.
        if SystemVoiceCatalog.isSystemVoice(id) {
            SystemVoiceCatalog.choose(id)
            // No rebuild needed: SystemSpeechProvider resolves the preference per
            // utterance, so the next announcement uses it.
        } else {
            VoiceCatalog.selectedVoiceId = id
        }
        lastStatusLine = "voice: \(sender.title)"
        rebuildMenu()

        // Hear it now. Choosing from a list of names is guesswork otherwise.
        Task { @MainActor in
            hud.showWorking("Voice set to \(sender.title).")
            self.coordinator?.speech.stop()
            guard let chain = self.coordinator?.speech else { return }
            _ = await chain.speak(SpokenTextSanitizer().sanitize(self.previewText()))
            showIdleGrid()
        }
    }

    /// A turn came back. Decide whether to raise the panel for it.
    ///
    /// Silently, always: showing up IS the signal, and a voice starting on its own
    /// while you are mid-sentence in another session is what gets an app deleted.
    ///
    /// The gate is consulted here for the first time. Until now it only ever vetoed
    /// a keypress, which is backwards — you cannot interrupt someone who just asked
    /// for something. Interrupting is exactly what this does, so this is where a
    /// veto belongs.
    func surfaceArrival(rows: [SessionRow], waiting: Int,
                                newlyWaiting: Bool) {
        let decision = gate.evaluate()
        guard decision.allowed else {
            // Held, not dropped. The count is still right the moment the panel is
            // next shown, and nothing was lost by staying quiet.
            Permissions.log("ambient: held (\(decision.reason))")
            gateLog.record(decision, context: "arrival")
            // A hail held because the device is busy looks exactly like an agent
            // that never came back, so this one refusal explains itself. Every
            // other veto stays in the log: a locked screen needs no note, and
            // nobody is reading the panel anyway. `flashNotice` paints only in
            // `.idle`, so a dismissed panel is not raised by this — which is the
            // ruling, and is structural rather than remembered.
            return
        }
        // The hail path. Without the overlay the frontmost-tab check below is
        // run against the session you just answered rather than the one that
        // actually arrived — the same defect as ⌃⌥, wearing a different symptom.
        let target = try? coordinator?.nextToAnnounce(excluding: delivering)
        // The frontmost-tab skip needs three subprocesses (osascript, the
        // claude CLI, ps), and it used to run them ON MAIN, synchronously —
        // issue 14's smaller resident: with Terminal frontmost AND busy, one
        // Apple event here could hold the app for minutes, on every arrival.
        // Terminal-not-frontmost is the common case and stays fully
        // synchronous: no probe, no reordering, identical behavior.
        let terminalIsFront = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier == "com.apple.Terminal"
        guard terminalIsFront, let target else {
            finishArrival(rows: rows, waiting: waiting, newlyWaiting: newlyWaiting)
            return
        }
        // Terminal IS frontmost: probe off-main, newest arrival wins. A newer
        // call bumps the generation, so a stale probe returns to find its
        // moment gone and stays silent — the newer one carries the chime.
        arrivalProbeGeneration += 1
        let generation = arrivalProbeGeneration
        pendingArrival = (rows, waiting, newlyWaiting)
        let sessionId = target.sessionId
        Task.detached(priority: .userInitiated) { [weak self] in
            let front = await Self.frontmostTerminalTabTty()
            let pid = front == nil ? nil : (ClaudeAgentsCLI().sessions() ?? [])
                .first(where: { $0.sessionId == sessionId })?.pid
            let onScreen = pid.flatMap { ProcessProbe.tty(of: $0) }
            let skip = front != nil && onScreen == front
            await MainActor.run { [weak self] in
                guard let self, generation == self.arrivalProbeGeneration,
                      let pending = self.pendingArrival else { return }
                self.pendingArrival = nil
                if skip {
                    // You are looking straight at the tab that just finished.
                    // Announcing it is telling you something you can already
                    // see — no panel, no hail: showing up is enough, and here
                    // you are already there.
                    Permissions.log("ambient: skipped, that session is the frontmost tab")
                    return
                }
                self.finishArrival(rows: pending.rows, waiting: pending.waiting,
                                   newlyWaiting: pending.newlyWaiting)
            }
        }
    }

    /// The away-channel tail of an arrival, after the gates have spoken.
    func finishArrival(rows: [SessionRow], waiting: Int,
                               newlyWaiting: Bool) {
        // RULING 1: an arrival changes what the panel SAYS, never whether it is
        // on screen or how wide it is. A panel you put away stays away.
        //
        // The count in the menu bar is what carries the news to a dismissed
        // panel — refreshed every tick and unable to go stale (WS-B,
        // `menuBarCount`) — plus the chime below, which is the away-channel and
        // does not need a window. Nothing is lost by not summoning one.
        //
        // This is the last unimplemented half of
        // docs/ruling-an-arrival-does-not-move-the-panel.md: `showIdle` raises
        // the panel, and `allowsAmbientSurface` is true for `.hidden`, so every
        // arriving turn re-opened a panel the user had dismissed.
        guard hud.isOnScreen else {
            Permissions.log("ambient: \(waiting) waiting, panel stays dismissed")
            if newlyWaiting { Earcons.play(.returned, gate: earconGate()) }
            return
        }
        Permissions.log("ambient: surfaced for \(waiting) waiting")
        hud.showIdle(rows: rows)
        // The arrival makes a SOUND, not a sentence.
        //
        // The spoken callsign is dead (ruled 10 Aug). It was the most expensive
        // thing in the app — it needed the interrupt gate, then a courtesy check,
        // then a microphone and a recogniser to decide whether saying one word
        // was rude — and in the whole time it shipped it never once announced
        // successfully. A chime carries the same information ("something came
        // back") at none of that cost, and the panel already carries WHICH.
        // Sound only on a session JOINING the waiting set — see `lastWaitingIds`.
        // The panel repaint above is unconditional and stays that way: currency is
        // not attention, and a lamp on screen must be true even when nothing
        // announces itself.
        if newlyWaiting {
            Earcons.play(.returned, gate: earconGate())
        } else {
            Permissions.log("earcon: no returned — \(waiting) waiting, none of them new")
        }
    }


    /// The tty of Terminal's selected tab. One Apple event, bounded: against a
    /// busy Terminal an unbounded event blocks its thread for up to the
    /// two-minute default timeout, so the deadline is what keeps this callable
    /// at all. Callers check who is frontmost first — that part is free.
    nonisolated private static func frontmostTerminalTabTty() async -> String? {
        let script = "tell application \"Terminal\" to return tty of selected tab of front window"
        guard case .success(let out) = await AppleScript.run(script: script, timeout: 2)
        else { return nil }
        let tty = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty ? nil : tty
    }

    /// The most recent thing it actually said, so a voice is judged on real work.
    func previewText() -> String {
        let recent = (try? store?.events(limit: 200))?
            .compactMap { $0.summaryText }
            .first(where: { !$0.isEmpty })
        return recent ?? "No sessions have finished yet, so this is what I sound like "
            + "reading nothing in particular."
    }

    func openSettings(tab: SettingsTab = .voices) {
        // Paid voices first, then the free ones the machine already has. Without the
        // second half this pane read "15 of 0 on roster" whenever no ElevenLabs key
        // was configured — an empty list on a Mac with forty voices installed, and no
        // hint that free ones exist at all.
        // Installed voices, then the good ones that are a download away. A picker
        // that shows only what you have cannot tell you what you are missing, and
        // what you are missing is the best of them.
        let paid = VoiceCatalog.cached()
        // The cached snapshot, same as the menu tick. The 1.5 s tick keeps it
        // no staler than ~15 s, and a sync read here is the same TTS-daemon
        // semaphore that froze the tick (issue 14) — a pane open must not
        // gamble on the daemon's mood either.
        let rows = SystemVoiceCatalog.cachedRows()
        let free = rows.catalogue
        let getMore = rows.downloads

        // One line. This was four sentences of explanation — a wall of prose where a
        // control belonged. The "Free · Get" rows below ARE the instruction now, so
        // the note only has to say what the list is.
        let note = paid.isEmpty
            ? "Free macOS voices. Pick one to hear it."
            : "Checked voices are the cast; agents draw one in roster order."

        hud.showSettings(voices: paid + free + getMore,
                         roster: VoiceRoster.load(), note: note, tab: tab)
    }

    /// The settings state's second pane (ruled 13 Aug): every capture over a
    /// second, newest first, with the transcript it has or the absence it
    /// doesn't, and a per-row manual retry. The log IS the utterances table;
    /// this only projects it.
    func showRecentAudio() {
        hud.showRecentAudio(events: recentAudioEvents(),
                            note: "Captures over a second, newest first.")
    }

    /// A second is the noise floor: shorter rows are key-slips and arm
    /// discards, and a log that lists them buries the recordings a human
    /// might actually want back.
    static let recentAudioFloorMs: Int64 = 1_000
    static let recentAudioRowCap = 12

    func recentAudioEvents(retrying: String? = nil) -> [AudioEventRow] {
        guard let store else { return [] }
        let stamp = DateFormatter()
        stamp.dateFormat = "MMM d HH:mm"
        return ((try? store.utterances(limit: 200)) ?? [])
            .filter { ($0.audioDurationMs ?? 0) >= Self.recentAudioFloorMs }
            .prefix(Self.recentAudioRowCap)
            .map { u in
                let seconds = Int((u.audioDurationMs ?? 0) / 1000)
                let text = u.transcriptText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return AudioEventRow(
                    id: u.id,
                    timeLabel: stamp.string(
                        from: Date(timeIntervalSince1970: Double(u.createdAtMs) / 1000)),
                    durationLabel: seconds >= 60
                        ? "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s"
                        : "\(seconds)s",
                    transcript: (text?.isEmpty ?? true) ? nil : text,
                    playing: u.id == utterancePlayer.playingId,
                    retrying: u.id == retrying)
            }
    }

    @objc func showPanel() {
        showIdleGrid()
    }

    /// Start a fresh Claude session in a new Terminal window (v1 is choiceless:
    /// home directory, `claude --dangerously-skip-permissions`). Its turns
    /// enter the loop — and the grid — as soon as the session first stops.
    func newSession() {
        newSession(directory: SessionLauncher.defaultDirectory,
                   command: SessionLauncher.defaultCommand)
    }

    /// Bring back a session whose process has ended.
    ///
    /// The row already checked that this session is gone and that its directory
    /// exists — but that check is as old as the last grid refresh, and the one
    /// thing that must not happen is resuming a session that came back to life
    /// in between. `claude --resume` on a live session adds a second process
    /// under the same id, and that crashed the app twice. So the guard is taken
    /// AGAIN here, on a fresh probe, at the moment of the act.
    ///
    /// Off-main because it drives Terminal through AppleScript.
    /// The graveyard, built once and handed over whole.
    ///
    /// Every interactive session in the window, live ones included: the job is
    /// "I don't know which tab that workstream is in", and a session you left
    /// running in a tab you have lost is exactly as hard to find as a dead one.
    /// The verb differs — a live row goes to its tab, a dead one comes back —
    /// and the row already knows which it is.
    ///
    /// Off-main because the scan can walk the archive, then applied on the main
    /// actor in one shot.
    func openPastAgents() {
        // The SAME rows the grid is built from, minus the ones it is showing.
        // Not a second query: two queries can disagree, and the disagreement
        // was visible — every live session appeared in both surfaces at once,
        // and appeared here with a quiet lamp whatever it was actually doing.
        // A working agent read as idle, which is the lamp lying.
        let rows = sessionRowsNow()
        let hidden = Array(StatusHUD.pastAgents(rows))
        // The directory is the one thing a row does not carry and the filter
        // wants, so it comes from the scan the rows were built from — already
        // warm, since sessionRowsNow just used it.
        let scanned = SessionDiscovery.discoverIfScanned()?.sessions ?? []
        let cwds = Dictionary(scanned.map { ($0.sessionId, $0.cwd ?? "") },
                              uniquingKeysWith: { first, _ in first })
        // When each agent last MOVED — the conversation's own clock, not the
        // file's. It rides the same scan the rows and the directories came from,
        // so the column, the lamp and the ranking are all reading one number;
        // a second source here is how the list would start disagreeing with the
        // band order it is drawn in.
        let moved = Dictionary(scanned.map { ($0.sessionId, $0.lastActivityAt) },
                               uniquingKeysWith: { first, _ in first })
        let now = Date()
        let items = hidden.map { row -> PastAgentsList.Item in
            // Everything the filter matches, lowercased once: the name you half
            // remember, the id you would have grepped for, and the directory you
            // were working in.
            let haystack = [row.name, row.id, cwds[row.id] ?? ""]
                .joined(separator: " ").lowercased()
            // The column answers "when", because that is the question this face
            // exists for (ruled 19 Aug). A stopped session used to spend the
            // whole column on its stall reason — a 46-character sentence,
            // right-aligned — and the name label yields its width to it, so the
            // three longest-stalled rows on the list rendered with no visible
            // name at all. The reason is not lost; it moves to the tooltip,
            // uncut, next to the id it now shares that space with.
            let when = moved[row.id].map { SessionActivity.lastMovedLabel($0, now: now) }
            let hover = [SessionRow.hoverText(for: row), SessionRow.shortId(row.id)]
                .compactMap { $0 }.joined(separator: "\n")
            // The row's OWN lamp, carried through. A session below the fold is
            // usually quiet, but it is not quiet by definition — on a small
            // screen an agent can be working and still not fit — and the lamp
            // must say which.
            return PastAgentsList.Item(row: row, revivable: row.revivable,
                                       haystack: haystack,
                                       aux: when, tooltip: hover)
        }
        hud.showPastAgents(items: items)

        // The list is on screen and usable before a single transcript is read.
        // What the sessions SAID arrives afterwards, off-main, because it costs
        // 0.26s over the sessions shown — nothing on a background queue, and a
        // visibly frozen open if the main actor paid it (rule 9). Robert asked
        // for this so that "microphone" finds "recording lost": the name tells
        // you what a session was CALLED, and the turns tell you what it was
        // about. See `TranscriptSearchText` for the bound and its measurement.
        let paths = Dictionary(scanned.map { ($0.sessionId, $0.transcriptPath) },
                               uniquingKeysWith: { first, _ in first })
        let wanted = hidden.map(\.id)
        Task.detached(priority: .userInitiated) {
            var extra: [String: [UInt8]] = [:]
            for id in wanted {
                guard let path = paths[id] else { continue }
                let text = TranscriptSearchText.shared.bytes(forTranscriptAt: path)
                if !text.isEmpty { extra[id] = text }
            }
            await MainActor.run { [weak self] in self?.hud.widenPastAgents(extra) }
        }
    }

    /// Focus a live session — tmux attach, or a Terminal.app tab for a
    /// hand-started one — from the list. Same door `StatusHUD.goToSession()`
    /// uses from the card; this one is reached from a session id rather than
    /// from the card's current target.
    func goToSession(_ sessionId: String) {
        Task.detached {
            guard let live = (ClaudeAgentsCLI().sessions() ?? [])
                .first(where: { $0.sessionId == sessionId }) else {
                Permissions.log("goTo: \(sessionId.prefix(8)) is not live any more")
                return
            }
            guard let tty = ProcessProbe.tty(of: live.pid) else {
                Permissions.log("goTo: no tty for pid \(live.pid)")
                return
            }
            switch await TerminalTabFocus.focus(tty: tty) {
            case .focused: Permissions.log("goTo: focused \(tty)")
            case .tabGone: Permissions.log("goTo: tab not found for \(tty)")
            case .timedOut(let seconds): Permissions.log("goTo TIMEOUT after \(seconds)s for \(tty)")
            case .failed(let message): Permissions.log("goTo FAILED: \(message)")
            }
        }
    }

    func revive(_ sessionId: String, name: String) {
        hud.showReceipt(.reviving(name))
        Task.detached {
            let fresh = SessionDiscovery.discover(ttl: 0).sessions
                .first { $0.sessionId == sessionId }
            guard let fresh else {
                // Not a Claude Code session — check Codex history before
                // refusing outright. A genuinely different mechanism below,
                // not a reimplementation: Codex attach goes through
                // `attemptCodexResume`, never `SessionLauncher.resume`,
                // because Codex's own single-writer lock is what answers
                // "already live", not a probe run beforehand (the settled
                // design, 2026-08-22-tb-codex-hand-started-adoption — the
                // same branch `tbase revive` already has and already
                // proved live).
                let codexFound = SessionDiscovery.discoverCodex().sessions
                    .first { $0.sessionId == sessionId }
                guard let codexFound, codexFound.revivable, let cwd = codexFound.cwd else {
                    Permissions.log("revive: refused \(sessionId.prefix(8)) — "
                        + (codexFound == nil ? "no longer on disk"
                           : "its directory is gone"))
                    await MainActor.run { [weak self] in
                        self?.hud.showReceipt(.notRevived(
                            codexFound == nil ? "no longer on disk" : "its directory is gone"))
                    }
                    return
                }
                await MainActor.run { [weak self] in self?.announceNext(only: sessionId) }
                switch SessionLauncher.attemptCodexResume(sessionId: sessionId, directory: cwd) {
                case .success(.attached):
                    Permissions.log("revive: attached codex \(sessionId.prefix(8))")
                    await MainActor.run { [weak self] in self?.hud.showReceipt(.revived(name)) }
                case .success(.alreadyLive):
                    Permissions.log("revive: refused \(sessionId.prefix(8)) — already live elsewhere")
                    await MainActor.run { [weak self] in
                        self?.hud.showReceipt(.notRevived(
                            "it's already running somewhere I don't control — end it in that terminal"))
                    }
                case .failure(let error):
                    Permissions.log("revive: failed codex \(sessionId.prefix(8)) — \(error.message)")
                    await MainActor.run { [weak self] in
                        self?.hud.showReceipt(.notRevived("couldn't attach"))
                    }
                }
                return
            }
            guard let command = fresh.reviveCommand else {
                // One receipt per reason (18 Aug). `alreadyAwake` used to answer
                // for all four, and it is only true for the first — so the
                // panel's single word on a refusal was false in the three cases
                // that are not "it came back on its own". That was survivable
                // while REVIVE was a hover verb on a list; it is not, now that
                // the lamp is the switch and this is what the switch says back.
                let why = fresh.liveness
                Permissions.log("revive: refused \(sessionId.prefix(8)) — liveness \(why.rawValue)")
                await MainActor.run { [weak self] in
                    switch why {
                    case .live:
                        self?.hud.showReceipt(.alreadyAwake)
                    // `gone` with no revive command means the one other thing
                    // `revivable` tests: the launch directory is no longer there,
                    // so `--resume` would land nowhere.
                    case .gone:
                        self?.hud.showReceipt(.notRevived("its directory is gone"))
                    case .unknown:
                        self?.hud.showReceipt(.notRevived("can't tell if it's running"))
                    }
                }
                return
            }
            // Say what it was doing, the moment you ask for it back (ruled
            // 18 Aug: "revive likewise should basically work the same — if
            // you're reviving, it should reopen the agent message").
            //
            // Announced BEFORE the resume rather than after, and not waiting on
            // it: unlike a launch, a revived session already has a brief, so
            // there is nothing to synthesize and nothing to wait for. The same
            // door a launch greeting uses, which means the same voice — this
            // session's own, assigned long ago — and the same reply routing,
            // under the same id, because `--resume` keeps it.
            //
            // A reply that beats the process back is not lost: dispatch checks
            // readiness and says "can't take this yet, your words are kept."
            await MainActor.run { [weak self] in self?.announceNext(only: sessionId) }
            switch SessionLauncher.resume(sessionId: sessionId, directory: command.cwd) {
            case .success:
                await MainActor.run { [weak self] in self?.hud.showReceipt(.revived(name)) }
                // The announce fired before this resume even started (see
                // `attachLivePid`'s doc comment) — by the time `resume` has
                // returned, the process has been up for however long the
                // trust-prompt watch took, so `claude agents --json` should
                // already know it. A few short retries, not a bare single
                // shot, because that registration is still a separate
                // process's own timing, not this call's.
                for _ in 0..<5 {
                    if let pid = (ClaudeAgentsCLI().sessions() ?? [])
                        .first(where: { $0.sessionId == sessionId })?.pid {
                        await MainActor.run { [weak self] in
                            self?.hud.attachLivePid(pid, sessionId: sessionId)
                        }
                        break
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            case .failure(let error):
                // The cause is a log line, not a card: an exit status means
                // nothing to the person holding the mouse. What they get is
                // the command that does not depend on this app's environment
                // — which is exactly the axis the 24 Aug failure lived on,
                // where every in-app launch died and this line worked all
                // morning — and a retry offer only when a retry could differ.
                Permissions.log("revive: failed \(sessionId.prefix(8)) — \(error.message)")
                let manual = SessionLauncher.manualRevival(
                    sessionId: sessionId, directory: command.cwd)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manual, forType: .string)
                    self.hud.showResult(
                        "Couldn't reopen \(name) here. Copied the manual revival command to "
                        + "your clipboard — paste it in a terminal."
                        + (error.worthRetrying ? " Or tap it again." : ""))
                }
            }
        }
    }

    /// The invitation's other half: a fresh agent in the artifact's own
    /// directory, opening with the artifact.
    ///
    /// The prompt is handed over twice on purpose. The clipboard copy is
    /// unconditional and cannot fail; the command-line copy is the one that
    /// makes the session start already holding the file, and it is skipped for
    /// any path carrying a quote, because that path would be interpolated
    /// through AppleScript into a shell and both layers quote differently. A
    /// session that opens blank with the prompt one ⌘V away is a small loss; a
    /// mangled `do script` is a window full of shell errors as the first thing
    /// a new user sees.
    func newSession(forArtifact path: String) {
        // Re-resolved rather than trusted: the card has been on screen for as
        // long as the user took to decide, and the string that reaches the
        // shell should be checked at the moment it is used, not the moment it
        // was displayed.
        guard let subject = DeepLink.subject(
            from: path, exists: { FileManager.default.fileExists(atPath: $0) })
        else {
            hud.showResult("That page's subject is no longer there. Nothing started.")
            return
        }
        let directory = subject.directory
        let opening = DeepLink.openingPrompt(for: subject)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(opening, forType: .string)
        let inline = DeepLink.openingCommand(base: SessionLauncher.defaultCommand,
                                             prompt: opening)
        let command = inline ?? SessionLauncher.defaultCommand
        Permissions.log("invitation: launching in \(directory) "
                        + "(prompt \(inline == nil ? "clipboard only" : "inline"))")
        // No greeting here. This session was started FOR something and the card
        // that offered it already said what; asking "how would you like to get
        // started?" over the top of an answered question is the app talking to
        // itself.
        newSession(directory: directory, command: command, greet: false)
    }

    /// Off-main like `revive()`: `launch()` drives Terminal through AppleScript
    /// and then watches the new tab for the trust prompt — its own doc says
    /// "call off-main". Until 12 Aug this ran on the main actor, and every
    /// NEW AGENT click beach-balled the app for the watcher's full 30s
    /// (app.log 22:00:24→22:00:59: launched, then "no trust prompt seen
    /// within 30s", with the main thread asleep in between).
    /// `greet` is false for the one launch that arrives already knowing what it
    /// is for — the artifact invitation, which hands the session its opening
    /// prompt. Everywhere else the greeting is the point: a launched agent is a
    /// waiting agent, and it says so.
    func newSession(directory dir: String, command: String, greet: Bool = true) {
        let label = (dir as NSString).lastPathComponent
        let line = LaunchGreeting.nextLine()

        // The card, FIRST — before Terminal is asked to do anything (ruled
        // 18 Aug). Painting after the launch meant painting after a window
        // opened, a CLI came up, a trust watcher settled and an id appeared in
        // `claude agents --json`: seconds of nothing, in answer to a button.
        // None of that is a precondition for asking the question, so none of it
        // is waited on. The session is attached underneath when it exists.
        // The voice this agent is about to be given, asked for before it has an
        // id to be given it under (ruled 18 Aug: "it should be the actual voice
        // for the agent, not a temporary one-off"). The greeting used the app's
        // own narrator, so a session introduced itself as one person and came
        // back as another the first time you pressed ⌃⌥. The peek is bound to
        // the session at registration, so the two cannot diverge.
        let voice = (try? store?.nextVoiceInRotation(roster: VoiceRoster.load())) ?? nil
        // The promise the card's answer waits on. Created with the card, because
        // the whole point of the card is that you may answer it before there is
        // an agent to answer — see PendingLaunch for what that cost before.
        // Where your attention was when the button was pressed, so the
        // adoption below can tell "still here" from "moved on". Read BEFORE the
        // launch is built and carried ON it (24 Aug): the microphone needs this
        // fact too, and as a local here it could not see it.
        let conversationAtLaunch = activeConversation?.sessionId
        let launch = greet ? PendingLaunch(label: label, directory: dir,
                                           conversationAtLaunch: conversationAtLaunch) : nil
        if let launch { pendingLaunch = launch }
        if greet, hud.showGreeting(line: line, label: label) {
            // Through the greeting cache, which is what it is for: one fixed
            // sentence per voice, synthesized once and replayed from disk
            // forever after — no model call, no round trip, no waiting for a
            // brief that has not been written yet. Detached because the audio
            // is not the panel's business and the panel is already up.
            Task.detached(priority: .userInitiated) {
                await GreetingCache.speak(line, voiceId: voice)
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let before = Set((ClaudeAgentsCLI().sessions() ?? [])
                .filter { $0.cwd == dir }.map(\.sessionId))
            // `acceptTrustPrompt: false` — we run that watcher ourselves, in
            // parallel, immediately below. It blocks for at least two settled
            // polls and up to thirty seconds, and until now the registration
            // this greeting binds to queued behind it.
            let result = SessionLauncher.launch(directory: dir, command: command,
                                                acceptTrustPrompt: false)
            guard case .success(let tty) = result else {
                // Every exit from here on releases the promise. A waiter left
                // hanging is a reply that never lands and never says why, which
                // is the one outcome worse than the misroute this replaces.
                launch?.abandon()
                if case .failure(let error) = result {
                    await MainActor.run { [weak self] in
                        self?.hud.showResult("Couldn't start an agent: \(error.message). "
                                             + "A missing tmux binary is the usual suspect.")
                    }
                }
                return
            }
            Task.detached(priority: .utility) {
                SessionLauncher.watchForTrustPrompt(tty: tty)
            }
            await MainActor.run { [weak self] in
                self?.lastStatusLine = "new session launched"
                self?.rebuildMenu()
            }

            // First-run reality (ruled, docs/ws-b-ruling.md): the
            // directory-trust prompt is a security consent and is NEVER
            // auto-answered when it needs a human. If nothing registers, say so
            // — a walked-away launch must not be a silently stillborn
            // investigation.
            guard let sessionId = LaunchGreeting.awaitRegistration(
                directory: dir, excluding: before) else {
                launch?.abandon()
                Permissions.log("launcher: no session registered in \(dir) after 30s")
                await MainActor.run { [weak self] in
                    guard let self, self.hud.canSurfaceAmbiently else { return }
                    self.showIdleGrid(note: "New agent is waiting on a prompt (attach to see it).")
                }
                return
            }

            // Kept BEFORE the greeting row is written and before the card is
            // bound: the promise is about the SESSION EXISTING, which is now
            // true, and it must not be hostage to a store write or to whether
            // the card is still on stage. Binding can fail — it does, whenever
            // you started talking — and the words must reach the agent anyway.
            launch?.resolve(sessionId: sessionId)
            guard greet else { return }

            // THE DESTINATION FOLLOWS THE LAUNCH (ruled 19 Aug), and it is
            // claimed HERE — one line after the session provably exists, and
            // before the store write, the greeting row, and the card binding
            // that used to own it. The comment above says the promise must not
            // be hostage to whether the card is still on stage; the reply
            // target was, twenty lines further down, assigned only inside the
            // successful-bind branch. So a microphone fault at 15:35:57 that
            // moved the panel off the greeting card sent every word after it
            // to the PREVIOUS agent, in a different repository, silently.
            // Binding a card is a question about the panel. Where your words
            // go is not, and no longer waits for an answer.
            //
            // Two conditions, because following the launch must not mean
            // overriding you:
            //   · this is still the newest launch — a second + NEW AGENT
            //     supersedes the first, and the older one must not claim the
            //     destination when it happens to register second;
            //   · you have not deliberately moved on since — a lamp press or
            //     a ⌃⌥ is an explicit statement about where your attention is,
            //     and it outranks a launch you started before it.
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard LaunchAdoption.claimsTheReply(
                    isNewestLaunch: launch != nil && self.pendingLaunch === launch,
                    conversationAtLaunch: conversationAtLaunch,
                    conversationNow: self.activeConversation?.sessionId)
                else {
                    // Answered, even though the answer is "not you" — the claim
                    // must expire on this branch too, or the launch keeps
                    // owning a microphone it just lost.
                    launch?.settle()
                    Permissions.log("launch: \(sessionId.prefix(8)) registered, but you "
                        + "moved on — replies stay where you put them")
                    return
                }
                self.activeConversation = (sessionId, label, dir)
                // The destination now lives in the panel; the launch stops being
                // consulted. See PendingLaunch.ownsTheReply — this is the
                // hand-off the 24 Aug misroute happened one hop before.
                launch?.settle()
                Permissions.log("launch: replies now go to \(sessionId.prefix(8))")
            }

            guard let store = await self?.store else { return }
            let pid = (ClaudeAgentsCLI().sessions() ?? [])
                .first(where: { $0.sessionId == sessionId })?.pid
            do {
                // The durable half. The card is already on screen; this is what
                // makes it a row in the grid, a reply target, and a turn the
                // session's own first Stop supersedes. nil means the session
                // already carries its greeting.
                guard try LaunchGreeting.record(sessionId: sessionId, directory: dir,
                                                line: line, voice: voice, tty: tty,
                                                store: store) != nil
                else { return }
                Permissions.log("greeting: recorded for \(sessionId.prefix(8)) in \(dir)")
            } catch {
                // The agent is up either way. A greeting that failed to land
                // costs a trip to the terminal, which is exactly where we were
                // before it existed.
                Permissions.log("greeting: not recorded for \(sessionId.prefix(8)): \(error)")
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The card acquires its session, and with it the doors: GO TO
                // AGENT, the hub link, the title. Only the doors — the reply
                // routing was settled above, the moment the session existed.
                // A door to an agent that does not exist is worse than no
                // door (18 Aug, 22:37), so this may still refuse; refusing now
                // costs a card, never a destination.
                if self.hud.bindGreeting(sessionId: sessionId, pid: pid,
                                         label: label, cwd: dir) {
                    Permissions.log("greeting: bound \(sessionId.prefix(8)) to the card")
                } else {
                    // Still logged, and still a fact worth having: three
                    // misroutes on 18 Aug were visible in app.log only as a
                    // MISSING line. It no longer reports a misroute, because
                    // there no longer is one — only a card that moved on.
                    Permissions.log("greeting: NOT bound \(sessionId.prefix(8)) — "
                        + "card moved on; replies still go to it")
                }
            }
        }
    }

    @objc func newSessionTapped() { newSession() }
}
