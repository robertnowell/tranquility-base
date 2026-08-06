import AppKit
import VoiceDispatchCore

/// The floating panel in the top-right corner.
///
/// This is the actual interface. The menu bar was never enough — on a full menu bar
/// macOS silently drops status items, and even when visible it can't show which
/// session is talking or what was said. Without this the app is a voice with no face:
/// you hear something, and have no way to see what it was, which session it came
/// from, or how to get there.
///
/// Non-activating: it takes no focus from whatever you're working in, so it can
/// appear mid-typing without stealing a keystroke.
///
/// It never auto-hides. The first version dismissed the idle state after four
/// seconds, which meant the only evidence the app was alive flashed up and vanished
/// before anyone looked at it — indistinguishable, again, from the app being broken.
/// A status indicator that disappears is not a status indicator. It stays until
/// superseded by the next state or explicitly dismissed.
@MainActor
final class StatusHUD: NSObject {
    private var panel: NSPanel?
    private var titleLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var stateLabel: NSTextField!
    private var goButton: NSButton!
    private var replyButton: NSButton!
    private var hintLabel: NSTextField!
    /// Set by the app so the panel can start and stop a recording itself. Without
    /// this the only way to answer was a hotkey that appears nowhere in the UI —
    /// the panel asked a question and offered no way to answer it.
    var onReply: (() -> Void)?
    var onStopReply: (() -> Void)?
    /// KEPT deliberately (WS-C would otherwise delete it): a recording started from
    /// the panel's Reply button does NOT enter `.listening` — the panel stays on the
    /// announcement, only the button title and hint change — so the enum genuinely
    /// lacks this fact. Folding button-recording into the state machine would change
    /// what is on screen, which is out of bounds for a structure pass.
    private var isRecording = false
    private var hideWorkItem: DispatchWorkItem?
    private var contentStack: NSStackView?
    private var identity: String?
    /// Derived, not stored. True exactly while the undo countdown is live AND the
    /// panel is in `.pendingSend` — the two facts the old boolean tracked by hand.
    /// Entering any other state makes it false (the state entry points used to
    /// clear the flag); the timer dying makes it false (commit, cancel, fire, or
    /// Dismiss all invalidate it). The countdown itself may keep running across a
    /// state change — that is open issue #8's undecided behavior, preserved as-is.
    private var awaitingConfirm: Bool { countdownTimer != nil && state.isPendingSend }
    private var meterTimer: Timer?
    private var levelSource: (() -> Float)?
    /// Where dictation will land ("→ Terminal", "→ clipboard"), probed at mic-open
    /// so the pill names the real destination, not the fallback.
    var dictationDestination: String?
    /// The event the panel is currently about, so Dismiss can retire it.
    private(set) var currentEventId: String?
    private var countdownTimer: Timer?
    private var onCancelSend: ((_ restartListening: Bool) -> Void)?
    private var onCommitSend: (() -> Void)?
    private var progressBar: NSProgressIndicator!
    private var meter: LevelMeterView!
    private var discardButton: NSButton!
    private var sendCheckButton: NSButton!
    private var voicePicker: NSPopUpButton!
    private var gearButton: NSButton!
    private var backButton: NSButton!
    private var waitingRows: NSStackView!
    var onPickWaiting: ((String) -> Void)?
    private var actionRow: NSStackView!
    private static let spokenMark = NSAttributedString.Key("vdSpoken")

    private var currentTarget: (sessionId: String, pid: Int?, label: String)?

    // MARK: - Public surface

    /// While you are talking, the panel's whole job is to prove it can hear you.
    ///
    /// It previously showed the same identity line, the same "hold ⌥ to speak" hint
    /// you were already obeying, and three buttons for actions unrelated to
    /// speaking. A live level meter answers the only question you actually have.
    /// A deep link hands the panel its session before the mic opens, so Listening
    /// can show who the reply is addressed to.
    func adoptTarget(sessionId: String, pid: Int?, label: String, cwd: String?) {
        currentTarget = (sessionId, pid, label)
        currentEventId = sessionId
        identity = Self.identify(pid: pid, cwd: cwd)
    }

    func showListening(level: @escaping () -> Float, handsFree: Bool = false) {
        guard transition(to: .listening(eventId: currentEventId), because: "recording started")
        else { return }
        levelSource = level
        // A pill: target name plus waveform, nothing else. Hands-free flanks the
        // waveform with ✕ and ✓, so the controls sit where your eyes already are.
        // The name stays (unlike Wispr) because our destination is a terminal
        // somewhere else, not the focused field on this screen.
        face = Face(listeningTarget: currentTarget?.label ?? dictationDestination
                        ?? StateLegend.clipboardDestination,
                    handsFree: handsFree)
        render()
    }

    /// RMS for speech is small, so it is square-rooted and scaled. The old factor of
    /// 3.2 pinned the bar at full for ordinary talking, which reads as clipping and
    /// makes you drop your voice to compensate; 2.0 leaves normal speech around
    /// two-thirds and keeps headroom visible.
    nonisolated private static func meterFraction(_ level: Float) -> Double {
        min(1, sqrt(max(0, Double(level))) * 2.0)
    }

    func showAnnouncement(
        isCatchUp: Bool = false,
        topic: String, spoken: String, sessionId: String, pid: Int?, project: String,
        cwd: String?, eventId: String? = nil,
        placard: String? = nil
    ) {
        currentEventId = eventId
        currentTarget = (sessionId, pid, project)
        // Only prefix when the topic adds something. A topic equal to the project
        // rendered as "promotions — promotions", which names the folder twice and
        // tells you nothing.
        let headline = topic.caseInsensitiveCompare(project) == .orderedSame || topic.isEmpty
            ? project : "\(project): \(topic)"
        identity = Self.identify(pid: pid, cwd: cwd)
        guard transition(to: .speaking(eventId: eventId, catchUp: isCatchUp),
                         because: "audio starting")
        else { return }
        // Into the fresh Face, never before it: the wholesale rebuild is what
        // clears a previous pull's placard on ordinary announcements.
        face = Face(title: headline, body: spoken, placardOverride: placard ?? "")
        render()
    }

    /// The concrete tab this is about: working directory and tty. Without it you
    /// cannot tell whether "Go to session" opened the right one — a project name is
    /// not an address, and several tabs share it.
    private static func identify(pid: Int?, cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let parts = URL(fileURLWithPath: cwd).pathComponents.filter { $0 != "/" }

        // Worktrees nest the real name under .claude/worktrees/<name>/<project>, so
        // the last component alone is ambiguous — every one of them ends in the same
        // project directory. The component before the plumbing is the one you named.
        if let marker = parts.firstIndex(of: "worktrees"), marker + 1 < parts.count {
            return "worktree: \(parts[marker + 1])"
        }
        return parts.suffix(2).joined(separator: "/")
    }

    /// The first reply to a session asks once, showing the words that are about to
    /// be typed and the tab they are going into. Approving here enrols it, so this
    /// appears once per session and never again.
    var onConfirmSend: (() -> Void)?

    /// Show what is about to be typed, and send it when the bar runs out.
    ///
    /// The bar is the whole design. A dialog asking permission taxes every correct
    /// transcript to catch the occasional wrong one; a countdown reverses that —
    /// doing nothing is doing the right thing, and stopping it costs one click on
    /// the rare occasion you need to.
    func showPendingSend(
        text: String, label: String, seconds: TimeInterval,
        send: @escaping () -> Void, cancel: @escaping (_ restartListening: Bool) -> Void
    ) {
        countdownTimer?.invalidate()
        // Transition first so a refused stage never arms the countdown. Safe for
        // `awaitingConfirm` (the old reason for the reversed order): it derives
        // from the countdown timer, which is invalidated above, so render() still
        // paints without the countdown chrome either way.
        guard transition(to: .pendingSend(utteranceId: ""), because: "undo window open")
        else { return }
        onCancelSend = cancel
        onCommitSend = send
        face = Face(title: "Your reply", body: "\u{201C}\(text)\u{201D}",
                    sendingLabel: label, countdownSeconds: seconds)
        render()
    }

    /// Fast-forward the undo window: fire the send NOW instead of at the bar's
    /// end. ⌃⌥ during the countdown means "yes, send it, and move on" — the press
    /// is momentum, not doubt; doubt is what Don't send and ⌃⇧ are for.
    @discardableResult
    func commitPendingSendNow() -> Bool {
        guard awaitingConfirm else { return false }
        countdownTimer?.invalidate(); countdownTimer = nil
        progressBar.isHidden = true
        let send = onCommitSend
        onCommitSend = nil; onCancelSend = nil
        // Committing is an explicit act: the send is out of your hands, so the
        // stage is yielded — the advance that follows may paint immediately
        // instead of being refused by a pendingSend that is already over.
        forceTransition(to: .idle(waiting: 0), because: "send committed")
        send?()
        return true
    }

    /// Stop a pending send. Safe to call when nothing is pending.
    ///
    /// `restartListening` is false when the caller is already starting a new
    /// recording of its own — holding ⌥ during the window is itself the instruction
    /// to say it again, so restarting from here as well would double-start.
    @discardableResult
    func cancelPendingSend(restartListening: Bool = true) -> Bool {
        guard awaitingConfirm else { return false }
        countdownTimer?.invalidate(); countdownTimer = nil
        progressBar.isHidden = true
        let cancel = onCancelSend
        onCancelSend = nil
        cancel?(restartListening)
        return true
    }

    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated private func cancelPendingSendTapped() {
        MainActor.assumeIsolated { cancelPendingSend(restartListening: true) }
    }

    /// Reflect a pause without rebuilding the panel — the spoken text and its
    /// highlight must stay exactly where they are.
    func setPaused(_ paused: Bool) {
        stateLabel.stringValue = StateLegend.row(for: paused ? .paused : .speaking).stateText
        hintLabel.stringValue = paused
            ? StateLegend.pausedHint
            : (identity.map { "\($0)\n\(StateLegend.speakingHint)" }
                ?? StateLegend.speakingHint)
    }

    /// Append a line to the current panel without disturbing what it is showing.
    func note(_ message: String) {
        hintLabel.stringValue = [message, hintLabel.stringValue]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if let panel { resizeToFit(panel); position(panel) }
    }

    /// Settings, in the same panel rather than a second window.
    ///
    /// One setting today. It lives here because the panel is already the place you
    /// look, and a preferences window for a single dropdown is furniture.
    var onChooseVoice: ((String) -> Void)?

    func showSettings(voices: [Voice], selected: String, previewNote: String) {
        guard transition(to: .settings, because: "settings opened") else { return }
        currentTarget = nil; identity = nil
        face = Face(title: "Voice", body: previewNote,
                    voices: voices, selectedVoice: selected)
        render()
    }

    var voicePickerItemCount: Int { voicePicker.numberOfItems }
    var backButtonHidden: Bool { backButton.isHidden }
    var gearHidden: Bool { gearButton.isHidden }
    var actionRowHidden: Bool { actionRow.isHidden }
    var voicePickerSelection: String? { voicePicker.selectedItem?.title }

    @objc nonisolated private func voicePicked() {
        MainActor.assumeIsolated {
            guard let id = voicePicker.selectedItem?.representedObject as? String else { return }
            onChooseVoice?(id)
        }
    }

    func showWorking(_ message: String) {
        guard transition(to: .transcribing(startedAt: Date()), because: "working")
        else { return }
        // One identity: the callsign-carrying target label, or no title at all.
        // The app's own name belongs only to the true empty state.
        face = Face(title: currentTarget?.label ?? "", body: message)
        render()
    }

    // MARK: - Transcription progress (sanctioned change: open issue #4)

    private var transcribingTimer: Timer?
    private var cancelTranscriptionButton: NSButton!
    private var retryTranscriptionButton: NSButton!

    /// Working, but with the clock visible. A 27-second transcription once sat on
    /// "Transcribing your reply…" with no feedback at all and read as a hang
    /// (open issue #4). The elapsed count proves the app is alive; past 20s it says
    /// the one thing worth saying — the audio is already durable on disk, a promise
    /// that was always true and just unstated — and offers Cancel and Retry.
    func showTranscribing(_ message: String,
                          onCancel: @escaping () -> Void,
                          onRetry: @escaping () -> Void) {
        guard transition(to: .transcribing(startedAt: Date()),
                         because: "transcription started")
        else { return }
        face = Face(title: currentTarget?.label ?? "", body: message,
                    transcription: (cancel: onCancel, retry: onRetry))
        render()
    }

    /// Every paint funnels through render(), which calls this, so the ticker and
    /// its buttons can never outlive the transcribing panel. Also the explicit
    /// teardown leg of endCapture(), which does not paint.
    private func endTranscribingUI() {
        transcribingTimer?.invalidate()
        transcribingTimer = nil
        cancelTranscriptionButton?.isHidden = true
        retryTranscriptionButton?.isHidden = true
    }

    @objc nonisolated private func cancelTranscriptionTapped() {
        MainActor.assumeIsolated { face.transcription?.cancel() }
    }

    @objc nonisolated private func retryTranscriptionTapped() {
        MainActor.assumeIsolated { face.transcription?.retry() }
    }

    /// A receipt, not a state you live in.
    ///
    /// A success needs nothing from you, so it says what happened and gets out of
    /// the way. "It's mid-turn, so it sends when that finishes" is worth a few
    /// seconds because it is not something you could otherwise know, but leaving it
    /// on screen with buttons implies there is something left to do. A failure is
    /// the opposite and stays until dismissed.
    func showResult(_ message: String, ok: Bool) {
        // A refused success receipt is the quiet-success path: the stage is busy
        // with something newer, the send still happened, and the log carries the
        // REFUSED line as its receipt.
        guard transition(to: .result(ok: ok), because: "reply resolved") else { return }
        // Reply and Go to session are about the announcement, not the receipt, and
        // offering them here suggests the send is still in your hands. It is not.
        currentTarget = ok ? nil : currentTarget
        // One identity: a success receipt needs no title (the pill and body say
        // it); a failure is titled by the session it is about, in its callsign.
        face = Face(title: ok ? "" : (currentTarget?.label ?? ""), body: message)
        render()
    }

    /// `note` is a prefix about what just happened ("Stopped."). The sentence about
    /// what is waiting is always derived from `waiting`, never passed in — the two
    /// were computed at different call sites and drifted, so the panel showed
    /// "2 waiting" directly above "Nothing waiting".
    /// True when the panel is showing the passive idle state and nothing else.
    ///
    /// Used to decide whether an arriving turn may refresh the panel underneath. It
    /// must never redraw over speech, a recording, a countdown or a failure notice:
    /// those are conversations in progress, and a background update that interrupts
    /// one is worse than a stale count.
    private(set) var state: PanelState = .hidden

    /// The only way state changes — and now the only place legality is decided.
    /// Every transition is logged, which is the whole point: when the panel gets
    /// stuck, the log says exactly which state it is in and what put it there.
    ///
    /// A refused transition returns false and the caller must not paint: a stale
    /// async resume (an interrupted announce waking after the gesture that killed
    /// it) used to repaint idle over a live microphone, and every guard written
    /// against that at a call site was one more place to be wrong. The legality
    /// lives in `PanelState.admits`, in one table.
    @discardableResult
    private func transition(to next: PanelState, because reason: String) -> Bool {
        guard state.admits(next) else {
            Permissions.log("state: REFUSED \(state.name) -> \(next.name)  (\(reason))")
            return false
        }
        if next != state {
            Permissions.log("state: \(state.name) -> \(next.name)  (\(reason))")
            state = next
        }
        return true
    }

    /// The user's door. Explicit actions (Dismiss, hiding the panel, committing a
    /// send) are never stale, so they bypass the table — but they announce it.
    private func forceTransition(to next: PanelState, because reason: String) {
        guard next != state else { return }
        Permissions.log("state: \(state.name) -> \(next.name)  (\(reason), user door)")
        state = next
    }

    /// Tear down a capture state for real before leaving it. The legality table
    /// refuses stale repaints over listening/transcribing/pendingSend; a person
    /// dismissing is not stale — but leaving without this is how a reply got lost:
    /// the panel hid mid-countdown and the send was never cancelled on the record
    /// (app.log 2026-08-05T18:27:59Z).
    func endCapture(because reason: String) {
        guard state.ownsStage else { return }
        if awaitingConfirm {
            cancelPendingSend(restartListening: false)
        } else {
            countdownTimer?.invalidate(); countdownTimer = nil
            onCommitSend = nil; onCancelSend = nil
        }
        meterTimer?.invalidate(); meterTimer = nil
        endTranscribingUI()
        // Yield the stage so whatever the caller paints next is admitted; the
        // state value is interim and the caller's repaint replaces it at once.
        forceTransition(to: .idle(waiting: 0), because: reason)
        Permissions.log("capture: ended (\(reason))")
    }

    /// The idle face IS the grid (WS-B, ruled): one row per live session,
    /// callsign + lamp + short topic. Row tap invites that session. The old
    /// count-pill and hint text are gone as the default face; the app's own name
    /// and a one-line hint survive only in the true empty state (no sessions).
    func showIdle(note: String? = nil, rows: [StateLegend.SessionRow]) {
        // The transition that used to stomp a live listening pill (an interrupted
        // announce resuming after the gesture that killed it). Now the table
        // refuses it and this returns without painting.
        let waiting = rows.filter { $0.lamp == .ready }.count
        guard transition(to: .idle(waiting: waiting), because: "idle repaint")
        else { return }
        currentTarget = nil; currentEventId = nil; identity = nil

        if rows.isEmpty {
            // The true empty state — the ONLY surface where the literal app name
            // appears, with the one-line hint.
            face = Face(title: "Voice Dispatch",
                        body: [note, "Nothing waiting. Sessions appear here as they finish."]
                            .compactMap { $0 }.joined(separator: " "))
        } else {
            // No "N waiting" headline (ruled): the strip says SESSIONS, the lamps
            // say who is waiting, and the count lives in the menu bar.
            face = Face(body: note ?? "", sessionRows: rows)
        }
        render()
    }

    /// True when the panel is visible and doing something worth stopping. Escape is
    /// a key with a job in every terminal app, so it only acts here when there is
    /// speech, a countdown, or a recording to interrupt.
    var isBusyOnScreen: Bool {
        guard panel?.isVisible == true else { return false }
        return state.acceptsEscape
    }

    var isCapturingAudio: Bool { state.isCapturingAudio }
    var canStartReply: Bool { state.canStartReply }

    /// Same path as the Dismiss button, so both can never drift apart.
    func dismiss() { dismissTapped() }

    func hide() {
        // Hidden still allows ambient surfacing, which is the property that broke
        // when this left a non-idle flag behind: after one Dismiss the app went
        // silent for the rest of the session.
        // The user door: hiding is always an explicit act (Dismiss, the result
        // auto-hide, quit), never a stale resume — so it bypasses the table.
        forceTransition(to: .hidden, because: "panel hidden")
        currentTarget = nil; currentEventId = nil; identity = nil
        render()
    }

    /// Whether an arriving turn may raise the panel right now.
    ///
    /// Anything mid-conversation says no: speech, a recording, a send countdown, or
    /// a failure still waiting to be read. Everything else, hidden included, is a
    /// moment where showing up is welcome rather than an interruption.
    var canSurfaceAmbiently: Bool { state.allowsAmbientSurface }

    var isOnScreen: Bool { panel?.isVisible ?? false }

    // MARK: - Rendering

    /// What the current state is about — the strings and closures PanelState
    /// deliberately does not carry. Stashed whole by each show* entry point;
    /// state + face is render()'s entire input.
    private struct Face {
        var title = "", body = "", listeningTarget = ""
        /// Names the ladder rung on the state pill ("◀ FINDINGS") while a ⌃⌃
        /// pull speaks — the visual identifier for what KIND of thing is being
        /// said. Empty = the state's own placard.
        var placardOverride = ""
        var handsFree = false
        var sendingLabel = ""
        var countdownSeconds: TimeInterval = 0
        var sessionRows: [StateLegend.SessionRow] = []
        var voices: [Voice] = []
        var selectedVoice = ""
        var transcription: (cancel: () -> Void, retry: () -> Void)?
    }
    private var face = Face()

    /// The pill/controls row for the current state, where one exists. `hidden`
    /// has no face; the associated labels (listening target, send destination)
    /// come from the stashed face, which is why this lives here and not on
    /// PanelState.
    private func situation() -> StateLegend.Situation? {
        switch state {
        case .hidden: return nil
        // Idle is Ready whether or not the grid has rows: the pill states the
        // APP's condition; each session's condition is its row's lamp. The old
        // clickable count pill is dead — the grid is already open.
        case .idle: return .ready
        case .preparing: return .preparing
        case .speaking(_, let catchUp): return catchUp ? .catchingUp : .speaking
        case .paused: return .paused
        case .listening: return .listening(target: face.listeningTarget)
        case .transcribing: return .working
        case .pendingSend: return .sendingTo(label: face.sendingLabel)
        case .result(let ok): return ok ? .sent : .needsYou
        case .settings: return .settings
        }
    }

    /// The one place pixels and timers derive from state. Every show* entry point
    /// is stash-payload → transition(to:) → render(); nothing else paints.
    ///
    /// Two passes over the widgets, both inside this function: the baseline pass
    /// writes EVERY widget from state + face before any arm runs, and the switch
    /// then states only what its state owns. Nothing a previous state showed can
    /// survive into this one — the residue class of bug (a countdown bar on the
    /// Speaking card, meter dots on Ready) is unrepresentable, because a widget
    /// no arm mentions is at its baseline, not left over.
    private func render() {
        // The leaving state's machinery dies here, in one place: the auto-hide,
        // the transcription ticker, and (outside a live capture) the meter.
        // The countdown TIMER is deliberately not stopped here (open issue #8:
        // the paths that end a pending send — commit, cancel, endCapture, its own
        // expiry — say so themselves); only its pixels are, in the baseline.
        hideWorkItem?.cancel()
        endTranscribingUI()
        if !state.isCapturingAudio { meterTimer?.invalidate(); meterTimer = nil }
        if case .hidden = state { panel?.orderOut(nil); return }
        let panel = panel ?? build()

        // Baseline: pill and action row from the state's legend row, title and
        // body from the stash, Reply / Go to session from who the panel is
        // addressing, everything stateful off. Go to session stays available
        // while listening — knowing which terminal your words are about to land
        // in is exactly when you want to check.
        let row = situation().map { StateLegend.row(for: $0) }
        stateLabel.stringValue = face.placardOverride.isEmpty
            ? (row?.stateText ?? "") : face.placardOverride
        stateLabel.isHidden = false
        // A title exists exactly when the face carries one; an empty label still
        // reserves a line's height, which reads as a hole.
        titleLabel.stringValue = face.title; titleLabel.isHidden = face.title.isEmpty
        bodyLabel.stringValue = face.body
        hintLabel.stringValue = currentActionHint()
        actionRow.isHidden = !(row?.showsControls ?? false)
        replyButton.title = awaitingConfirm ? "Don't send"
            : (isRecording || state.isCapturingAudio ? "Send now" : "Reply")
        replyButton.isHidden = !awaitingConfirm && currentTarget == nil
        goButton.isHidden = currentTarget?.pid == nil
        progressBar.isHidden = true; meter.isHidden = true
        discardButton.isHidden = true; sendCheckButton.isHidden = true
        voicePicker.isHidden = true; waitingRows.isHidden = true
        gearButton.isHidden = false; backButton.isHidden = true
        // Part of the baseline so the grid's monospaced key line can never leak
        // into another state's hint — a font no arm mentions is at its baseline.
        hintLabel.font = .systemFont(ofSize: 10)
        // Unhidden only by the slow-transcription tick, never by a state's arm.
        cancelTranscriptionButton.isHidden = true; retryTranscriptionButton.isHidden = true
        var autoHide: TimeInterval?

        switch state {
        case .hidden, .preparing, .speaking, .transcribing:
            break

        case .idle where !face.sessionRows.isEmpty:
            // The grid: the idle face IS one row per live session (WS-B, ruled).
            // Ruled strip: a small letterspaced SESSIONS placard where the Ready
            // pill would be — no "Ready", no "N waiting" (the count lives in the
            // menu bar) — and the key line where the Dismiss button was: every
            // gesture the grid answers to, in the panel's monospaced small type.
            // Tracking 3.2 (was 1.6): the accepted draft's strip is airier —
            // "A G E N T S" — and the title got shorter, so it can afford it.
            stateLabel.attributedStringValue = letterspaced(
                StateLegend.gridStripTitle, size: 10, tracking: 3.2,
                color: StateLegend.Lens.chrome.color)
            hintLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
            hintLabel.stringValue = StateLegend.gridHint
            actionRow.isHidden = true
            waitingRows.isHidden = false
            rebuildSessionRows()

        case .idle:
            // True empty state: the baseline already says everything — the app
            // name as title and the one-line hint as body.
            break

        case .paused:
            // Never entered today — setPaused() patches the speaking face in
            // place so the highlight cannot move. Rendered honestly for the day
            // a transition lands here.
            hintLabel.stringValue = identity.map { "\($0)\n\(StateLegend.pausedHint)" }
                ?? StateLegend.pausedHint

        case .listening:
            titleLabel.isHidden = true
            hintLabel.stringValue = ""
            // ✕ is ALWAYS visible while the mic is open (re-ruled 06 Aug): a
            // recording escapable only by keyboard trapped the user for minutes
            // when the event tap died — an open microphone must carry its own
            // off-switch. ✓ stays hands-free-only; push-to-talk sends on release.
            discardButton.isHidden = false
            sendCheckButton.isHidden = !face.handsFree
            meter.isHidden = false

        case .pendingSend:
            replyButton.title = "Don't send"; replyButton.isHidden = false
            progressBar.isHidden = false

        case .result(let ok):
            // A success needs nothing from you, so it says what happened and gets
            // out of the way. A failure stays until dismissed.
            autoHide = ok ? 6 : nil

        case .settings:
            stateLabel.stringValue = ""
            hintLabel.stringValue = ""
            gearButton.isHidden = true; backButton.isHidden = false
            voicePicker.isHidden = false
            populateVoicePicker()
        }

        Permissions.log("HUD.render state=\(state.name) title=\(titleLabel.stringValue)")
        resizeToFit(panel)
        position(panel)
        panel.orderFrontRegardless()
        Permissions.log("HUD frame=\(panel.frame) visible=\(panel.isVisible) screen=\(NSScreen.main?.visibleFrame.debugDescription ?? "nil")")

        // Which timer runs is a fact of the state, decided in the same breath as
        // its pixels.
        switch state {
        case .listening:
            meter.reset()
            meterTimer?.invalidate()
            // 20Hz: fast enough that the waveform tracks syllables rather than words.
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
                guard let self, self.state.isCapturingAudio else { return timer.invalidate() }
                self.meter.push(CGFloat(Self.meterFraction(self.levelSource?() ?? 0)))
            }
            RunLoop.main.add(timer, forMode: .common); meterTimer = timer

        case .transcribing:
            // The elapsed ticker only when the entry point offered a way out
            // (showTranscribing); showWorking's brief notices tick nothing.
            guard face.transcription != nil else { break }
            // The elapsed count reads from the state's own startedAt, so the pill
            // can never disagree with the transition log about when this began.
            // The hidden cancel button doubles as the surfaced-once latch.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                guard let self, case .transcribing(let startedAt) = self.state else {
                    return timer.invalidate()
                }
                let seconds = Int(Date().timeIntervalSince(startedAt))
                self.stateLabel.stringValue =
                    StateLegend.row(for: .workingFor(seconds: seconds)).stateText
                guard seconds >= Int(StateLegend.slowTranscriptionThreshold),
                      self.cancelTranscriptionButton.isHidden else { return }
                self.cancelTranscriptionButton.isHidden = false
                self.retryTranscriptionButton.isHidden = false
                self.note(StateLegend.slowTranscriptionNote)
                Permissions.log("transcribing: slow (\(seconds)s), surfaced cancel/retry")
            }
            RunLoop.main.add(timer, forMode: .common); transcribingTimer = timer

        case .pendingSend:
            progressBar.doubleValue = 0
            let (seconds, send, started) = (face.countdownSeconds, onCommitSend, Date())
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                let elapsed = Date().timeIntervalSince(started)
                self.progressBar.doubleValue = min(elapsed / seconds, 1) * 100
                guard elapsed >= seconds else { return }
                timer.invalidate()
                self.countdownTimer = nil
                self.progressBar.isHidden = true
                // The bar running out IS the confirmation — the contract completed
                // exactly as displayed, so the stage is yielded before the dispatch
                // work begins. The caller repaints ready; only a failure comes back.
                self.forceTransition(to: .idle(waiting: 0), because: "countdown completed")
                send?()
            }
            // .common so the countdown keeps running while a menu or drag is
            // tracking — otherwise it silently stalls and the reply never goes.
            RunLoop.main.add(timer, forMode: .common); countdownTimer = timer

        default:
            break
        }

        if let autoHide {
            // The hide belongs to THIS render: the only identity that matters is
            // the state itself — if the panel has moved on by the time it fires,
            // the hide is stale and does nothing. Checking the real fact beats
            // counting generations.
            let scheduledFor = state
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == scheduledFor else { return }
                self.hide()
            }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    /// The grid's content width: the 380 panel minus the stack's 14pt insets.
    private static let gridWidth: CGFloat = 352

    /// The ruled grid (draft variant C, ruled 05 Aug): 26px lamp, then the
    /// session NAME (the tab's string) owning the row, the minted callsign
    /// right-aligned in the remaining ≤38% — at a fixed 40px height, a
    /// hairline rule between rows (none after the last), capped at 8. Below
    /// the rows: a quiet "+ NEW SESSION" placard, then the strong rule above
    /// the key line. Tap = invite that session. Fixed height plus single-line
    /// labels is what kills the orphan fragments and ragged gaps the old
    /// free-height attributed-title rows produced.
    private func rebuildSessionRows() {
        waitingRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        waitingRows.spacing = 0

        func hairline(_ color: NSColor) -> NSView {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = color.cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            line.widthAnchor.constraint(equalToConstant: Self.gridWidth).isActive = true
            return line
        }

        // The strip's bottom rule, under "AGENTS ⚙".
        waitingRows.addArrangedSubview(hairline(StateLegend.Palette.hairline))
        let shown = Array(face.sessionRows.prefix(8))
        // ONE callsign column (ruled 05 Aug): sized to the widest callsign on
        // show, capped at 38% of the grid. Per-row widths made every name
        // truncate at its own x and the right side read as a rag, not a
        // column; a shared width gives one vertical boundary, callsigns
        // right-aligned into it, names truncating against it.
        let auxWidth = min(
            Self.gridWidth * GridRowView.auxFraction,
            shown.map {
                ceil(($0.callsign as NSString)
                    .size(withAttributes: [.font: GridRowView.auxFont]).width)
            }.max() ?? 0)
        for (index, item) in shown.enumerated() {
            let row = GridRowView(item: item, auxWidth: auxWidth, target: self,
                                  action: #selector(sessionRowTapped(_:)))
            waitingRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.gridWidth).isActive = true
            if index < shown.count - 1 {
                waitingRows.addArrangedSubview(hairline(StateLegend.Palette.hairlineSoft))
            }
        }
        // The proactive half (ruled 05 Aug addendum): the "+" placard kicks off
        // a fresh session — same code path as the menu item.
        waitingRows.addArrangedSubview(hairline(StateLegend.Palette.hairlineSoft))
        let newRow = PlacardRowView(target: self, action: #selector(newSessionRowTapped))
        waitingRows.addArrangedSubview(newRow)
        newRow.widthAnchor.constraint(equalToConstant: Self.gridWidth).isActive = true
        // The key line's top rule; the hint label follows in the outer stack.
        waitingRows.addArrangedSubview(hairline(StateLegend.Palette.hairline))

        // The layout self-check: geometry is ruled, so the log states it — and
        // singleLine proves the labels can never recreate the orphan fragments
        // ("**Voices for lif") between rows.
        let ready = shown.filter { $0.lamp == .ready }.count
        let singleLine = shown.allSatisfy {
            !$0.name.contains("\n") && !$0.callsign.contains("\n")
        }
        Permissions.log("grid: \(shown.count) rows (\(ready) ready) "
            + "rowH=\(Int(GridRowView.height)) "
            + "cols=\(Int(GridRowView.lampColumn))/flex/aux\(Int(auxWidth)) "
            + "lamps=circular singleLine=\(singleLine)")
    }

    /// Wired by the app onto SessionLauncher.launch().
    var onNewSession: (() -> Void)?

    @objc nonisolated private func newSessionRowTapped() {
        MainActor.assumeIsolated { onNewSession?() }
    }

    private func populateVoicePicker() {
        voicePicker.removeAllItems()
        for group in ["cloned", "generated", "professional", "premade"] {
            let inGroup = face.voices.filter { $0.category == group }.sorted { $0.name < $1.name }
            guard !inGroup.isEmpty else { continue }
            voicePicker.menu?.addItem(.separator())
            let header = NSMenuItem(title: group.capitalized, action: nil, keyEquivalent: "")
            header.isEnabled = false
            voicePicker.menu?.addItem(header)
            for voice in inGroup {
                let item = NSMenuItem(title: voice.name, action: nil, keyEquivalent: "")
                item.representedObject = voice.id
                voicePicker.menu?.addItem(item)
            }
        }
        if let match = voicePicker.menu?.items.first(where: {
            ($0.representedObject as? String) == face.selectedVoice
        }) {
            voicePicker.select(match)
        }
    }

    /// The hint line for the current flags, identity-prefixed. One derivation over
    /// StateLegend.actionHint, so show() and replyTapped() cannot drift apart —
    /// the chain used to be pasted verbatim in both.
    private func currentActionHint() -> String {
        let action = StateLegend.actionHint(
            isListening: state.isCapturingAudio,
            awaitingConfirm: awaitingConfirm,
            hasTarget: currentTarget != nil,
            isRecording: isRecording)
        return identity.map { "\($0)\n\(action)" } ?? action
    }

    /// Grow the window to whatever the content needs.
    ///
    /// The first version pinned the panel at 150pt regardless of what was in it, so
    /// a long summary pushed the buttons off the bottom edge — the actions were
    /// literally unreachable. Never ship a fixed-height container around
    /// variable-length text.
    private func resizeToFit(_ panel: NSPanel) {
        guard let stack = contentStack else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let needed = stack.fittingSize
        let height = max(needed.height, 90)
        if abs(panel.frame.height - height) > 1 {
            panel.setContentSize(NSSize(width: 380, height: height))
        }
        // Assert the actions are actually on screen. "Buttons cut off" is a bug the
        // code can check for itself; it should never reach a person's eyes.
        let buttonsFit = panel.contentView.map { $0.bounds.height + 0.5 >= needed.height } ?? false

        // Does the label actually show all of its text? Comparing the rendered
        // height to the text's natural height at this width is the only way to
        // see truncation from code — the panel happily fits a clipped label, so
        // the previous check passed while four lines of every summary were lost.
        let width = bodyLabel.bounds.width
        let natural = (bodyLabel.stringValue as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyLabel.font ?? .systemFont(ofSize: 12)]).height
        let textFits = bodyLabel.bounds.height + 1 >= natural

        // Frames live in each view's own superview, and the header is a nested
        // stack, so comparing raw minX values across rows compares nothing. Convert
        // into the panel's space before drawing any conclusion about alignment.
        if let root = panel.contentView {
            func box(_ v: NSView) -> NSRect { v.convert(v.bounds, to: root) }
            Permissions.log(
                "HUD chrome: state.x=\(Int(box(stateLabel).minX)) "
                + "title.x=\(Int(box(titleLabel).minX)) body.x=\(Int(box(bodyLabel).minX)) "
                + "gear.maxX=\(Int(box(gearButton).maxX)) panelW=\(Int(panel.frame.width)) "
                + "rightMargin=\(Int(panel.frame.width - box(gearButton).maxX))")
        }
        Permissions.log(
            "HUD layout: needed=\(Int(needed.height)) frame=\(Int(panel.frame.height)) "
            + "buttonsFit=\(buttonsFit) textFits=\(textFits) "
            + "labelH=\(Int(bodyLabel.bounds.height)) naturalH=\(Int(natural))")
    }

    /// Shown the instant ⌃⌥ is tapped, so the gap before audio isn't dead air.
    /// Summarizing and fetching the voice take a few seconds; without this the app
    /// looks broken for the whole of it.
    /// A visible pulse the instant a gesture registers.
    ///
    /// The gap between pressing and anything happening is where the app feels
    /// broken: summarizing takes seconds, and with no acknowledgment a registered
    /// press and a missed press look identical, so you press again — which is how
    /// every double-trigger bug this weekend started. The pulse says "heard you"
    /// before any work begins.
    /// Our own overlay layer, not the NSVisualEffectView's.
    ///
    /// The first version set a border on the effect view's backing layer and
    /// nothing appeared: that layer is privately managed and does not render
    /// externally-set borders reliably. A plain CALayer we own, sitting above the
    /// content, has no such opinions.
    private var ackLayer: CALayer?

    func flashAcknowledge() {
        guard let host = panel?.contentView, let hostLayer = host.layer else { return }
        if panel?.isVisible != true { panel?.orderFrontRegardless() }

        let layer: CALayer
        if let existing = ackLayer {
            layer = existing
        } else {
            layer = CALayer()
            // Palette, not controlAccentColor: accent = state, not user
            // preference (ruled) — the pulse is the same green as the go lamp.
            layer.borderColor = StateLegend.Palette.ready.cgColor
            layer.borderWidth = 3
            layer.cornerRadius = 12
            layer.opacity = 0
            hostLayer.addSublayer(layer)
            ackLayer = layer
        }
        layer.frame = host.bounds

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.0
        pulse.duration = 0.4
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.removeAnimation(forKey: "ack")
        layer.add(pulse, forKey: "ack")
        Permissions.log("ack: pulsed (visible=\(panel?.isVisible == true))")
    }

    /// Returns false when the stage refused (a reply flow is live) — the caller
    /// must not announce, or the audio would play against a panel that never
    /// changed. Pixels and voice obey the same table.
    @discardableResult
    func showPreparing() -> Bool {
        guard transition(to: .preparing, because: "announce requested") else { return false }
        // One identity: no app-name masthead — the Preparing pill and the body
        // carry it. The callsign arrives with the announcement itself.
        face = Face(body: "Writing the summary and fetching the voice…")
        render()
        return true
    }

    /// Prove a pending send can be stopped for its whole life.
    ///
    /// It could not: the flag was inferred from the state text, the text changed,
    /// and cancelling silently became a no-op. Asserted here rather than trusted.
    func selfTestPendingSend() {
        var sent = false
        var cancelled = false
        currentTarget = ("selftest", 1, "promotions")
        showPendingSend(text: "words that should never be sent", label: "promotions",
                        seconds: 4, send: { sent = true }, cancel: { _ in cancelled = true })

        let cancellable = cancelPendingSend(restartListening: false)
        Permissions.log("selftest pendingSend: cancellable=\(cancellable) "
                        + "cancelled=\(cancelled) sent=\(sent)")

        // And it must stay stopped: the timer should be dead, not merely ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Permissions.log("selftest pendingSend: after the window, sent=\(sent)")
        }
    }

    /// Render every state with worst-case text and confirm nothing is clipped.
    /// Run with `--selftest-hud`.
    func selfTest() {
        let long = String(repeating: "Product image binding is fixed across the stack. ", count: 8)
        currentTarget = ("selftest", 1, "promotions")
        // The exact path that drew past the panel edge.
        identity = Self.identify(
            pid: 1,
            cwd: NSHomeDirectory()
                + "/Projects/kopi/promotions/.claude/worktrees/"
                + "product-image-binding-oracle/promotions")
        Permissions.log("selftest identity=\(identity ?? "nil")")
        for (label, block) in [
            ("idle", { self.showIdle(note: long, rows: []) }),
            // The idle grid: mixed lamps, a long name, a worst-case callsign,
            // and rows not yet minted (empty right column).
            ("idleGrid", { self.showIdle(rows: [
                .init(id: "a", name: "Fix hero image binding across the stack",
                      callsign: "promotions copy", lamp: .ready),
                .init(id: "b", name: long, callsign: "syndit citation", lamp: .running),
                .init(id: "c", name: "voice dispatch", callsign: "", lamp: .ready),
                .init(id: "d", name: "robertnowell-83",
                      callsign: "voice-dispatch synchronization",
                      lamp: .running),
            ]) }),
            ("preparing", { _ = self.showPreparing() }),
            ("announcement", { self.showAnnouncement(
                topic: "Product image binding fix validation", spoken: long,
                sessionId: "s", pid: 1, project: "promotions", cwd: "/tmp/promotions") }),
            ("listening", {
                var t = 0.0
                self.showListening(level: {
                    t += 0.05
                    return Float(0.25 + 0.25 * sin(t * 6))  // something speech-shaped
                })
                // Fill the history so the drawing path runs against real geometry.
                for i in 0..<80 { self.meter.push(CGFloat(0.2 + 0.6 * abs(sin(Double(i) / 4)))) }
                self.panel?.contentView?.layoutSubtreeIfNeeded()
                Permissions.log(
                    "meter frame=\(self.meter.frame) hidden=\(self.meter.isHidden) style=centred")
            }),
            // The full reply flow, in its real order, so every capture state's
            // matrix is on the record: transcribing, the undo window, then both
            // receipt flavors.
            ("working", { self.showTranscribing("Transcribing your reply…",
                                                onCancel: {}, onRetry: {}) }),
            ("pendingSend", { self.showPendingSend(
                text: "words that should never be sent", label: "promotions",
                seconds: 60, send: {}, cancel: { _ in }) }),
            ("result", { _ = self.cancelPendingSend(restartListening: false)
                         self.showResult(long, ok: false) }),
            ("resultOk", { self.showResult("Sent.", ok: true) }),
            ("settings", {
                self.showSettings(
                    voices: [Voice(id: "a", name: "Archer", category: "professional"),
                             Voice(id: "b", name: "My Clone", category: "cloned"),
                             Voice(id: "c", name: "Sarah", category: "premade")],
                    selected: "c",
                    previewNote: "Pick a voice and it reads your most recent summary.")
                self.panel?.contentView?.layoutSubtreeIfNeeded()
                Permissions.log("settings chrome: picker=\(self.voicePickerItemCount) "
                                + "back=\(!self.backButtonHidden) gear=\(!self.gearHidden) "
                                + "actions=\(!self.actionRowHidden) "
                                + "selected=\(self.voicePickerSelection ?? "nil")")
            }),
        ] as [(String, () -> Void)] {
            Permissions.log("selftest state=\(label)")
            block()
            Permissions.log("selftest matrix \(label): \(widgetMatrix())")
        }

        // The stomp that froze the app (2026-08-05): a stale idle repaint against a
        // live capture. Must be REFUSED, and the pill must still be on the walls.
        showListening(level: { 0.4 })
        showIdle(rows: [.init(id: "a", name: "promotions copy", callsign: "", lamp: .ready),
                        .init(id: "b", name: "syndit", callsign: "", lamp: .ready)])
        let survived = state.isCapturingAudio && !meter.isHidden
        Permissions.log("selftest legality: idle-over-listening refused=\(survived) "
                        + "state=\(state.name)")
        recordingEnded()
        // Through the user door, exactly as a real abort must go — showIdle alone
        // is (correctly) refused from a capture state.
        endCapture(because: "selftest cleanup")
        showIdle(rows: [])
    }

    // MARK: - Pose driver (dev tooling)

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
        let catchUpSpoken = "Syndit citation. While you were away, the daily "
            + "thread posted with the featured report cited in every reply. "
            + "Queue tomorrow's rotation?"
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
        func announce(catchUp: Bool = false, project: String, topic: String,
                      spoken text: String, highlightFraction: Double,
                      cwd: String = NSHomeDirectory() + "/Projects/kopi/promotions") {
            showAnnouncement(isCatchUp: catchUp, topic: topic, spoken: text,
                             sessionId: "pose", pid: 1, project: project, cwd: cwd)
            highlight(upTo: Int(Double(text.count) * highlightFraction))
        }
        // A mid-level frozen waveform: speech-shaped, never pinned at full.
        func seedMeter() {
            for i in 0..<80 { meter.push(CGFloat(0.18 + 0.42 * abs(sin(Double(i) / 3.2)))) }
        }

        switch name {
        case "grid":
            showIdle(rows: [
                .init(id: "s1", name: "Validate hero image binding",
                      callsign: "promotions copy", lamp: .ready),
                .init(id: "s2", name: "Render pose driver states",
                      callsign: "voice-dispatch recording", lamp: .ready),
                .init(id: "s3", name: "Cite featured report in daily thread",
                      callsign: "syndit citation", lamp: .running),
                .init(id: "s4", name: "Green the hybrid retrieval eval",
                      callsign: "recall dense", lamp: .running),
                .init(id: "s5", name: "Ship Track A provenance fix",
                      callsign: "bookmarks provenance", lamp: .running),
                .init(id: "s6", name: "Stage footer flag migration",
                      callsign: "kopi footer", lamp: .running),
                .init(id: "s7", name: "Ship Shopify-only filter",
                      callsign: "m3-tracker poller", lamp: .running),
                .init(id: "s8", name: "Draft personality prompt criteria",
                      callsign: "live-hud director", lamp: .running),
            ])

        case "empty":
            showIdle(rows: [])

        case "preparing":
            _ = showPreparing()

        case "speaking":
            announce(project: callsign, topic: "Hero image binding fix",
                     spoken: spoken, highlightFraction: 0.6)

        case "catchup":
            announce(catchUp: true, project: "syndit citation",
                     topic: "Daily thread citations",
                     spoken: catchUpSpoken, highlightFraction: 0.6,
                     cwd: NSHomeDirectory() + "/Projects/syndit")

        case "paused":
            announce(project: callsign, topic: "Hero image binding fix",
                     spoken: spoken, highlightFraction: 0.6)
            setPaused(true)

        case "depth1":
            // Exactly the ⌃⌃ path: the same announcement card, the rationale as
            // the spoken text, karaoke highlight and all (main.swift wires it
            // identically via showAnnouncement).
            announce(project: callsign, topic: "Hero image binding fix",
                     spoken: rationale, highlightFraction: 0.4)

        case "listening", "handsfree":
            adopt()
            showListening(level: { 0.35 }, handsFree: name == "handsfree")
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
            note(StateLegend.slowTranscriptionNote)

        case "readback":
            adopt()
            showPendingSend(
                text: "Ship the Shopify-only filter and rerun the poller",
                label: callsign, seconds: 8, send: {}, cancel: { _ in })
            // Frozen mid-window: 40% elapsed, so ~60% of the bar remains.
            progressBar.doubleValue = 40

        case "sent":
            showResult("Sent.", ok: true)

        case "needsyou":
            adopt()
            showResult("promotions copy's tab is gone — copied your words to the clipboard.",
                       ok: false)

        case "settings":
            showSettings(
                voices: [Voice(id: "a", name: "Archer", category: "professional"),
                         Voice(id: "b", name: "My Clone", category: "cloned"),
                         Voice(id: "c", name: "Sarah", category: "premade"),
                         Voice(id: "d", name: "River", category: "premade")],
                selected: "c",
                previewNote: "Pick a voice and it reads your most recent summary.")

        default:
            return false
        }

        // Freeze: a pose is a photograph, not a running instrument. Everything
        // that would advance the picture dies here; the pixels it already
        // painted stay. (The countdown's own pixels were re-set above.)
        meterTimer?.invalidate(); meterTimer = nil
        transcribingTimer?.invalidate(); transcribingTimer = nil
        countdownTimer?.invalidate(); countdownTimer = nil
        hideWorkItem?.cancel(); hideWorkItem = nil

        // The capture harness reads this one line: the panel frame in AppKit's
        // bottom-left origin, the full screen frame to convert with, and the
        // window number (the CGWindowID `screencapture -l` takes — window-id
        // capture is immune to overlays that pollute a region capture).
        Permissions.log("pose: \(name) frame=\(panel?.frame ?? .zero) "
                        + "screenFrame=\(NSScreen.main?.frame ?? .zero) "
                        + "window=\(panel?.windowNumber ?? -1)")
        return true
    }

    /// Every widget's visibility in one line, so the selftest log IS the render
    /// contract: diff two runs and any residue names itself.
    private func widgetMatrix() -> String {
        let widgets: [(String, NSView?)] = [
            ("title", titleLabel), ("body", bodyLabel), ("state", stateLabel),
            ("hint", hintLabel), ("bar", progressBar), ("meter", meter),
            ("actions", actionRow), ("reply", replyButton), ("go", goButton),
            ("discard", discardButton), ("check", sendCheckButton), ("picker", voicePicker),
            ("gear", gearButton), ("back", backButton), ("rows", waitingRows),
            ("cancelTx", cancelTranscriptionButton),
            ("retryTx", retryTranscriptionButton),
        ]
        return widgets.map { "\($0.0)=\($0.1?.isHidden == false ? "1" : "0")" }
            .joined(separator: " ")
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 16
        let size = panel.frame.size
        // Top-right, below the menu bar.
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - size.width - margin,
            y: screen.visibleFrame.maxY - size.height - margin)
        panel.setFrameOrigin(origin)
    }

    private func build() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            // .nonactivatingPanel is the key flag: the panel can show without the app
            // becoming frontmost, so it never steals a keystroke mid-sentence.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        // NSWindow defaults isReleasedWhenClosed to true, which predates ARC: closing
        // the window performs a manual release while `panel` still holds a strong
        // reference. The result is an over-release, and the panel's content — the
        // buttons among it — becomes freed memory that AppKit still hands mouse
        // events to. Clicking Reply then crashed inside the executor check on a
        // garbage object pointer, taking the window with it.
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The surface is an opaque light console on every face (ruled): AppKit's
        // own chrome — bezels, the picker, the progress bar — must render for a
        // light surface even when the system is in dark mode, or a dark-mode
        // bezel sits on light putty looking like a hole.
        panel.appearance = NSAppearance(named: .aqua)

        // Opaque light console surface, panel-wide (ruled — the blur is dead: an
        // instrument guarantees its own contrast, a blur borrowed the desktop's).
        // Same corner radius, shadow, and non-activating behavior as before.
        let background = NSView(frame: panel.contentView!.bounds)
        background.autoresizingMask = [.width, .height]
        background.wantsLayer = true
        background.layer?.backgroundColor = StateLegend.Palette.surface.cgColor
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        // Widgets carry no initial visibility: build() is only reached from
        // render(), which writes every widget's visibility before the panel is
        // ever ordered front.
        stateLabel = NSTextField(labelWithString: "")
        stateLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        stateLabel.textColor = StateLegend.Lens.chrome.color

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = StateLegend.Lens.content.color
        titleLabel.lineBreakMode = .byTruncatingTail

        bodyLabel = NSTextField(wrappingLabelWithString: "")
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = StateLegend.Lens.content.color
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.isSelectable = true

        // The action row's five buttons share one style.
        func rounded(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            return button
        }
        goButton = rounded("Go to session", #selector(goToSession))
        replyButton = rounded("Reply", #selector(replyTapped))
        replyButton.keyEquivalent = "\r"

        // A real symbol at a real size. The text glyph was 12pt — visually timid
        // and, worse, a hit target well under the ~24pt a fingertip-sized control
        // needs even for a mouse.
        gearButton = NSButton(image: NSImage(systemSymbolName: "gearshape",
                                             accessibilityDescription: "Settings")!
                                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))!,
                              target: self, action: #selector(gearTapped))
        gearButton.isBordered = false
        gearButton.contentTintColor = StateLegend.Lens.chrome.color
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        gearButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        gearButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        // A breadcrumb, not a button in a row of actions: it says where you are and
        // the only way out is back the way you came.
        backButton = NSButton(title: StateLegend.backTitle, target: self, action: #selector(backTapped))
        backButton.isBordered = false
        backButton.controlSize = .small
        backButton.font = .systemFont(ofSize: 11, weight: .medium)
        backButton.contentTintColor = StateLegend.Lens.chrome.color

        let dismiss = rounded("Dismiss", #selector(dismissTapped))
        // Surfaced only once a transcription has run long enough to deserve them
        // (sanctioned change: open issue #4). Styled exactly like their row-mates.
        cancelTranscriptionButton = rounded(StateLegend.cancelTranscriptionTitle,
                                            #selector(cancelTranscriptionTapped))
        retryTranscriptionButton = rounded(StateLegend.retryTranscriptionTitle,
                                           #selector(retryTranscriptionTapped))

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = StateLegend.Lens.guidance.color

        let buttons = NSStackView(views: [replyButton, goButton,
                                          cancelTranscriptionButton,
                                          retryTranscriptionButton, dismiss])
        actionRow = buttons
        buttons.orientation = .horizontal
        buttons.spacing = 8

        hintLabel.maximumNumberOfLines = 0
        hintLabel.lineBreakMode = .byTruncatingMiddle
        progressBar = NSProgressIndicator()
        progressBar.isIndeterminate = false
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.controlSize = .small

        meter = LevelMeterView()

        discardButton = NSButton(title: StateLegend.Glyph.discard, target: self, action: #selector(dismissTapped))
        discardButton.isBordered = false
        discardButton.font = .systemFont(ofSize: 15, weight: .medium)
        discardButton.contentTintColor = StateLegend.Lens.chrome.color

        sendCheckButton = NSButton(title: StateLegend.Glyph.confirm, target: self, action: #selector(checkTapped))
        sendCheckButton.isBordered = false
        sendCheckButton.font = .systemFont(ofSize: 15, weight: .semibold)
        sendCheckButton.contentTintColor = StateLegend.Lens.action.color

        voicePicker = NSPopUpButton()
        voicePicker.controlSize = .small
        voicePicker.font = .systemFont(ofSize: 11)
        voicePicker.target = self
        voicePicker.action = #selector(voicePicked)

        waitingRows = NSStackView()
        waitingRows.orientation = .vertical
        waitingRows.alignment = .leading
        waitingRows.spacing = 2

        let stack = NSStackView(views: [backButton, stateLabel, titleLabel,
                                        waitingRows, bodyLabel,
                                        progressBar, meter, voicePicker, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        background.addSubview(gearButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            bodyLabel.widthAnchor.constraint(equalToConstant: 348),
            hintLabel.widthAnchor.constraint(equalToConstant: 348),
            titleLabel.widthAnchor.constraint(equalToConstant: 348),
            stateLabel.widthAnchor.constraint(equalToConstant: 348),
            // Same margin as every text row, so the eye reads one column.
            gearButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            gearButton.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),
            meter.widthAnchor.constraint(equalToConstant: 348),
            meter.heightAnchor.constraint(equalToConstant: 28),
        ])
        self.contentStack = stack

        panel.contentView = background
        self.panel = panel
        return panel
    }

    // MARK: - Actions

    /// Bring the originating terminal tab to the front.
    ///
    /// Same addressing chain the dispatcher uses — pid to tty to tab — so "go to
    /// session" lands on exactly the tab a reply would be typed into, rather than
    /// merely activating Terminal and leaving you to find it.
    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated private func goToSession() {
        MainActor.assumeIsolated {
            guard let pid = currentTarget?.pid else {
                bodyLabel.stringValue = "That session is no longer running, so there's no tab to open."
                return
            }
            guard let tty = ProcessProbe.tty(of: pid) else {
                bodyLabel.stringValue = "Couldn't find a terminal for process \(pid). It may have exited."
                Permissions.log("goToSession: no tty for pid \(pid)")
                return
            }
            let script = """
                tell application "Terminal"
                  activate
                  repeat with w in windows
                    repeat with t in tabs of w
                      if (tty of t) as text is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        return "ok"
                      end if
                    end repeat
                  end repeat
                  return "notfound"
                end tell
                """
            switch AppleScript.run(script: script) {
            case .success(let out) where out.contains("notfound"):
                bodyLabel.stringValue = "That session's tab isn't open in Terminal any more (\(tty))."
                Permissions.log("goToSession: tab not found for \(tty)")
            case .success:
                Permissions.log("goToSession: focused \(tty)")
            case .failure(let error):
                bodyLabel.stringValue = "Couldn't control Terminal: \(error.message)"
                Permissions.log("goToSession FAILED: \(error.message)")
            }
        }
    }

    /// Advance the highlight to the character range currently being spoken.
    ///
    /// Everything up to the cursor is shown at full strength and the rest dimmed, so
    /// the eye can follow the voice without the jitter of a per-word box.
    func highlight(upTo index: Int) {
        guard let body = bodyLabel?.stringValue, !body.isEmpty else {
            Permissions.log("highlight upTo=\(index) SKIPPED: no body text")
            return
        }
        Permissions.log("highlight upTo=\(index) of \(body.count) thread=\(Thread.isMainThread)")
        let clamped = max(0, min(index, body.count))
        let attributed = NSMutableAttributedString(string: body)
        let full = NSRange(location: 0, length: (body as NSString).length)
        attributed.addAttribute(
            .foregroundColor,
            value: StateLegend.Palette.ink.withAlphaComponent(0.35), range: full)
        let spokenRange = NSRange(location: 0, length: min(clamped, full.length))
        attributed.addAttribute(.foregroundColor, value: StateLegend.Palette.ink,
                                range: spokenRange)
        attributed.addAttribute(Self.spokenMark, value: true, range: spokenRange)
        attributed.addAttribute(
            .font, value: NSFont.systemFont(ofSize: 12), range: full)
        bodyLabel.attributedStringValue = attributed

        var bright = 0
        bodyLabel.attributedStringValue.enumerateAttribute(Self.spokenMark, in: full) { value, range, _ in
            if value != nil { bright += range.length }
        }
        Permissions.log("highlight rendered bright=\(bright)/\(full.length)")
    }

    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated private func replyTapped() {
        MainActor.assumeIsolated {
            if awaitingConfirm {
                cancelPendingSendTapped()
                return
            }
            if isRecording { isRecording = false; onStopReply?() }
            else { isRecording = true; onReply?() }
            replyButton.title = isRecording ? "Send reply" : "Reply"
            hintLabel.stringValue = currentActionHint()
        }
    }

    func recordingEnded() {
        dictationDestination = nil
        isRecording = false
        meterTimer?.invalidate(); meterTimer = nil
        meter?.isHidden = true
        replyButton?.title = "Reply"
    }

    /// Set by the app so Dismiss can silence the voice, not just hide the panel.
    var onDismiss: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onLeaveSettings: (() -> Void)?

    @objc nonisolated private func checkTapped() {
        MainActor.assumeIsolated {
            if isRecording { isRecording = false }
            onStopReply?()
        }
    }

    @objc nonisolated private func gearTapped() {
        MainActor.assumeIsolated { onOpenSettings?() }
    }

    // The separate waiting-list face is gone (WS-B): the idle grid IS the list,
    // so showWaitingList/onOpenWaitingList and the clickable count pill went
    // with it — one face, not two near-identical lists.

    @objc nonisolated private func sessionRowTapped(_ sender: NSControl) {
        MainActor.assumeIsolated {
            guard let id = sender.identifier?.rawValue else { return }
            onPickWaiting?(id)
        }
    }

    @objc nonisolated private func backTapped() {
        MainActor.assumeIsolated {
            // Leaving settings stops whatever the preview was saying. Walking away
            // from a screen should not leave its sound running.
            onLeaveSettings?()
        }
    }

    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated private func dismissTapped() {
        MainActor.assumeIsolated {
            // Through the capture teardown, not around it: raw timer invalidation
            // here once dropped a mid-countdown send with no record of the cancel.
            endCapture(because: "dismissed")
            onDismiss?()
            hide()
        }
    }
}

/// Small uppercase letterspaced type — the SESSIONS strip (10px, +0.16em) and
/// the NEW SESSION placard (9.5px, +0.14em) share it.
@MainActor
private func letterspaced(_ text: String, size: CGFloat, tracking: CGFloat,
                          color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size),
        .kern: tracking,
        .foregroundColor: color,
    ])
}

/// One grid row, in the ruled three-column geometry: a 26px lamp column, a
/// 148px callsign column, and the topic in whatever remains — at a fixed 31px
/// height with single-line tail-truncating labels, so a row can never be taller
/// or shorter than its neighbors and no text fragment can wrap between rows.
///
/// A control with real frames, not a bezel-less NSButton: an attributed title
/// can only flow its runs inline, and columns need columns. Hover paints the
/// row in the palette's hover putty, exactly like the mock.
private final class GridRowView: NSControl {
    // Variant C metrics (ruled 05 Aug, from the accepted draft render, scaled
    // from its 640px frame to the panel's 352): taller rows, the name in the
    // larger mono with NO added tracking, the callsign right-aligned and
    // muted. The fixed 148px name column is dead — the name owns the row up
    // to the shared callsign column (`auxWidth`, measured by the grid over
    // every shown row, capped at `auxFraction`), so all names truncate at ONE
    // vertical boundary instead of each row's own rag.
    static let height: CGFloat = 40
    // 26 → 20 (ruled 05 Aug): the 17pt lamp-to-name gap read as dead air at
    // the new row height; 11pt keeps the lamp clear of the type and hands the
    // difference to the name column.
    static let lampColumn: CGFloat = 20
    static let auxFraction: CGFloat = 0.38
    static let auxFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(item: StateLegend.SessionRow, auxWidth: CGFloat,
         target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        identifier = NSUserInterfaceItemIdentifier(item.id)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let ready = item.lamp == .ready

        // The lamp: a 9px CIRCLE (ruled — squares read as checkboxes), flat
        // fill, no gradients or shadows. Quiet lamps get the hairline ring.
        let lamp = NSView()
        lamp.translatesAutoresizingMaskIntoConstraints = false
        lamp.wantsLayer = true
        lamp.layer?.backgroundColor = item.lamp.fill.cgColor
        lamp.layer?.cornerRadius = StateLegend.Lamp.diameter / 2
        if let ring = item.lamp.ring {
            lamp.layer?.borderWidth = 1
            lamp.layer?.borderColor = ring.cgColor
        }

        // The type ramp: both columns monospaced (one family, two sizes — the
        // callsign is an identity, not prose), semibold name only when ready.
        let name = NSTextField(labelWithString: item.name)
        name.font = .monospacedSystemFont(ofSize: 13, weight: ready ? .semibold : .medium)
        name.textColor = StateLegend.Palette.ink
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let callsign = NSTextField(labelWithString: item.callsign)
        callsign.font = Self.auxFont
        callsign.textColor = ready ? StateLegend.Palette.secondary : StateLegend.Palette.muted
        callsign.lineBreakMode = .byTruncatingTail
        callsign.alignment = .right
        callsign.translatesAutoresizingMaskIntoConstraints = false

        addSubview(lamp); addSubview(name); addSubview(callsign)
        // A grid with no minted callsigns collapses the column entirely —
        // no phantom 12pt gutter on the right.
        let gutter: CGFloat = auxWidth > 0 ? 12 : 0
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            lamp.widthAnchor.constraint(equalToConstant: StateLegend.Lamp.diameter),
            lamp.heightAnchor.constraint(equalToConstant: StateLegend.Lamp.diameter),
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor),
            lamp.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: Self.lampColumn),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: callsign.leadingAnchor,
                                           constant: -gutter),
            callsign.trailingAnchor.constraint(equalTo: trailingAnchor),
            callsign.centerYAnchor.constraint(equalTo: centerYAnchor),
            callsign.widthAnchor.constraint(equalToConstant: auxWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = StateLegend.Palette.hover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    // A cell-less NSControl tracks nothing by default; the whole row is the
    // hit target, and the tap lands on mouse-up like any button's would.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }
}

/// The "+ NEW SESSION" placard: a quiet 28px row — the plus glyph in the lamp
/// column, the label letterspaced and faint. A placard, not a bordered button:
/// it invites without competing with the lamps for attention.
private final class PlacardRowView: NSControl {
    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let plus = NSTextField(labelWithString: "+")
        plus.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        plus.textColor = StateLegend.Palette.faint
        plus.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = letterspaced(
            StateLegend.newSessionTitle, size: 9.5, tracking: 1.33,
            color: StateLegend.Palette.faint)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(plus); addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            plus.leadingAnchor.constraint(equalTo: leadingAnchor),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: GridRowView.lampColumn),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }
}
