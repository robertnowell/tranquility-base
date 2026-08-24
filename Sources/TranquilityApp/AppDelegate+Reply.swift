import AppKit
import CryptoKit
import TranquilityCore

/// AppDelegate's reply half -- dispatch, dismissal, the drop target, the
/// waiting badge -- split out of main.swift (App-lane P7, 24 Aug); see
/// AppDelegate+Permissions.swift's doc comment for why.

extension AppDelegate {
    /// Dispatch a transcript whose undo window has closed, and say exactly what
    /// happened. "Couldn't send it" hid a `try?` that swallowed the real outcome —
    /// including the one case that matters most, where the text may have landed but
    /// the read-back could not confirm it.
    func send(utteranceId: String, label: String, sessionId: String) {
        guard let coordinator else { return }
        let mine = replyGeneration
        Task { @MainActor in
            // The second half of the delivery window (see DeliveryInFlight):
            // the capture handed it to the countdown, the countdown handed it
            // here, and it closes on the outcome however that outcome reads.
            // Same discipline as the first half — one defer, not seven cases.
            defer { delivering.finished(sessionId: sessionId) }
            guard mine == replyGeneration else {
                // Superseded between the timer firing and this running.
                try? coordinator.cancelSend(utteranceId: utteranceId)
                return
            }
            // The countdown completing was the confirmation; a "Sending…" card
            // after it is a second wait the user already served. Ready comes back
            // immediately — you can talk again or move on while the dispatch and
            // its read-back verification run behind the scenes. Only repaint if
            // the stage is actually free: on a ⌃⌥ commit-and-advance the next
            // announcement is already preparing, and this must not stomp it.
            // The undo window closed, which is the moment the user CONFIRMED the
            // send. Ruled 18 Aug: "dispatch means turn done" — so this is the
            // closure cue, and it is the only falling figure in the set.
            Earcons.play(.dispatched, gate: earconGate())
            lastStatusLine = "sending to \(label)…"
            // The whisper (ruled 06 Aug): the words are on their way, said
            // without taking the stage from whatever is on it.
            hud.showReceipt(.sending(label))
            if hud.canSurfaceAmbiently {
                showIdleGrid()
            }
            // A dispatch that reaches any of the failure branches below (in the
            // switch or the catch) was typed at, or attempted against, a target
            // this app just talked to — `about`'s pid used to be structurally
            // absent (the tuple carried none), so GO TO AGENT could never grow
            // on a failure card even when the session was undeniably alive,
            // which is the ordinary case for `sessionNotReady`/
            // `verificationTimedOut`. One lookup, reused everywhere below;
            // naturally nil for the "tab is gone" branches, where nil is right.
            let pid = (ClaudeAgentsCLI().sessions() ?? [])
                .first(where: { $0.sessionId == sessionId })?.pid
            do {
                let outcome = try await coordinator.confirmAndSend(utteranceId: utteranceId)
                Permissions.log("confirmAndSend -> \(outcome)")
                // The confirm round-trip can outlive the user's attention: they may
                // already be listening to the NEXT session when this lands. The
                // stage arbiter handles that now — a success receipt asking to
                // paint over live speech or a capture is refused inside
                // showResult, and the REFUSED transition log is its receipt.
                // Failures always surface: they are the case with work left to do.
                switch outcome {
                // Success says nothing: the countdown already confirmed, the
                // status line and log carry the receipt, and a third card for a
                // thing that went right was indistinguishable noise (user report,
                // 05 Aug — "two further states, all saying different things").
                case .queued(_, _, let dispatchedPid):
                    hud.showReceipt(.queued)
                    lastStatusLine = "queued in \(label), sends when its turn finishes"
                    Permissions.log("send: queued in \(label)")
                    // A queued/dispatched reply can have gone through an
                    // ownership transfer (resumeTwin ends the hand-started
                    // process and resumes fresh under tmux) — the pid this
                    // outcome actually landed on is not necessarily the one
                    // the card was bound to when it was first shown. Syncs
                    // GO TO AGENT the same way `attachLivePid` already does
                    // for a revive that lands on a decision (found live, 23
                    // Aug: without this, the button kept pointing at the pid
                    // the transfer had just, on purpose, ended).
                    if let dispatchedPid {
                        hud.attachLivePid(dispatchedPid, sessionId: sessionId)
                    }
                case .dispatched(_, _, _, let dispatchedPid):
                    hud.showReceipt(.sent)
                    lastStatusLine = "sent to \(label)"
                    Permissions.log("send: confirmed to \(label)")
                    if let dispatchedPid {
                        hud.attachLivePid(dispatchedPid, sessionId: sessionId)
                    }
                case .sessionNotReady(let readiness):
                    // Sanctioned change (b): the actual condition in plain words,
                    // not the enum case's name. Mapping documented in
                    // StateLegend.plainWords(for:).
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult(
                        "\(label) can't take this yet, \(StateLegend.plainWords(for: readiness)). "
                        + "Your words are kept. Try again in a moment.",
                        about: (sessionId: sessionId, pid: pid, label: label))
                case .dispatchFailed(.verificationTimedOut, _):
                    // Documented as ambiguous and never auto-retried: only a human
                    // can decide whether to repeat themselves. That is needs-you.
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult(
                        "Typed it into \(label), but couldn't confirm it landed. "
                        + "Check the tab before repeating yourself.",
                        about: (sessionId: sessionId, pid: pid, label: label))
                case .dispatchFailed(.tabNotFound, let utteranceId),
                     .dispatchFailed(.targetGone, let utteranceId):
                    // The destination no longer exists — "kept" must mean usable,
                    // not archived. The words go to the clipboard, plainly said.
                    Earcons.play(.needsYou, gate: earconGate())
                    let copied = copyTranscriptToClipboard(utteranceId: utteranceId)
                    hud.showResult(
                        StateLegend.tabGoneRescueMessage(label: label, copied: copied),
                        about: (sessionId: sessionId, pid: pid, label: label))
                case .dispatchFailed(let failure, _):
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult("Couldn't type into \(label): \(failure). "
                                   + "Your words are kept.",
                                   about: (sessionId: sessionId, pid: pid, label: label))
                case .noTarget:
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult("That reply lost its agent. Your words are kept.",
                                   about: (sessionId: sessionId, pid: pid, label: label))
                default:
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult("Unexpected result: \(outcome). Your words are kept.",
                                   about: (sessionId: sessionId, pid: pid, label: label))
                }
            } catch {
                Permissions.log("confirmAndSend threw: \(error)")
                Earcons.play(.needsYou, gate: earconGate())
                hud.showResult("Send failed: \(error). Your words are kept.",
                               about: (sessionId: sessionId, pid: pid, label: label))
            }
            rebuildMenu()
        }
    }

    /// Dismiss whatever the panel is showing, through its latest event.
    func dismissCurrent(_ sessionId: String) {
        guard let coordinator else { return }
        guard let latest = try? coordinator.waiting().first(where: { $0.sessionId == sessionId })
        else { return }
        try? coordinator.dismiss(sessionId: sessionId, through: latest.latestId)
        Permissions.log("dismissed \(sessionId.prefix(8)) through event \(latest.latestId)")
    }

    /// Who the next reply would go to, resolved BEFORE the microphone opens.
    ///
    /// Every mic-opening path runs through this, for two reasons. First, the panel
    /// must name the session and terminal while you talk — addressing you cannot
    /// see is addressing you cannot check, and one misroute already proved it.
    /// Second, if there is no target, the honest move is refusing to record, not
    /// transcribing a reply in order to discover it has nowhere to go.
    func resolveReplyContext() -> (sessionId: String, pid: Int?, label: String, cwd: String?)? {
        if let conversation = activeConversation {
            // The session on screen or just replied to — your attention, which
            // outranks anything derived from cursors. Its label is already the
            // one identity (callsign-resolved when the announcement painted).
            let live = (ClaudeAgentsCLI().sessions() ?? [])
                .first(where: { $0.sessionId == conversation.sessionId })
            return (conversation.sessionId, live?.pid, conversation.label, conversation.cwd)
        }
        guard let target = try? coordinator?.replyTarget() ?? nil else { return nil }
        let live = (ClaudeAgentsCLI().sessions() ?? [])
            .first(where: { $0.sessionId == target.sessionId })
        // One displayed identity (re-ruled 05 Aug): the tab's string,
        // checkable at a glance — see tabDisplayName.
        let name = tabDisplayName(for: target, live: live)
        return (target.sessionId, live?.pid, name, target.cwd)
    }

    /// Recompute who a dropped file would go to.
    ///
    /// The same ladder `resolveReplyContext` walks — the conversation you are
    /// in, else the session that last spoke — minus the pid probe, which is a
    /// subprocess and which a staged file does not need. Deliberately the
    /// same ladder: a file must land where your voice would, or the panel is
    /// naming one destination and using another.
    func refreshDropTarget() {
        if let conversation = activeConversation {
            dropTarget = (conversation.sessionId, conversation.label)
            return
        }
        guard let target = try? coordinator?.replyTarget() ?? nil else {
            dropTarget = nil
            return
        }
        dropTarget = (target.sessionId, target.callsign ?? target.projectLabel)
    }

    /// A dragged image with no file behind it, written somewhere durable.
    ///
    /// Content-hashed rather than timestamped: dropping the same screenshot
    /// twice is one chip and one file, and a session that reads the path
    /// later finds the bytes it was told about. Beside the audio archive,
    /// under app support — a temp dir would be swept out from under a
    /// session that had not read it yet.
    static func persistDroppedImage(_ data: Data, ext: String) -> String? {
        let dir = QueueStore.supportDirectory.appendingPathComponent("dropped",
                                                                     isDirectory: true)
        try? PrivateStorage.createDirectory(at: dir)
        let digest = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }
            .joined().prefix(16)
        let url = dir.appendingPathComponent("drop-\(digest).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            Permissions.log("drop: write failed — \(error)")
            return nil
        }
    }

    /// The badge, from the same predicate a keypress uses.
    func waitingNow() -> Int { (try? coordinator?.waitingCount()) ?? 0 }
}
