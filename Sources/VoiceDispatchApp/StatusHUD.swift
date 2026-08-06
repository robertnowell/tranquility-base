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
    /// The readback face's ONE negative (simplification pass, ruled): a quiet
    /// text action, not a lozenge. The Reply/Dismiss buttons are dead — chords
    /// are the interface.
    private var dontSendButton: NSButton!
    private var hintLabel: NSTextField!
    private var contentStack: NSStackView?
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
    private var countdownBar: CountdownBarView!
    private var meter: LevelMeterView!
    private var voiceList: NSScrollView!
    private var voiceStack: NSStackView!
    private var voiceListHeight: NSLayoutConstraint!
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
    }

    /// What arming replaced, kept whole so the abort path can restore the
    /// EXACT prior face — state, strings, rows, closures — including hidden:
    /// arming surfaces the panel, so an abort from hidden re-hides it.
    /// Consumed by revertArming; invalidated by any entry into listening
    /// (the upgrade path no longer needs it).
    private var stashBeforeArming: (state: PanelState, face: Face)?

    /// The arming face (instant-arm, docs/instant-arm.md): the listening
    /// pill's geometry in the faint treatment — flat meter, faint dot,
    /// identity only if already in hand. A real PanelState case run through
    /// the same transition funnel as every face; returns false when the
    /// legality table refuses (a capture state owns the stage), in which
    /// case the caller arms audio only and paints nothing.
    @discardableResult
    func showArming(target: String?) -> Bool {
        let prior = (state: state, face: face)
        guard transition(to: .arming, because: "arm window opened") else { return false }
        stashBeforeArming = prior
        face = Face(listeningTarget: target ?? "")
        render()
        return true
    }

    /// Restore exactly the face arming replaced. No-op unless the panel is
    /// still arming — an upgrade or an explicit dismiss has already moved it
    /// on, and the stash dies with it.
    func revertArming(because reason: String) {
        guard case .arming = state, let stash = stashBeforeArming else {
            stashBeforeArming = nil
            return
        }
        stashBeforeArming = nil
        forceTransition(to: stash.state, because: "arm reverted: \(reason)")
        face = stash.face
        render()
    }

    func showListening(level: @escaping () -> Float) {
        guard transition(to: .listening(eventId: currentEventId), because: "recording started")
        else { return }
        // An armed face that upgraded no longer has anything to revert to.
        stashBeforeArming = nil
        levelSource = level
        // A pill: target name plus waveform, nothing else. The name stays
        // (unlike Wispr) because our destination is a terminal somewhere else,
        // not the focused field on this screen. The hands-free ✕/✓ buttons are
        // dead code deleted (simplification pass): they were never attached to
        // any view hierarchy, and the chords cover both actions.
        face = Face(listeningTarget: currentTarget?.label ?? dictationDestination
                        ?? StateLegend.clipboardDestination)
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
        topic: String, spoken: String, sessionId: String, pid: Int?, project: String,
        cwd: String?, eventId: String? = nil,
        placard: String? = nil
    ) {
        currentEventId = eventId
        currentTarget = (sessionId, pid, project)
        guard transition(to: .speaking(eventId: eventId), because: "audio starting")
        else { return }
        // Into the fresh Face, never before it: the wholesale rebuild is what
        // clears a previous pull's placard on ordinary announcements. The topic
        // rides separately from the identity (ruled: identity in mono, topic in
        // the regular face) and is dropped when it adds nothing — a topic equal
        // to the project rendered as "promotions — promotions".
        let extra = topic.caseInsensitiveCompare(project) == .orderedSame ? "" : topic
        face = Face(title: project, topic: extra, body: spoken,
                    placardOverride: placard ?? "")
        render()
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
        // READBACK placard via the same placardOverride the ladder pills use;
        // the identity (mono) titles the card, the words being sent are the body.
        face = Face(title: label, body: "\u{201C}\(text)\u{201D}",
                    placardOverride: StateLegend.readbackPlacard,
                    countdownSeconds: seconds)
        render()
    }

    /// Fast-forward the undo window: fire the send NOW instead of at the bar's
    /// end. ⌃⌥ during the countdown means "yes, send it, and move on" — the press
    /// is momentum, not doubt; doubt is what Don't send and ⌃⇧ are for.
    @discardableResult
    func commitPendingSendNow() -> Bool {
        guard awaitingConfirm else { return false }
        countdownTimer?.invalidate(); countdownTimer = nil
        countdownBar.isHidden = true
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
        countdownBar.isHidden = true
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

    // setPaused is dead (simplification pass, ruled): ⇧ pause is an AUDIO
    // behavior; the frozen speaking card — highlight stopped mid-word — IS the
    // pause indication. No pill switch, no hint.

    /// Append a line to the current panel without disturbing what it is showing.
    func note(_ message: String) {
        hintLabel.stringValue = [message, hintLabel.stringValue]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if let panel { resizeToFit(panel); position(panel) }
    }

    /// Settings, in the same panel rather than a second window: the voice
    /// ROSTER pane (draft render ruled 05 Aug — the single narrator dropdown
    /// is dead). Every cached voice is a row: square check = on the roster
    /// (the cast sessions draw durable voices from, in roster order), ▶ =
    /// preview, ≡ in the left gutter drags a roster row to a new assignment
    /// position.
    var onPreviewVoice: ((String) -> Void)?
    /// (voiceId, nowOnRoster) after a check toggle. The host persists and
    /// calls updateSettings — the pane never mutates the roster itself.
    var onToggleVoice: ((String, Bool) -> Void)?
    /// The full roster order after a ≡ drag lands.
    var onRosterReordered: (([String]) -> Void)?

    func showSettings(voices: [Voice], roster: [String], note: String) {
        guard transition(to: .settings, because: "settings opened") else { return }
        currentTarget = nil
        face = Face(title: "Voices", body: note, voices: voices, roster: roster)
        render()
    }

    /// Re-render the pane with a new roster without re-entering the state —
    /// the toggle round-trips through the host's persistence and back here.
    func updateSettings(roster: [String]) {
        guard case .settings = state else { return }
        face.roster = roster
        render()
    }

    var backButtonHidden: Bool { backButton.isHidden }
    var gearHidden: Bool { gearButton.isHidden }
    var actionRowHidden: Bool { actionRow.isHidden }
    var voiceRowCount: Int { voiceStack.arrangedSubviews.count }

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

    /// A failure receipt — the ONLY receipt (simplification pass, ruled): the
    /// Sent face is dead, success says nothing on the panel (status line + log
    /// only, immediate return to the grid). A failure is the case with work
    /// left to do, so it stays until dismissed, titled by the session it is
    /// about — the one displayed identity, in mono.
    func showResult(_ message: String) {
        guard transition(to: .result, because: "reply failed") else { return }
        face = Face(title: currentTarget?.label ?? "", body: message)
        render()
    }

    /// The dictation receipt (ui-pass-7, ruling 5): dictation success shows its
    /// card again, because it tells you where the words went — which app was
    /// typed into, or what is now on the clipboard, is invisible otherwise.
    /// Reply-send success stays silent as ruled; this is the only
    /// success-shaped card in the app. No title: dictation is exactly the path
    /// with no agent, so the Delivered pill and the body carry the whole story.
    func showDictationReceipt(_ message: String) {
        guard transition(to: .receipt, because: "dictation delivered") else { return }
        face = Face(body: message)
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
        // A dismissed arm has nothing left to revert to.
        stashBeforeArming = nil
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
        currentTarget = nil; currentEventId = nil

        if rows.isEmpty {
            // The true empty state — the ONLY surface where the literal app name
            // appears, with the one-line hint.
            face = Face(title: "Voice Dispatch",
                        body: [note, "Nothing waiting. Agents appear here as they finish."]
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
        // The user door: hiding is always an explicit act (Dismiss, quit),
        // never a stale resume — so it bypasses the table.
        forceTransition(to: .hidden, because: "panel hidden")
        currentTarget = nil; currentEventId = nil
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
        /// The displayed identity (the tab's string) — rendered in MONO on
        /// every face, matching the grid rows (ruled). The app name on the true
        /// empty state rides the same slot: it is the app's own identity.
        var title = ""
        /// The composed topic, in the REGULAR face beside the mono identity;
        /// empty when it adds nothing the identity doesn't.
        var topic = ""
        var body = "", listeningTarget = ""
        /// Names the pill when a face needs its own placard — the ⌃⌃ ladder
        /// rungs ("◀ FINDINGS") and READBACK. Empty = the state's own placard.
        var placardOverride = ""
        var countdownSeconds: TimeInterval = 0
        var sessionRows: [StateLegend.SessionRow] = []
        var voices: [Voice] = []
        var roster: [String] = []
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
        case .speaking: return .speaking
        // The faint pill (armingPill) carries this face; no legend row.
        case .arming: return nil
        case .listening: return .listening(target: face.listeningTarget)
        case .transcribing: return .working
        // The READBACK placard (face.placardOverride) carries this face's pill.
        case .pendingSend: return nil
        case .result: return .needsYou
        case .receipt: return .delivered
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
        // The leaving state's machinery dies here, in one place: the
        // transcription ticker, and (outside a live capture) the meter.
        // The countdown TIMER is deliberately not stopped here (open issue #8:
        // the paths that end a pending send — commit, cancel, endCapture, its own
        // expiry — say so themselves); only its pixels are, in the baseline.
        endTranscribingUI()
        if !state.isCapturingAudio { meterTimer?.invalidate(); meterTimer = nil }
        if case .hidden = state { panel?.orderOut(nil); return }
        let panel = panel ?? build()

        // Baseline: pill from the state's legend row (or the face's own
        // placard), title and body from the stash, every quiet action off.
        // Go to agent stays available while listening — knowing which
        // terminal your words are about to land in is exactly when you want to
        // check. No hint line on any card (ruled): the grid's key line is the
        // only hint left, set by its own arm.
        let row = situation().map { StateLegend.row(for: $0) }
        stateLabel.attributedStringValue = placardText(
            face.placardOverride.isEmpty
                ? (row?.stateText ?? "") : face.placardOverride)
        stateLabel.isHidden = false
        stateLabel.textColor = StateLegend.Lens.chrome.color
        // A title exists exactly when the face carries one; an empty label still
        // reserves a line's height, which reads as a hole. The identity renders
        // in MONO, matching the grid rows; the topic joins in the regular face.
        renderTitle()
        bodyLabel.stringValue = face.body
        hintLabel.stringValue = ""
        goButton.isHidden = currentTarget?.pid == nil
        dontSendButton.isHidden = true
        countdownBar.isHidden = true; meter.isHidden = true
        voiceList.isHidden = true; waitingRows.isHidden = true
        gearButton.isHidden = false; backButton.isHidden = true
        // Part of the baseline so the grid's monospaced key line can never leak
        // into another state's hint — a font no arm mentions is at its baseline.
        hintLabel.font = .systemFont(ofSize: 10)
        // Unhidden only by the slow-transcription tick, never by a state's arm.
        cancelTranscriptionButton.isHidden = true; retryTranscriptionButton.isHidden = true

        switch state {
        case .hidden, .preparing, .transcribing, .receipt:
            break

        case .speaking:
            // Karaoke starts unspoken (ui-pass-7, ruling 6): the card's text
            // first paints entirely in the faint treatment; ink arrives only
            // word-by-word with the voice. highlight(upTo: 0) IS the initial
            // attribution — without it the baseline's plain stringValue showed
            // every word full-dark until the first word event repainted it.
            highlight(upTo: 0)

        case .idle where !face.sessionRows.isEmpty:
            // The grid: the idle face IS one row per live session (WS-B, ruled).
            // Ruled strip: a small letterspaced AGENTS placard where the Ready
            // pill would be — no "Ready", no "N waiting" (the count lives in the
            // menu bar) — and the key line at the bottom: every gesture the grid
            // answers to, in the panel's monospaced small type.
            // Tracking 3.2 (was 1.6): the accepted draft's strip is airier —
            // "A G E N T S" — and the title got shorter, so it can afford it.
            stateLabel.attributedStringValue = letterspaced(
                StateLegend.gridStripTitle, size: 10, tracking: 3.2,
                color: StateLegend.Lens.chrome.color)
            hintLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
            hintLabel.stringValue = StateLegend.gridHint
            waitingRows.isHidden = false
            rebuildSessionRows()

        case .idle:
            // True empty state: the baseline already says everything — the app
            // name as title and the one-line note as body.
            break

        case .arming:
            // The listening pill's geometry, grayed: faint dot, faint target
            // (or none), the meter visible but FLAT — no timer feeds it, so
            // it draws its resting floor. Same widgets as .listening; the
            // upgrade at hold-resolution is an alpha/content change, not a
            // relayout.
            titleLabel.isHidden = true
            stateLabel.attributedStringValue = armingPill()
            meter.isHidden = false
            meter.reset()

        case .listening:
            titleLabel.isHidden = true
            // The pill's dot in channel green (ruled): mic open = go.
            stateLabel.attributedStringValue = listeningPill()
            meter.isHidden = false

        case .pendingSend:
            // Exactly ONE negative (ruled), as a quiet text action.
            dontSendButton.isHidden = false
            countdownBar.isHidden = false

        case .result:
            // A failure stays until dismissed. Amber presence beyond the glyph
            // (ruled): the placard text itself in amber ink — flat, calm.
            // Re-rendered attributed rather than via textColor, which attributed
            // runs ignore.
            stateLabel.textColor = StateLegend.Palette.fault
            stateLabel.attributedStringValue = placardText(
                stateLabel.attributedStringValue.string,
                color: StateLegend.Palette.fault)

        case .settings:
            stateLabel.stringValue = ""
            gearButton.isHidden = true; backButton.isHidden = false
            voiceList.isHidden = false
            bodyLabel.stringValue =
                "\(face.roster.count) of \(face.voices.count) on roster. \(face.body)"
            hintLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
            hintLabel.stringValue = "check = on roster · ▶ preview · drag ≡ to reorder"
            rebuildVoiceRows()
        }

        // The action row exists exactly when a quiet action is visible. (The
        // slow-transcription tick unhides its own actions later and re-runs
        // this.)
        updateActionRowVisibility()

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
                self.updateActionRowVisibility()
                self.note(StateLegend.slowTranscriptionNote)
                Permissions.log("transcribing: slow (\(seconds)s), surfaced cancel/retry")
            }
            RunLoop.main.add(timer, forMode: .common); transcribingTimer = timer

        case .pendingSend:
            // The bar animates CONTINUOUSLY across the window (ruled — tick
            // steps read as a stutter), filling go-green; one one-shot timer
            // fires the send when the window closes. Layout has already run, so
            // the bar's bounds are real when the animation starts.
            countdownBar.begin(seconds: face.countdownSeconds)
            let send = onCommitSend
            let timer = Timer(timeInterval: face.countdownSeconds, repeats: false) {
                [weak self] timer in
                guard let self else { return timer.invalidate() }
                self.countdownTimer = nil
                self.countdownBar.isHidden = true
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
    }

    /// The identity in MONO (matching the grid rows) on line one; the topic in
    /// the regular face starting on line TWO (ui-pass-7, ruling 4) — always its
    /// own line, never a same-line continuation. Still one attributed string in
    /// one label, so the pair stays a single layout unit; each line truncates
    /// against the panel edge by itself.
    private func renderTitle() {
        titleLabel.isHidden = face.title.isEmpty
        guard !face.title.isEmpty else { titleLabel.stringValue = ""; return }
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let line = NSMutableAttributedString(
            string: face.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: StateLegend.Palette.ink,
                .paragraphStyle: truncating,
            ])
        if !face.topic.isEmpty {
            line.append(NSAttributedString(
                string: "\n\(face.topic)", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: StateLegend.Palette.secondary,
                    .paragraphStyle: truncating,
                ]))
        }
        titleLabel.attributedStringValue = line
    }

    /// The listening pill: the live dot in channel green (mic open = go), the
    /// target in the pill's usual chrome mono.
    private func listeningPill() -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let pill = NSMutableAttributedString(
            string: StateLegend.Glyph.dot, attributes: [
                .font: font, .foregroundColor: StateLegend.Palette.ready,
            ])
        pill.append(NSAttributedString(
            string: " \(face.listeningTarget)", attributes: [
                .font: font, .foregroundColor: StateLegend.Lens.chrome.color,
            ]))
        return pill
    }

    /// The arming pill: the listening pill's geometry with the whole thing in
    /// the faint treatment — the dot is not yet "go", it is "maybe". The
    /// target rides along only when it was already in hand (the active
    /// conversation); the arm path never probes for one.
    private func armingPill() -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let pill = NSMutableAttributedString(
            string: StateLegend.Glyph.dot, attributes: [
                .font: font, .foregroundColor: StateLegend.Palette.faint,
            ])
        if !face.listeningTarget.isEmpty {
            pill.append(NSAttributedString(
                string: " \(face.listeningTarget)", attributes: [
                    .font: font, .foregroundColor: StateLegend.Palette.faint,
                ]))
        }
        return pill
    }

    /// The action row exists exactly when one of its quiet actions is visible —
    /// the row of lozenge buttons is dead (ruled); this is what replaced its
    /// per-state visibility flag.
    private func updateActionRowVisibility() {
        actionRow.isHidden = [goButton, dontSendButton,
                              cancelTranscriptionButton, retryTranscriptionButton]
            .allSatisfy { $0?.isHidden ?? true }
        if let panel { resizeToFit(panel); position(panel) }
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

    /// The roster pane's rows: roster members first, in assignment order, then
    /// the rest grouped by category. Rows draw their own bottom hairline (no
    /// interleaved rule views), so an arranged index IS a row index — the ≡
    /// drag's arithmetic depends on that.
    private func rebuildVoiceRows() {
        voiceStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let byId = Dictionary(uniqueKeysWithValues: face.voices.map { ($0.id, $0) })
        // A roster id the catalog no longer lists has no row (nothing to play,
        // nothing to name); it stays in the persisted roster untouched until
        // the user next reorders, which saves exactly what is on screen.
        let cast = face.roster.compactMap { byId[$0] }
        let bench = face.voices
            .filter { !face.roster.contains($0.id) }
            .sorted { ($0.category, $0.name) < ($1.category, $1.name) }
        for voice in cast + bench {
            let onRoster = face.roster.contains(voice.id)
            let row = VoiceRowView(
                voice: voice, onRoster: onRoster,
                onPlay: { [weak self] in self?.onPreviewVoice?(voice.id) },
                onToggle: { [weak self] in self?.onToggleVoice?(voice.id, !onRoster) },
                onDragStep: { [weak self] row, step in self?.dragRosterRow(row, by: step) },
                onDragEnd: { [weak self] in self?.commitRosterOrder() })
            voiceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.gridWidth).isActive = true
        }
        voiceListHeight.constant = min(
            CGFloat(voiceStack.arrangedSubviews.count) * VoiceRowView.height, 340)
        Permissions.log("roster pane: \(cast.count) cast + \(bench.count) bench rows")
    }

    /// Move a roster row by whole-row steps during a ≡ drag, clamped inside
    /// the roster segment (the bench below is sorted, not ordered — nothing
    /// can be dragged into it).
    private func dragRosterRow(_ row: VoiceRowView, by steps: Int) {
        let rows = voiceStack.arrangedSubviews.compactMap { $0 as? VoiceRowView }
        guard steps != 0, let current = rows.firstIndex(where: { $0 === row }) else { return }
        let rosterCount = rows.filter(\.isOnRoster).count
        let target = max(0, min(rosterCount - 1, current + steps))
        guard target != current else { return }
        voiceStack.removeArrangedSubview(row)
        voiceStack.insertArrangedSubview(row, at: target)
    }

    private func commitRosterOrder() {
        let order = voiceStack.arrangedSubviews
            .compactMap { $0 as? VoiceRowView }
            .filter(\.isOnRoster)
            .map(\.voiceId)
        onRosterReordered?(order)
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
            // matrix is on the record: transcribing, the undo window, then the
            // one receipt left (failure — the Sent face is dead, ruled).
            ("working", { self.showTranscribing("Transcribing your reply…",
                                                onCancel: {}, onRetry: {}) }),
            ("pendingSend", { self.showPendingSend(
                text: "words that should never be sent", label: "promotions",
                seconds: 60, send: {}, cancel: { _ in }) }),
            ("result", { _ = self.cancelPendingSend(restartListening: false)
                         self.showResult(long) }),
            // The one success-shaped card (ui-pass-7, ruling 5): a delivered
            // dictation names where the words went.
            ("receipt", { self.showDictationReceipt(
                "Copied to clipboard: \u{201C}\(long)\u{201D}") }),
            ("settings", {
                self.showSettings(
                    voices: [Voice(id: "a", name: "Archer", category: "professional"),
                             Voice(id: "b", name: "My Clone", category: "cloned"),
                             Voice(id: "c", name: "Sarah", category: "premade")],
                    roster: ["c"],
                    note: "Checked voices are the cast agents speak with.")
                self.panel?.contentView?.layoutSubtreeIfNeeded()
                Permissions.log("settings chrome: rows=\(self.voiceRowCount) "
                                + "back=\(!self.backButtonHidden) gear=\(!self.gearHidden) "
                                + "actions=\(!self.actionRowHidden)")
            }),
        ] as [(String, () -> Void)] {
            Permissions.log("selftest state=\(label)")
            block()
            Permissions.log("selftest matrix \(label): \(widgetMatrix())")
        }

        // Instant-arm (E3, docs/instant-arm.md): from each prior face, arming
        // must restore the EXACT widget matrix on abort — including hidden,
        // where arming surfaces the panel and the revert re-hides it. This
        // whole block runs synchronously on the main actor, so no timer can
        // interleave between the before and after readings.
        let armPriors: [(String, () -> Void)] = [
            ("grid", { self.showIdle(rows: [
                .init(id: "a", name: "Fix hero image binding",
                      callsign: "promotions copy", lamp: .ready),
                .init(id: "b", name: "voice dispatch", callsign: "", lamp: .running),
            ]) }),
            ("speaking", { self.showAnnouncement(
                topic: "Hero image binding fix", spoken: long,
                sessionId: "s", pid: 1, project: "promotions", cwd: "/tmp/promotions") }),
            ("hidden", { self.hide() }),
        ]
        for (label, paint) in armPriors {
            paint()
            let before = "\(widgetMatrix()) state=\(state.name) visible=\(isOnScreen)"
            let armed = showArming(target: "promotions copy")
            let armingMatrix = "\(widgetMatrix()) state=\(state.name) visible=\(isOnScreen)"
            revertArming(because: "selftest")
            let after = "\(widgetMatrix()) state=\(state.name) visible=\(isOnScreen)"
            // Hidden's observable contract is state + visibility: render()
            // short-circuits before the widget baseline while hidden (the
            // panel may not even be built yet), so the widget matrix under
            // hidden is unobservable residue by design — the next surface
            // rebaselines every widget before the panel is ordered front.
            let restored = label == "hidden"
                ? state.name == "hidden" && !isOnScreen
                : before == after
            Permissions.log("selftest arm[\(label)]: armed=\(armed) "
                            + "restored=\(restored)")
            Permissions.log("selftest arm[\(label)] before:  \(before)")
            Permissions.log("selftest arm[\(label)] arming:  \(armingMatrix)")
            Permissions.log("selftest arm[\(label)] after:   \(after)")
        }
        // And the upgrade path: arming admits exactly one successor, listening.
        showArming(target: "promotions copy")
        showListening(level: { 0.3 })
        Permissions.log("selftest arm[upgrade]: state=\(state.name) "
                        + "(want listening) meterShown=\(!meter.isHidden)")
        recordingEnded()
        endCapture(because: "selftest arm cleanup")

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
        func announce(project: String, topic: String,
                      spoken text: String, highlightFraction: Double,
                      placard: String? = nil,
                      cwd: String = NSHomeDirectory() + "/Projects/kopi/promotions") {
            showAnnouncement(topic: topic, spoken: text,
                             sessionId: "pose", pid: 1, project: project, cwd: cwd,
                             placard: placard)
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

        case "depth1":
            // Exactly the ⌃⌃ path: the same announcement card, the rationale as
            // the spoken text, karaoke highlight and all — with the rung-naming
            // pill main.swift sends ("◀ WHY", the ladder's own convention).
            announce(project: callsign, topic: "Hero image binding fix",
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

        case "readback":
            adopt()
            showPendingSend(
                text: "Ship the Shopify-only filter and rerun the poller",
                label: callsign, seconds: 8, send: {}, cancel: { _ in })
            // Frozen mid-window: 40% elapsed. The freeze below kills the timer;
            // this pins the bar's fill so the photograph shows a real mid-state.
            panel?.contentView?.layoutSubtreeIfNeeded()
            countdownBar.freeze(fraction: 0.4)

        case "needsyou":
            adopt()
            showResult("promotions copy's tab is gone — copied your words to the clipboard.")

        case "receipt":
            // The dictation receipt (ui-pass-7, ruling 5). No adopted target:
            // dictation is exactly the path with no agent, so the Delivered
            // pill and the body carry the whole story.
            showDictationReceipt("Copied to clipboard: \u{201C}Ship the "
                + "Shopify-only filter and rerun the poller\u{201D}")

        case "settings":
            showSettings(
                voices: [Voice(id: "a", name: "Archer", category: "professional"),
                         Voice(id: "b", name: "My Clone", category: "cloned"),
                         Voice(id: "c", name: "Sarah", category: "premade"),
                         Voice(id: "d", name: "River", category: "premade")],
                roster: ["c", "a"],
                note: "Checked voices are the cast agents speak with.")

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

    /// Every widget's visibility in one line, so the selftest log IS the render
    /// contract: diff two runs and any residue names itself.
    private func widgetMatrix() -> String {
        let widgets: [(String, NSView?)] = [
            ("title", titleLabel), ("body", bodyLabel), ("state", stateLabel),
            ("hint", hintLabel), ("bar", countdownBar), ("meter", meter),
            ("actions", actionRow), ("go", goButton),
            ("dontSend", dontSendButton), ("voices", voiceList),
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
        // The identity face: mono, matching the grid rows (ruled). renderTitle
        // sets the attributed pair; this is the fallback style. Two lines
        // (ui-pass-7, ruling 4): identity on line one, topic on line two.
        titleLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = StateLegend.Lens.content.color
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2

        bodyLabel = NSTextField(wrappingLabelWithString: "")
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = StateLegend.Lens.content.color
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.isSelectable = true

        // Every surviving action is a QUIET text action (ruled): borderless,
        // palette ink, no lozenge. The button rows are dead — chords are the
        // interface; these are the few context actions a face still owns.
        func quietAction(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = StateLegend.Palette.ink
            return button
        }
        // "Go to agent" (ui-pass-7, rulings 1 + 3): the one navigation the
        // panel owns gets presence — go-green palette ink, letterspaced caps
        // like the grid placards, and the action row's right edge to itself.
        // Still flat, no lozenge: promotion by ink and placement, not chrome.
        goButton = NSButton(title: "Go to agent", target: self, action: #selector(goToSession))
        goButton.isBordered = false
        goButton.attributedTitle = letterspaced(
            "GO TO AGENT \(StateLegend.Glyph.forward)", size: 10.5, tracking: 1.3,
            color: StateLegend.Palette.advisory)
        dontSendButton = quietAction("Don't send", #selector(cancelPendingSendTapped))

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

        // Surfaced only once a transcription has run long enough to deserve them
        // (sanctioned change: open issue #4). Quiet text, like their row-mates.
        cancelTranscriptionButton = quietAction(StateLegend.cancelTranscriptionTitle,
                                                #selector(cancelTranscriptionTapped))
        retryTranscriptionButton = quietAction(StateLegend.retryTranscriptionTitle,
                                               #selector(retryTranscriptionTapped))

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = StateLegend.Lens.guidance.color

        // Quiet context actions keep the left edge; GO TO AGENT holds the
        // right edge alone (ui-pass-7, ruling 3). The row spans the content
        // column below, so the trailing gravity is a real edge.
        let buttons = NSStackView()
        actionRow = buttons
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.addView(dontSendButton, in: .leading)
        buttons.addView(cancelTranscriptionButton, in: .leading)
        buttons.addView(retryTranscriptionButton, in: .leading)
        buttons.addView(goButton, in: .trailing)

        hintLabel.maximumNumberOfLines = 0
        hintLabel.lineBreakMode = .byTruncatingMiddle
        countdownBar = CountdownBarView()

        meter = LevelMeterView()

        // The roster list: a flipped document so content hangs from the top,
        // the stack of VoiceRowViews inside, overlay scroller, no chrome.
        voiceStack = NSStackView()
        voiceStack.orientation = .vertical
        voiceStack.alignment = .leading
        voiceStack.spacing = 0
        voiceStack.translatesAutoresizingMaskIntoConstraints = false
        let voiceDoc = FlippedDocumentView()
        voiceDoc.translatesAutoresizingMaskIntoConstraints = false
        voiceDoc.addSubview(voiceStack)
        voiceList = NSScrollView()
        voiceList.drawsBackground = false
        voiceList.hasVerticalScroller = true
        voiceList.scrollerStyle = .overlay
        voiceList.translatesAutoresizingMaskIntoConstraints = false
        voiceList.documentView = voiceDoc
        voiceListHeight = voiceList.heightAnchor.constraint(equalToConstant: 340)
        NSLayoutConstraint.activate([
            voiceStack.topAnchor.constraint(equalTo: voiceDoc.topAnchor),
            voiceStack.leadingAnchor.constraint(equalTo: voiceDoc.leadingAnchor),
            voiceStack.trailingAnchor.constraint(equalTo: voiceDoc.trailingAnchor),
            voiceStack.bottomAnchor.constraint(equalTo: voiceDoc.bottomAnchor),
            voiceDoc.leadingAnchor.constraint(equalTo: voiceList.contentView.leadingAnchor),
            voiceDoc.topAnchor.constraint(equalTo: voiceList.contentView.topAnchor),
            voiceDoc.widthAnchor.constraint(equalTo: voiceList.contentView.widthAnchor),
            voiceListHeight,
        ])

        waitingRows = NSStackView()
        waitingRows.orientation = .vertical
        waitingRows.alignment = .leading
        waitingRows.spacing = 2

        let stack = NSStackView(views: [backButton, stateLabel, titleLabel,
                                        waitingRows, bodyLabel,
                                        countdownBar, meter, voiceList, hintLabel, buttons])
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
            countdownBar.widthAnchor.constraint(equalToConstant: 348),
            countdownBar.heightAnchor.constraint(equalToConstant: 4),
            // The action row spans the content column so GO TO AGENT's
            // trailing gravity right-aligns against a real edge (ruling 3).
            buttons.widthAnchor.constraint(equalToConstant: 348),
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
                bodyLabel.stringValue = "That agent is no longer running, so there's no tab to open."
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
                bodyLabel.stringValue = "That agent's tab isn't open in Terminal any more (\(tty))."
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

    func recordingEnded() {
        dictationDestination = nil
        meterTimer?.invalidate(); meterTimer = nil
        meter?.isHidden = true
    }

    /// Set by the app so Dismiss can silence the voice, not just hide the panel.
    var onDismiss: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onLeaveSettings: (() -> Void)?

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
/// The placard string with symbol glyphs optically corrected. ◀/▶ are not in
/// SF Mono; the fallback font's triangle renders larger and off-baseline
/// against the placard's 10pt mono caps (Robert's screenshot, 06 Aug — the
/// "◀ SOLUTION" rung pill). The glyph run is drawn smaller with a baseline
/// nudge so both fonts share one optical center; letter runs keep the
/// placard's own font. Color is explicit because attributed runs ignore the
/// field's textColor.
private func placardText(
    _ text: String, color: NSColor = StateLegend.Lens.chrome.color
) -> NSAttributedString {
    let placardFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    let out = NSMutableAttributedString()
    var letters = ""
    func flushLetters() {
        guard !letters.isEmpty else { return }
        out.append(NSAttributedString(string: letters, attributes: [
            .font: placardFont, .foregroundColor: color,
        ]))
        letters = ""
    }
    for ch in text {
        if ch == "◀" || ch == "▶" {
            flushLetters()
            out.append(NSAttributedString(string: String(ch), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 7.5, weight: .medium),
                .baselineOffset: 0.8,
                .foregroundColor: color,
            ]))
        } else {
            letters.append(ch)
        }
    }
    flushLetters()
    return out
}

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
            StateLegend.newAgentTitle, size: 9.5, tracking: 1.33,
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

/// The readback countdown, drawn by Core Animation instead of a ticking
/// NSProgressIndicator: one linear animation across the whole window (ruled —
/// tick steps read as a stutter), the fill in the palette's go green. The send
/// itself is fired by a one-shot timer in render(); this view is pixels only.
private final class CountdownBarView: NSView {
    private let fill = CALayer()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        fill.backgroundColor = StateLegend.Palette.ready.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0)
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Fill from empty to full over the window, continuously. Called after
    /// layout, so bounds are real.
    func begin(seconds: TimeInterval) {
        fill.removeAllAnimations()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let sweep = CABasicAnimation(keyPath: "bounds.size.width")
        sweep.fromValue = 0
        sweep.toValue = bounds.width
        sweep.duration = seconds
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.add(sweep, forKey: "sweep")
    }

    /// Pin the fill at a fraction with no animation — the pose driver's frozen
    /// mid-window photograph.
    func freeze(fraction: CGFloat) {
        fill.removeAllAnimations()
        fill.frame = CGRect(x: 0, y: 0,
                            width: bounds.width * fraction, height: bounds.height)
    }
}

/// A scroll document that hangs content from the top; without it a stack in an
/// NSScrollView anchors to the bottom and short lists float mid-air.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// One row of the voice roster pane (draft render ruled 05 Aug):
/// [≡ grip 16][square check 14][11][▶][11][name — flexible][category, faint].
/// The check is SQUARE — it is a checkbox; circles are the grid's session
/// lamps and the two must not read as the same species. The grip lives in the
/// left gutter so the check column is the pane's left alignment line, and it
/// exists only on roster rows: the bench below is sorted, not ordered.
private final class VoiceRowView: NSControl {
    static let height: CGFloat = 34
    static let gripWidth: CGFloat = 16

    let voiceId: String
    let isOnRoster: Bool
    private let onPlay: () -> Void
    private let onToggle: () -> Void
    private let onDragStep: (VoiceRowView, Int) -> Void
    private let onDragEnd: () -> Void
    private let hairline = CALayer()
    private var dragging = false
    private var dragAccum: CGFloat = 0
    private var lastStep = 0

    init(voice: Voice, onRoster: Bool,
         onPlay: @escaping () -> Void,
         onToggle: @escaping () -> Void,
         onDragStep: @escaping (VoiceRowView, Int) -> Void,
         onDragEnd: @escaping () -> Void) {
        self.voiceId = voice.id
        self.isOnRoster = onRoster
        self.onPlay = onPlay
        self.onToggle = onToggle
        self.onDragStep = onDragStep
        self.onDragEnd = onDragEnd
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hairline.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
        layer?.addSublayer(hairline)

        let grip = NSTextField(labelWithString: onRoster ? "≡" : "")
        grip.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        grip.textColor = StateLegend.Palette.faint
        grip.translatesAutoresizingMaskIntoConstraints = false

        let check = CheckView(on: onRoster) { [weak self] in self?.onToggle() }

        let play = NSButton(title: "▶", target: self, action: #selector(playTapped))
        play.isBordered = false
        play.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        play.contentTintColor = StateLegend.Palette.secondary
        play.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: Self.concise(voice.name))
        name.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        name.textColor = StateLegend.Palette.ink
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let category = NSTextField(labelWithString: voice.category)
        category.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        category.textColor = StateLegend.Palette.faint
        category.translatesAutoresizingMaskIntoConstraints = false

        addSubview(grip); addSubview(check); addSubview(play)
        addSubview(name); addSubview(category)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: Self.gripWidth),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            play.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 11),
            play.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: 11),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: category.leadingAnchor,
                                           constant: -10),
            category.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            category.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    /// "Brittney - Social Media Voice - Fun, Youthful…" → "Brittney". The row
    /// names a voice; the sales copy stays in the catalog.
    static func concise(_ name: String) -> String {
        let head = name
            .components(separatedBy: CharacterSet(charactersIn: "-–—™"))
            .first?.trimmingCharacters(in: .whitespaces) ?? name
        return head.isEmpty ? name : head
    }

    @objc private func playTapped() { onPlay() }

    // ≡ drag: whole-row steps from accumulated deltaY (positive = down =
    // later index; the flipped document keeps visual and index order equal).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isOnRoster, point.x < Self.gripWidth else { return }
        dragging = true; dragAccum = 0; lastStep = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        dragAccum += event.deltaY
        let step = Int((dragAccum / Self.height).rounded())
        if step != lastStep {
            onDragStep(self, step - lastStep)
            lastStep = step
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDragEnd()
    }
}

/// The square roster checkbox: filled console green with a ✓ when on, the
/// hover putty with a hairline ring when off. Same materials as the lamps,
/// different shape — shape is what says "you can set this".
private final class CheckView: NSControl {
    private let onToggle: () -> Void

    init(on: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 2.5
        layer?.backgroundColor = (on ? StateLegend.Palette.ready
                                     : StateLegend.Palette.hover).cgColor
        if !on {
            layer?.borderWidth = 1
            layer?.borderColor = StateLegend.Palette.hairline.cgColor
        }
        if on {
            let mark = NSTextField(labelWithString: StateLegend.Glyph.confirm)
            mark.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
            mark.textColor = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.89, alpha: 1)
            mark.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mark)
            NSLayoutConstraint.activate([
                mark.centerXAnchor.constraint(equalTo: centerXAnchor),
                mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle()
    }
}
