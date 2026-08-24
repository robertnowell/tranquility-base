import AppKit
import TranquilityCore

/// AppDelegate's push-to-talk gesture handling -- the hotkey transition
/// table and the announce-next walk -- split out of main.swift (App-lane
/// P7, 24 Aug); see AppDelegate+Permissions.swift's doc comment for why.

extension AppDelegate {
    // MARK: - Push to talk

    func handle(_ transition: HotkeyMonitor.Transition) {
        // Any gesture is attention: the panel must not yank itself back to the
        // grid underneath it (the receipt's timer dies on contact; the spoken
        // card has no timer at all — ruling 14 reversed, 12 Aug). The arm
        // window is the one exception — arming is SPECULATION about a hold
        // that may turn out to be a tap or a typing chord, so it must not
        // consume the receipt's clock; the abort path restarts the clock when
        // its revert lands back on the receipt.
        switch transition {
        case .armWindowOpened, .armAborted: break
        default: returnToGridWork?.cancel()
        }
        // Acknowledge before acting — EVERY gesture, no exceptions (ruled
        // 06 Aug: "anytime a chord or command is heard from the user, light up
        // that top bar, and it should be super reliable. I should never
        // question whether my control is having an impact on the system").
        //
        // Unconditional on purpose. The previous version pulsed for three
        // transitions and left the rest to downstream call sites that sat
        // BEHIND their guards, so exactly the presses that did nothing —
        // ⌃⌃ with nothing announced, ⌥ taps outside hands-free, a gesture
        // arriving before the first paint — were the ones that also looked
        // unheard. Acknowledgment is not a reward for a press that worked; it
        // is the receipt for a press that was received.
        switch transition {
        case .armWindowOpened:
            // The light comes on with the key and STAYS on until it lifts
            // (ruled 06 Aug) — one press, one light. Everything the hold
            // becomes downstream (the mic opening, the pill upgrading) must
            // NOT re-light it; that second flash was the stutter.
            hud.holdAcknowledge()
        case .armAborted, .replyEnded, .replyAborted:
            hud.releaseAcknowledge()
        case .replyBegan:
            break  // already lit by the arm that preceded it
        case .next, .dismiss, .optionTapped, .pauseToggled, .controlDoubleTapped:
            hud.acknowledge(.recognized)
        case .controlRegistered:
            // Blue: received, not acted on. The second ⌃ of a ⌃⌃ arrives while
            // this light is still up and recolours it green, so the pair reads
            // as one light resolving rather than two flashes.
            hud.acknowledge(.registered)
        }
        switch transition {
        case .controlRegistered:
            // Acknowledged above and nothing else. A first ⌃ is not an
            // instruction — the whole point of the case is that the light can
            // report a press the app is not going to act on.
            break
        case .next:
            // Open issue #6, wired at last: ⌃⌥ while the microphone is open would
            // start an announcement into a live mic — it would record itself.
            // The question is answered by the state, in one place, for every path
            // that opens the mic through `.listening`.
            guard !hud.isCapturingAudio else {
                Permissions.log("next: ignored, microphone is open")
                return
            }
            // Advancing mid-transcription would announce against a panel the
            // arbiter refuses to repaint; the pendingSend arrives in seconds and
            // the press works then. Same law as the microphone guard above.
            if case .transcribing = hud.state {
                Permissions.log("next: ignored, transcription in flight")
                return
            }
            // During the undo window, ⌃⌥ commits the send and goes HOME
            // (re-ruled 06 Aug, superseding ui-pass-7's commit-and-advance:
            // "it should go to the home screen first" — the readback is not
            // an exception to home-first, and advancing straight into the
            // next agent's voice was the surprise, not the momentum). The
            // countdown fast-forwards, then the grid; a second press invites
            // the next agent from there, same as every other altitude.
            if hud.commitPendingSendNow() {
                Permissions.log("next: committed the pending send, going home")
                showIdleGrid()
                return
            } else if hud.state.isCardOnStage {
                // ⌃⌥ = home first (ui-pass-7, ruling 7). From any card on
                // stage — the announcement or any ⌃⌃ ladder rung, both of
                // which live in `.speaking` — ⌃⌥ stops the voice and returns
                // to the grid, advancing NOTHING: no dismissal, no markHeard,
                // no next announcement. The cursor stays exactly where the
                // announce machinery already put it (Core writes nothing
                // before the audio, so a mid-speech stop leaves the item
                // unread and its row lit; a fully-heard card stays heard).
                // This is also how the ladder cycle (8fecb52) is EXITED: ⌃⌥
                // leaves the walk standing where it is — ⌃⌃ resumes it —
                // rather than advancing it. A rapid double-press composes
                // into "next agent": the first press lands on the grid, and
                // from the grid the second press invites the next agent below.
                goHomeFromCard(via: "⌃⌥")
                return
            }
            // From hidden, ⌃⌥ surfaces the grid and stops (ruled 05 Aug):
            // the queue appears before anyone speaks, so you always see where
            // you are before choosing to listen. The hail is unaffected — a
            // hail has already surfaced the grid, so the go-ahead press finds
            // the panel visible and plays immediately, exactly as before.
            guard hud.isOnScreen else {
                Permissions.log("⌃⌥: surface")
                showIdleGrid()
                return
            }
            // From the visible grid, the empty state, or a receipt/failure
            // card: ⌃⌥ invites the next agent — and this is how a hail's
            // "go ahead" resolves, since the hail surfaces the grid. The old
            // dismiss-on-advance died with home-first: advancing can no
            // longer happen FROM the speaking card at all.
            Permissions.log("⌃⌥: next")
            activeConversation = nil   // moving on is the explicit end of a conversation
            announceNext()

        case .dismiss:
            // Same action as the Dismiss button; a chord because Escape leaks ESC
            // into the focused terminal and interrupts the Claude session there.
            //
            // It is also the recourse out of a transcription (06 Aug: "I cannot
            // cancel transcriptions with a command or anything else"). The
            // cancel button only appears after ~20s of waiting; the chord works
            // from the first second. The audio is already durable on disk, so
            // cancelling costs the transcript, never the recording.
            if case .transcribing = hud.state {
                replyGeneration += 1        // orphans whatever is in flight
                Permissions.log("⌃⇧: cancelled the transcription in flight")
                lastStatusLine = "transcription cancelled, audio kept"
                hud.endCapture(because: "transcription cancelled by chord")
                showIdleGrid(note: "Transcription cancelled. Audio kept.")
                return
            }
            if hud.isBusyOnScreen || hud.isOnScreen { hud.dismiss() }

        case .optionTapped:
            // One tap ends ANY live capture — the mirror of releasing the held
            // key, and the escape hatch from a capture whose release was lost.
            //
            // 06 Aug, from the log: the app sat in `listening` with the mic
            // open and no key held, and every press logged "no meaning in
            // listening" because a tap only meant something in hands-free.
            // A capture with no way out is the trust-killer — "you have to
            // know that when you need to talk, you can talk", and equally
            // that you can stop. Hands-free is now just the case that also
            // clears its latch.
            // The decision is made in Core, where it is tested exhaustively
            // (OptionTapDecisionTests). This handler owns the side effects only.
            // Both of 10 Aug's ⌥ regressions were decisions taken inside an
            // untestable file; the rule "while speaking, ⌥ lets you speak" is now
            // an assertion rather than a sentence in a commit message.
            let decision = OptionTapDecision.decide(
                isSpeaking: hud.state.isSpeaking,
                isRecording: recorder.isRecording,
                isArmed: armedAt != nil,
                withinPairWindow: lastOptionTapAt.map { Date().timeIntervalSince($0) < 0.45 } ?? false,
                listeningJustStarted: listeningStartedAt.map { Date().timeIntervalSince($0) < 0.45 } ?? false,
                micGranted: micGranted)
            Permissions.log("⌥ tap: \(decision) in \(hud.state)")

            switch decision {
            case .ignore:
                return
            case .armFirstOfPair:
                lastOptionTapAt = Date()
                return
            case .endCapture:
                if handsFreeListening { handsFreeListening = false }
                handle(.replyEnded)
                return
            case .startListening:
                break
            }
            // Talking over the announcement is the commonest thing there is, and
            // for a long time it did nothing. Ruled a bug, 10 Aug: "If something
            // is speaking and I hit Option, it should listen to me. It should not
            // be discarded."
            //
            // Until now a tap while speaking only armed the double-tap window, so
            // it took TWO taps inside 0.45s to be heard — and the log of a
            // frustrated session shows exactly what that costs: `⌥ tap: no
            // meaning in speaking` at 19:51:05 and again at 19:51:06, a full
            // second apart, each one forgotten before the next arrived, until the
            // sixth press. A key that ignores you while the app is talking is the
            // one moment you most need it.
            //
            // So while we are speaking, ONE tap is the whole gesture: stop
            // talking and listen. It locks hands-free, which makes the next tap
            // send — the same tap-to-start, tap-to-send pair the double-tap
            // already gave, minus the timing you had to get right.
            do {
                lastOptionTapAt = nil
                guard micGranted else { return }
                if recorder.isRecording {
                    Permissions.log("hands-free: refused, mic already live")
                    lastStatusLine = "mic already live, tap ⌥ to send"
                    return
                }
                // ⌥⌥ from the read-back is Don't send, then ⌥⌥ (ruled 18 Aug).
                // It was not: this path opened a new capture and never touched
                // the countdown, so four seconds later the words the gesture had
                // just rejected were dispatched into a live microphone (app.log
                // 22:39:05). The hold path has always said these two lines; the
                // tap path never got them. `StatusHUD.releasePendingSend` now
                // catches the whole class at the door — this stays because the
                // ORDER is a ruling in its own right, and the door cannot know it.
                //
                // BEFORE the microphone, unlike every mutation below it. The
                // 10 Aug rule ("nothing is mutated until the microphone is
                // actually recording") protects a waiting agent you could LOSE to
                // a failed open; this is the opposite kind of mutation. You asked
                // for these words NOT to be sent, and a microphone that fails to
                // open is not a reason to send them. A failure lands on the mic
                // card with the transcript discarded — kept in past utterances,
                // out of the sendable set — which is where Don't send leaves it
                // too. Same order `.replyBegan` already uses for the hold.
                //
                // The generation bump is not decoration and it is not the fix:
                // `send(utteranceId:)` reads the generation when the timer FIRES,
                // so it can never catch a countdown. What it does catch is the
                // sibling case one state over — ⌥⌥ during `.transcribing`, which
                // also admits `.listening` — where the replaced transcription
                // would otherwise finish and open a read-back for the old words
                // while you are already speaking the new ones.
                replyGeneration += 1
                hud.cancelPendingSend(restartListening: false)
                // ORDER IS THE WHOLE FIX (10 Aug, second attempt). This block
                // used to mark the session heard and stop the announcement
                // BEFORE opening the microphone. When the open then failed —
                // which the delivery gate now makes visible rather than silent —
                // the session had already gone green-to-empty, the panel had
                // already fallen back to the grid, and there was no recorder to
                // show for it. One tap could lose a waiting agent and give
                // nothing back.
                //
                // Nothing is mutated until the microphone is actually recording.
                // A failed open now leaves the world exactly as it found it: the
                // lamp still green, the announcement still playing, the agent
                // still waiting on you.
                let context = resolveReplyContext()
                do {
                    try recorder.start()
                } catch {
                    Permissions.log("mic: start failed (hands-free) — nothing changed: \(error)")
                    hud.showResult(micFailureMessage(error))
                    return
                }

                handsFreeListening = true
                // Same rule as the tap path above: a launch in flight owns the
                // reply, and the routing ladder must not be allowed to answer
                // for it.
                if let launch = pendingLaunch, launch.isPending {
                    recordingLaunch = launch
                    recordingTarget = nil
                } else if let ctx = context {
                    recordingLaunch = nil
                    hud.adoptTarget(sessionId: ctx.sessionId, pid: ctx.pid,
                                    label: ctx.label, cwd: ctx.cwd)
                    recordingTarget = ctx.sessionId
                } else {
                    dictationMode = true
                    hud.dictationDestination = FocusedInput.focusedEditableApp()
                        .map { StateLegend.destination($0) } ?? StateLegend.clipboardDestination
                }
                // Deliberately NOT marking the session heard here (ruled 10 Aug).
                // An agent stops waiting when you ANSWER it or when you press its
                // lamp — never because a key was pressed while it happened to be
                // talking. Hearing the first half of an announcement and starting
                // to reply is not the same as being done with it, and the reply
                // path advances the cursor on a confirmed send anyway.
                coordinator?.speech.stop()
                isBusy = true
                listeningStartedAt = Date()
                updateTitle()
                hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 })
                Permissions.log("hands-free: listening locked")
            }

        case .pauseToggled:
            // Handled in the hotkey tap closure (audio-only, ruled); the case
            // exists so the switch stays exhaustive.
            break

        case .controlDoubleTapped:
            // ⌃⌃ = escalate the daemon's channel: speak the rationale and risk
            // for the announcement on stage (or the last one spoken), composed
            // from the brief's already-computed card fields — zero model calls,
            // and the session itself is never woken. Wiring per docs/wiring-a4.md.
            guard let coordinator else { return }
            guard !hud.isCapturingAudio else {
                Permissions.log("depth-1: ignored, microphone is open")
                return
            }
            guard let announcement = lastAnnouncement else {
                // Quiet, not spoken: nothing has been announced this launch, and
                // the voice is the away-channel — it never narrates empty state.
                Permissions.log("depth-1: nothing announced yet; staying quiet")
                return
            }
            // The ladder (ruled: findings → solution → why → message, the
            // order of the stack). Each ⌃⌃ takes the next rung; a new
            // announcement resets the walk. After WHY comes the original
            // MESSAGE re-heard — it lands differently once it has been
            // explained three ways — then the cycle repeats. Empty rungs
            // never made it into the array.
            let key = "\(announcement.event.sessionId):\(announcement.event.latestId)"
            if ladderKey != key { ladderKey = key; ladderIndex = 0 }
            let rungs = SpokenComposition.ladderRungs(for: announcement)
            let rung = rungs[ladderIndex % rungs.count]
            ladderIndex += 1
            let previous = announceTask
            announceTask = Task { @MainActor in
                coordinator.speech.stop()
                previous?.cancel()
                _ = await previous?.value
                guard !Task.isCancelled else { return }
                // Audio ⊂ visual, and the pill NAMES the rung ("◀ FINDINGS") so
                // you always know what kind of thing you are hearing. The live
                // probe resolves the agent's pid exactly as the base
                // announcement does (ui-pass-7, ruling 2): the rung path used
                // to pass nil, which hid "Go to agent" the moment the walk
                // began — the button persists through the entire ladder.
                let live = (ClaudeAgentsCLI().sessions() ?? [])
                    .first { $0.sessionId == announcement.event.sessionId }
                hud.showAnnouncement(
                    spoken: rung.spoken,
                    sessionId: announcement.event.sessionId,
                    pid: live?.pid,
                    project: tabDisplayName(for: announcement.event, live: live),
                    cwd: announcement.event.cwd,
                    eventId: announcement.event.sessionId,
                    placard: "\(StateLegend.Glyph.speaking) \(rung.kind.rawValue)")
                Permissions.log("ladder: \(rung.kind.rawValue) "
                                + "(\(ladderIndex)/\(rungs.count)) for "
                                + "\(announcement.event.sessionId.prefix(8))")
                try? store?.recordDogfood(.depthOnePulled,
                                          sessionId: announcement.event.sessionId)
                // In the session's voice (ruled 05 Aug, a559f29): the pull deepens
                // that session's announcement, so it must sound like it.
                // The rung after this one, warmed while this one talks. Walks
                // continue ~75% of the time at every step, and the render hides
                // completely under the rung already playing.
                let nextRung = ladderIndex
                let warmToken = "\(key):rung\(ladderIndex)"
                let spoken = await coordinator.speech.speak(
                    rung.spoken,
                    voice: coordinator.voiceId(for: announcement.event.sessionId),
                    onWord: { [weak self] range in
                        Task { @MainActor in
                            guard let self else { return }
                            self.hud.highlight(upTo: range.upperBound)
                            self.warmNextRung(after: nextRung, token: warmToken)
                        }
                    })
                hud.highlight(upTo: rung.spoken.text.count)
                lastStatusLine = "\(rung.kind.rawValue.lowercased()) spoken"
                // Ruling 14 reversed (12 Aug): a finished rung dwells. No clock —
                // the reader decides when a pull has been read, so the only exits
                // from this card are gestures. `completed` is still read rather
                // than discarded (`_ = await` hid a provider lying about early
                // returns once already); an unfinished rung is still worth a line.
                if !spoken.completed {
                    Permissions.log("ladder: rung did not complete")
                }
                rebuildMenu()
            }

        case .armWindowOpened(let pressedAt):
            // Instant-arm (docs/instant-arm.md): bare ⌥ survived the grace.
            // Speculative on purpose — a tap or a chord fully unwinds it.
            guard micGranted else { return }
            // A wedged machine will refuse the open anyway; refusing here
            // skips painting an arming face that would only revert.
            guard recorder.allowsAutoArm else {
                Permissions.log("arm: skipped, mic machine wedged")
                return
            }
            guard armedAt == nil, !recorder.isRecording else {
                // Hands-free is live (a ⌥ tap will SEND) or a capture is
                // already running: nothing to arm.
                Permissions.log("arm: skipped, mic already live")
                return
            }
            // Visual FIRST (eval E5): between the grace timer firing and this
            // render sit only in-memory stash writes — no probes, no engine.
            // Identity only if already in hand: resolveReplyContext shells out
            // to the liveness probe and stays where it always was, at
            // hold-resolution.
            armedVisually = hud.showArming(target: activeConversation?.label)
            let visibleMs = Int(Date().timeIntervalSince(pressedAt) * 1000)
            // Audio second: optimistic capture, NO StreamedUtterance — the
            // stream (a network session) is created at hold-resolution as
            // always, and openStream() feeds it this backlog.
            do {
                try recorder.start(openingStream: false)
            } catch {
                // Transient route-change territory; the hold, if it resolves,
                // retries through the ordinary path and reports for real.
                Permissions.log("arm: optimistic mic open failed (\(error)); reverting")
                if armedVisually { hud.revertArming(because: "mic failed") }
                armedVisually = false
                return
            }
            armedAt = Date()
            isBusy = true
            updateTitle()
            let faceNote = armedVisually ? "shown" : "refused, audio-only arm"
            Permissions.log("latency: key-down→arming-visible \(visibleMs)ms"
                + " (face \(faceNote));"
                + " mic open +\(Int(Date().timeIntervalSince(pressedAt) * 1000))ms"
                + " after key-down")

        case .armAborted:
            // The press turned out to be a tap or a real shortcut. Unwind
            // everything the arm did: stop and DISCARD the capture — no
            // utterance row, no file write, no transcription — and restore
            // the exact face the panel wore before. Any tap meaning
            // (optionTapped etc.) arrives after this and acts as it always
            // has.
            let armedDuration = armedAt.map { Date().timeIntervalSince($0) }
            armedAt = nil
            let hadFace = armedVisually
            armedVisually = false
            if armedDuration != nil {
                // Same exception-firewalled teardown as every capture stop
                // (eval E4); abandon returns no audio and writes nothing.
                recorder.abandon()
                isBusy = false
                updateTitle()
            }
            if hadFace { hud.revertArming(because: "tap or chord") }
            if let armedDuration {
                Permissions.log("arm: discarded, \(Int(armedDuration * 1000))ms audio")
            }
            // If the revert landed back on the receipt, its clock — which this
            // gesture deliberately never cancelled, but whose work item may have
            // fired into the arming window and consumed itself — restarts. The
            // spoken card dwells (ruling 14 reversed, 12 Aug), so it re-arms
            // nothing.
            switch hud.state {
            case .receipt: scheduleReturnToGrid()
            default: break
            }

        case .replyBegan:
            // Latency instrumentation (ruled 05 Aug: measure before rewiring).
            // t0 is the moment the gesture RESOLVED — the ~0.35s tap-vs-hold
            // threshold has already been paid before this line; HotkeyMonitor
            // owns that constant. What we measure here is everything the app
            // adds on top: teardown, mic engine start, first pill paint.
            let gestureResolvedAt = Date()
            func lat(_ stage: String) {
                let ms = Int(Date().timeIntervalSince(gestureResolvedAt) * 1000)
                Permissions.log("latency: \(stage) +\(ms)ms after hold resolved")
            }
            guard micGranted else { return }
            // Instant-arm: the mic may already be OURS, opened at the arm
            // window. Consume the arm — from here on this is an ordinary
            // reply that simply started capturing ~270ms early.
            let armed = armedAt
            armedAt = nil
            armedVisually = false
            if recorder.isRecording, armed == nil {
                // Refusing silently is how "app seems dead" reports start — the
                // stomped-pill incident left the recorder live behind an idle
                // facade and every press landed here, invisibly.
                Permissions.log("reply: refused, mic already live")
                lastStatusLine = "mic already live, tap ⌥ to send"
                return
            }
            // Open issue #7 is NOT wired here, deliberately. `canStartReply` as a
            // hard refusal would break three live behaviors: dictation-to-clipboard
            // when nothing is waiting (which is how #7's "transcribe then fail" was
            // actually fixed), replying from an idle/hidden panel inside the 15-min
            // reply window, and re-recording during transcription (replyGeneration
            // exists for exactly that). The predicate needs a rethink before it can
            // gate anything. See docs/ws-c-changes.md.
            // The agent you just launched owns this reply, even though it has
            // no id yet. Resolving the routing here would walk past it to the
            // PREVIOUS agent — the misroute this exists to end — so the launch
            // is remembered instead and the words wait for it at submit time.
            if let launch = pendingLaunch, launch.isPending {
                recordingLaunch = launch
                recordingTarget = nil
            } else if let ctx = resolveReplyContext() {
                recordingLaunch = nil
                hud.adoptTarget(sessionId: ctx.sessionId, pid: ctx.pid,
                                label: ctx.label, cwd: ctx.cwd)
                recordingTarget = ctx.sessionId
            } else {
                dictationMode = true
                hud.dictationDestination = FocusedInput.focusedEditableApp()
                    .map { StateLegend.destination($0) } ?? StateLegend.clipboardDestination   // nothing to answer → transcript to clipboard
            }
            // Anything already in flight belongs to a reply you have just replaced.
            replyGeneration += 1
            // Holding ⌥ during the send window means "no, let me say that again".
            // The old transcript is discarded rather than deleted, and the gesture
            // itself starts the new recording, so nothing restarts it twice.
            hud.cancelPendingSend(restartListening: false)
            // NOT marked heard here (ruled 10 Aug). Starting to record is not
            // answering: an agent stops waiting when a reply actually lands, or
            // when you press its lamp — never because you pressed the mic key
            // while it was talking. This used to mark heard first, which meant a
            // press that opened no microphone still took the session out of the
            // queue: green to empty, and the work gone from view with nothing to
            // show for it.
            //
            // The revert this used to defend against is now the correct outcome.
            // Stopping an announcement returns it to unread — which is exactly
            // what it should be, because you have not answered it yet. The reply
            // path advances the cursor on a confirmed send, so a delivered answer
            // still retires it.
            coordinator?.speech.stop()  // never record over playback
            lat("teardown done, opening mic")
            if armed != nil, recorder.isRecording {
                // The mic has been open since the arm window (eval E6: the
                // arm-window audio is already in the durable buffer, so
                // nothing said since the press can be lost). Attach the live
                // stream now — hold-resolution, exactly where it was created
                // before instant-arm — and it is fed the whole backlog.
                recorder.openStream()
                lat("stream opened over armed mic — "
                    + "\(Int(recorder.bufferedSeconds * 1000))ms already buffered, "
                    + "zero-loss window")
            } else {
                do {
                    try recorder.start()
                    lat("mic open")
                } catch {
                    // Route changes make this genuinely transient — say so and stop,
                    // rather than showing a Listening pill over a dead microphone.
                    Permissions.log("mic: start failed: \(error)")
                    dictationMode = false
                    recordingTarget = nil
                    hud.showResult(micFailureMessage(error))
                    return
                }
            }
            isBusy = true
            updateTitle()
            hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 })
            lat("pill rendered")

        case .replyEnded:
            isBusy = false
            hud.recordingEnded()
            guard let capture = try? recorder.stop() else {
                updateTitle()
                // The silence gate's event, one layer down: the device returned
                // so little that Recorder refused to hand it back. This printed
                // "Nothing recorded." over the grid whether you brushed the key
                // or held it for a minute against a dead microphone — the two
                // cases that most need telling apart, and the dead-mic one is
                // the reason this path exists at all.
                reportNothingHeard(because: "nothing recorded")
                return
            }
            updateTitle()
            sendReply(capture)

        case .replyAborted where handsFreeListening:
            // A stray key during locked listening is not an abort signal: nothing is
            // being held, so there is no gesture to have interfered with. Ignore.
            return

        case .replyAborted:
            // The hold turned out to be part of a real shortcut. Drop the audio
            // rather than transcribing whatever happened to be in the room.
            isBusy = false
            hud.recordingEnded()
            recorder.abandon()
            recordingTarget = nil
            dictationMode = false
            updateTitle()
            hud.endCapture(because: "reply aborted")
            showIdleGrid()
        }
    }

    /// Tap: play the next waiting update, then that session becomes the reply target.
    /// Announcements are strictly serialized: at most one exists at any moment, and
    /// a new one cannot begin until the previous one has fully finished.
    ///
    /// A boolean guard was not enough, and could not have been. Pressing again
    /// during the slow part cleared the flag and started a second announcement while
    /// the first was still in flight — so the flag said "one at a time" while two
    /// were running, and both eventually spoke. Two voices talking over each other
    /// is the single worst thing this app can do, so the guarantee has to be
    /// structural: hold the task, cancel it, and AWAIT it before starting anything.
    /// Nothing about timing or ordering is then left to chance.
    func announceNext(only eventId: String? = nil) {
        guard let coordinator else { return }
        // A new announcement supersedes any armed return-to-grid: the old
        // card's timer must never yank the fresh one off the stage.
        returnToGridWork?.cancel()
        let previous = announceTask
        // Summarizing and fetching the voice take several seconds. Without this the
        // app shows nothing at all for the whole of that and reads as broken.
        // A refusal means a reply flow owns the stage — and the voice obeys the
        // same table as the pixels, so nothing is announced either.
        guard hud.showPreparing() else {
            Permissions.log("announce: refused, reply flow on stage")
            return
        }
        announceTask = Task { @MainActor in
            // Silence the old one first, then wait for it to actually be over.
            coordinator.speech.stop()
            previous?.cancel()
            _ = await previous?.value

            defer { isAnnouncing = false }
            guard !Task.isCancelled else {
                Permissions.log("announce: cancelled before starting")
                return
            }
            isAnnouncing = true

            // Ingest the spool BEFORE selecting. Intake ran only on the 5-second
            // tick, and a human is faster than that: reply to a session, press to
            // hear the next thing, and the reply's user_prompt_submit was still
            // sitting in the spool — so the turn you had just answered played as if
            // nothing had happened. Measured: Stop at 08:38:09, spoken at 08:41:06,
            // the retiring reply landing the same second, five seconds too late.
            _ = try? coordinator.intake()

            // The emptiness check runs HERE, after Preparing has painted, with the
            // probe warmed off-main. It used to run before anything was shown, so a
            // press sat on a frozen panel for the length of a subprocess call and a
            // registered press looked exactly like a missed one.
            await Task.detached { _ = ClaudeAgentsCLI().sessions() }.value
            // Same overlay as the selection below, or this emptiness check
            // says "something is waiting" about the very turn we are about to
            // refuse to announce, and the grid never gets shown.
            //
            // Nothing unopened does NOT mean nothing to play (ruled 13 Aug):
            // anything green always plays. When every waiting row has been
            // opened, ⌃⌥ WALKS them — the next one after whatever it played
            // last, wrapping — through the explicit path a row tap uses.
            //
            // Two bugs on this keypress, in order. First it bounced to the
            // grid in silence, which read as a dead app (13 Aug 14:26). The
            // fix replayed `waiting().first`, which is the same row every
            // time, so ⌃⌥ welded itself to one session: five presses, five
            // `replaying 4394c0ec` (16 Aug 01:04). ⌃⌥ means "next", and it
            // has to mean that on the opened stack too.
            //
            // `lastReplayed` is the walk's only state and it is deliberately
            // in-memory: a restart should open at the top of the stack, not
            // resume a walk nobody remembers taking.
            var replayId: String?
            if eventId == nil,
               (try? coordinator.nextToAnnounce(excluding: self.delivering)) == nil {
                replayId = ((try? coordinator.nextToReplay(
                    after: self.lastReplayed, excluding: self.delivering)) ?? nil)?.sessionId
                guard let replayId else {
                    lastReplayed = nil
                    showIdleGrid()
                    return
                }
                lastReplayed = replayId
                Permissions.log("announce: all opened — replaying \(replayId.prefix(8))"
                    + " (walk)")
            } else {
                // A fresh unopened turn, or an explicitly named session, ends
                // the walk: the next ⌃⌥ over an all-opened stack starts from
                // the top rather than continuing a walk the user interrupted.
                lastReplayed = eventId
            }
            Permissions.log("announce: starting")
            do {
                // A tap is an explicit request to hear something, so the
                // interruptibility gate does not apply — you cannot interrupt
                // someone who just asked.
                let outcome = try await coordinator.announceNext(
                    only: eventId ?? replayId,
                    ignoringGate: true,
                    excluding: self.delivering,
                    onWillSpeak: { [weak self] announcement in
                        // Render BEFORE the audio starts. Showing it afterwards is
                        // useless — you have already heard the whole thing by then.
                        guard let self else { return false }
                        let live = (ClaudeAgentsCLI().sessions() ?? [])
                            .first { $0.sessionId == announcement.event.sessionId }
                        // One displayed identity (re-ruled 05 Aug): the terminal
                        // tab's own string. It is now the ONLY identity — the
                        // voice stopped speaking the callsign on 18 Aug, so the
                        // eye and the ear have nothing left to disagree about.
                        let name = self.tabDisplayName(for: announcement.event, live: live)
                        // The stage is claimed FIRST. Everything below records
                        // "this is the conversation you are in", and a refused
                        // announcement is not one — recording it anyway is how a
                        // turn nobody heard became the reply target.
                        guard self.hud.showAnnouncement(
                                    spoken: announcement.spoken,
                            sessionId: announcement.event.sessionId,
                            pid: live?.pid,
                            project: name,
                            cwd: announcement.event.cwd,
                            eventId: announcement.event.sessionId)
                        else {
                            Permissions.log("announce: stage refused, not speaking")
                            return false
                        }
                        self.activeConversation = (
                            announcement.event.sessionId,
                            name,
                            announcement.event.cwd)
                        self.lastAnnouncement = announcement
                        return true
                    },
                    onWord: { [weak self] range in
                        Task { @MainActor in
                            guard let self else { return }
                            self.hud.highlight(upTo: range.upperBound)
                            // First audio of the announcement is the moment the
                            // ladder becomes likely — and the moment the main
                            // fetch is provably done, so the two never compete
                            // for a narrow link. Rung 0 is FINDINGS, which is
                            // where essentially every walk opens.
                            guard let last = self.lastAnnouncement else { return }
                            self.warmNextRung(
                                after: 0,
                                token: "\(last.event.sessionId):\(last.event.latestId):main")
                        }
                    }
                )

                // A superseded announcement does not get to speak for the app.
                //
                // Everything below is REPORTING — a status line, a card, the grid.
                // None of it is bookkeeping: the cursor advance and the unread
                // revert both happen inside Coordinator.speak, before this returns.
                // So an announcement that has already been replaced has nothing it
                // needs to do here, and no right to do it — the stage belongs to
                // whatever replaced it.
                //
                // This rule already existed, applied at two of the five places that
                // needed it. The three that lacked it painted the grid over the
                // announcement that superseded them: 38 times in one day, twice
                // while the microphone was open (app.log, `speaking -> idle
                // (grid from announceNext(only:):1378)`). Stated once, above the
                // switch, no branch can be added that forgets it.
                guard !Task.isCancelled else {
                    Permissions.log("announce: superseded, not reporting")
                    return
                }

                switch outcome {
                case .spoke(let announcement):
                    Permissions.log("announce: spoke via \(announcement.via)")
                    if let degraded = announcement.degraded {
                        // Heard, but in the plainer voice. Say why, or an outage
                        // reads as the app just sounding worse for no reason.
                        hud.note("Read in the system voice. \(degraded)")
                    }
                    lastStatusLine = "\(StateLegend.Glyph.speaking) \(announcement.brief.topic)"
                    hud.highlight(upTo: announcement.spoken.text.count)
                    // The agent's page catches up here, off the main thread and
                    // after the audio: the brief for this turn has just been
                    // stored, so this is the first moment the page can be
                    // right, and nothing downstream waits on it. A failure is
                    // logged and dropped — a stale home base must never cost
                    // anyone an announcement.
                    let spokenSession = announcement.event.sessionId
                    Task.detached { [weak self] in
                        guard let store = await self?.store else { return }
                        do {
                            // Detached, so the GitHub lookups may block here —
                            // and this is the moment that makes the tapped
                            // door instant later.
                            if let file = try HomeBase.write(sessionId: spokenSession,
                                                             store: store,
                                                             priming: true) {
                                Permissions.log("homebase: \(file.lastPathComponent) "
                                                + "for \(spokenSession.prefix(8))")
                            }
                        } catch {
                            Permissions.log("homebase FAILED: \(error)")
                        }
                    }
                    // Ruling 14 reversed (12 Aug): fully spoken dwells. The card
                    // stays until a gesture moves it — the grid is one tap away,
                    // not four seconds away.
                case .interrupted(let failure):
                    if let failure {
                        // Nobody asked for this one. Say so, rather than letting a
                        // dropped connection masquerade as something you chose.
                        // A failure writes no cursor, so "still unread" is true.
                        lastStatusLine = "playback failed, still unread"
                        hud.showResult(
                            "Playback failed (\(failure)). It's still waiting. "
                            + "tap ⌃⌥ to hear it again.")
                    } else {
                        // No read-state claim here: stopping it yourself OPENS
                        // the turn (13 Aug), stopping it before any audio does
                        // not, and the grid's row weight now shows which one
                        // happened — copy that guessed would lie half the time.
                        lastStatusLine = "stopped"
                        showIdleGrid(note: "Stopped.")
                    }
                case .held(let reason):
                    lastStatusLine = "held: \(reason)"
                    showIdleGrid(note: "Holding. \(reason).")
                case .nothingWaiting:
                    Permissions.log("announce: nothingWaiting")
                    lastStatusLine = "nothing waiting"
                    showIdleGrid()
                }
            } catch {
                Permissions.log("announce: threw \(error)")
                lastStatusLine = "announce failed: \(error)"
            }
            rebuildMenu()
        }
    }
}
