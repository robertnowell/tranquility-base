import AppKit
import TranquilityCore

/// AppDelegate's remaining self-test drills -- slow-transcription
/// recovery and the instant-arm battery (docs/instant-arm.md) -- split
/// out of main.swift (App-lane P7, 24 Aug); see AppDelegate+Permissions.
/// swift's doc comment for why.

/// A tiny thread-safe counter for the selftest's stream-ask ledger.
final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

extension AppDelegate {
    // MARK: - Slow transcription (sanctioned change: open issue #4)

    /// Cancel from the transcribing panel: drop the attempt and return to idle.
    ///
    /// Two mechanisms, both needed: the generation bump guarantees the result is
    /// dropped (reply path) or its send cancelled (readyToSend) even if the
    /// attempt cannot stop; the task cancel actually STOPS it where it can — a
    /// cancelled upload unwinds in milliseconds instead of holding its rung's
    /// full timeout. The audio row was durable before the network was touched,
    /// so nothing is lost: the row lands failed-with-audio, which is exactly
    /// what the recent-audio pane's per-row retry recovers from.
    func cancelTranscription() {
        replyGeneration += 1
        inFlightTranscription?.task?.cancel()
        inFlightTranscription = nil
        recordingTarget = nil
        dictationMode = false
        lastStatusLine = "transcription cancelled, audio kept"
        Permissions.log("transcription: cancelled from the panel; audio is kept")
        // The user door out of the capture state — without it the arbiter would
        // refuse the idle repaint below and strand the panel.
        hud.endCapture(because: "transcription cancelled")
        showIdleGrid()
        rebuildMenu()
    }

    /// Retry from the transcribing panel: supersede the attempt on screen and run
    /// the SAME capture again, from the top of the chain.
    ///
    /// This button used to run the failed-rows sweep, which by construction could
    /// not touch the attempt the user was staring at — the 19 Aug 15:23 taps were
    /// received, re-transcribed some old clips, and changed nothing on screen.
    /// Now: the stalled attempt's result is disowned (generation), its network
    /// work told to stop (cancel), its row retired once it unwinds (so the
    /// recent-audio pane never grows a transcriptless twin), and a fresh attempt
    /// starts over the same audio with the same addressing. The re-entered
    /// transcribing face restarts the elapsed clock — the acknowledgment.
    func retryTranscriptionFromPanel() {
        guard let prior = inFlightTranscription else {
            // A stale tap as the face leaves, or a retry with nothing in
            // flight: sweep past failures, the one thing still worth doing.
            Permissions.log("transcription: retry with nothing in flight; sweeping failed rows")
            retryFailed()
            return
        }
        Permissions.log("transcription: retry from the panel — superseding "
            + "\(prior.utteranceId.prefix(8)) and rerunning the chain")
        replyGeneration += 1
        prior.task?.cancel()
        if let store, let superseded = prior.task {
            Task { @MainActor in
                _ = await superseded.value
                try? store.discardUtterance(id: prior.utteranceId,
                                            because: "superseded by the panel's retry")
            }
        }
        // Restore the addressing facts the superseded attempt consumed, so the
        // re-run resolves to the same session (or launch) the words were
        // spoken to — never a re-derivation (the HTML-button lesson).
        recordingTarget = prior.target
        recordingLaunch = prior.launch
        dictationMode = prior.dictation
        sendReply(prior.capture, isRetry: true)
    }

    func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Instant-arm selftest (docs/instant-arm.md, evals E2/E4/E5)

    /// Drives the arm window through the REAL handler — real recorder, real
    /// store — and asserts what the unit tests cannot: a tap after arming
    /// leaves zero durable residue (E2: no utterance row, no audio file, no
    /// stream session), the recorder is closed after every abort path (E4),
    /// and the grace-fire→render path stays within the latency budget (E5).
    func runArmSelftest() {
        guard micGranted else {
            Permissions.log("selftest-arm: SKIPPED — microphone not granted")
            return
        }
        guard let store else {
            Permissions.log("selftest-arm: SKIPPED — no store")
            return
        }
        func utteranceCount() -> Int { (try? store.utterances(limit: 10_000).count) ?? -1 }
        func audioFileCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(
                at: QueueStore.audioDirectory, includingPropertiesForKeys: nil).count) ?? -1
        }
        // Stream sessions are counted, not opened: a nil-returning factory
        // proves WHEN the app asks for a stream without touching the network.
        let originalFactory = recorder.streamFactory
        defer { recorder.streamFactory = originalFactory }
        let streamAsks = Counter()
        recorder.streamFactory = { streamAsks.increment(); return nil }

        let rowsBefore = utteranceCount()
        let filesBefore = audioFileCount()

        // A clean stage first: --selftest-hud's pendingSend drill leaves the
        // panel owning the stage, which would (correctly) refuse both the
        // idle repaint and the arming face and turn this into a test of the
        // wrong thing.
        hud.endCapture(because: "selftest-arm setup")

        // E5: the grace-fire→render path, timed directly. The handler's own
        // ordering (render BEFORE recorder.start) is the review-level half,
        // documented in docs/instant-arm.md.
        showIdleGrid()
        let renderStart = Date()
        hud.showArming(target: "selftest")
        let renderMs = Date().timeIntervalSince(renderStart) * 1000
        hud.revertArming(because: "selftest E5 timing")
        Permissions.log(String(format:
            "selftest-arm E5: grace-fire→render %.1fms (budget 30ms) %@",
            renderMs, renderMs <= 30 ? "PASS" : "FAIL"))

        // E2 + E4, abort from the visible grid: arm, then tap-abort.
        handle(.armWindowOpened(pressedAt: Date()))
        let armedOk = recorder.isRecording && hud.state.name == "arming"
        handle(.armAborted)
        let gridAbort = !recorder.isRecording && streamAsks.value == 0
        Permissions.log("selftest-arm abort[grid]: armed=\(armedOk) "
            + "micClosed=\(!recorder.isRecording) streams=\(streamAsks.value) "
            + "state=\(hud.state.name) \(armedOk && gridAbort ? "PASS" : "FAIL")")

        // Abort from hidden: arming surfaced the panel; the revert re-hides.
        hud.hide()
        handle(.armWindowOpened(pressedAt: Date()))
        let surfaced = hud.isOnScreen && hud.state.name == "arming"
        handle(.armAborted)
        let rehidden = !hud.isOnScreen && hud.state.name == "hidden"
            && !recorder.isRecording
        Permissions.log("selftest-arm abort[hidden]: surfaced=\(surfaced) "
            + "rehidden=\(rehidden) \(surfaced && rehidden ? "PASS" : "FAIL")")

        // E4's other abort leg: arm → hold resolves (upgrade) → replyAborted.
        // The stream ask here is EXPECTED — hold-resolution is where streams
        // have always been created; the abort still leaves no residue. The
        // reply is addressed to a synthetic conversation so the selftest can
        // never markHeard a REAL waiting session (prod-data guard).
        showIdleGrid()
        activeConversation = ("selftest-arm", "selftest-arm", nil)
        defer { activeConversation = nil }
        handle(.armWindowOpened(pressedAt: Date()))
        handle(.replyBegan)
        let upgraded = recorder.isRecording && streamAsks.value == 1
        handle(.replyAborted)
        let replyAbortClean = !recorder.isRecording
        Permissions.log("selftest-arm abort[upgrade]: upgraded=\(upgraded) "
            + "micClosed=\(replyAbortClean) "
            + "\(upgraded && replyAbortClean ? "PASS" : "FAIL")")

        // E2's ledger: nothing durable moved across any of the above.
        let rowsAfter = utteranceCount()
        let filesAfter = audioFileCount()
        let clean = rowsAfter == rowsBefore && filesAfter == filesBefore
        Permissions.log("selftest-arm E2: utteranceRows \(rowsBefore)→\(rowsAfter) "
            + "audioFiles \(filesBefore)→\(filesAfter) "
            + "\(clean ? "PASS" : "FAIL")")
        showIdleGrid()
    }
}
