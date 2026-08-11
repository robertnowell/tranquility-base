import AppKit
import TranquilityCore

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
    private var titleLabel: DoorLabel!
    private var bodyLabel: NSTextField!
    private var stateLabel: NSTextField!
    private var goButton: NSButton!
    /// The readback face's ONE negative (simplification pass, ruled): a quiet
    /// text action, not a lozenge. The Reply/Dismiss buttons are dead — chords
    /// are the interface.
    private var dontSendButton: NSButton!
    private var micSettingsButton: NSButton!
    private var newSessionButton: NSButton!
    private var openPageButton: NSButton!
    private var hintLabel: NSTextField!
    /// The capture strip's own label, and the hairline that separates it from
    /// whatever it sits under.
    ///
    /// The capture used to speak through `stateLabel` — one pill, at the top —
    /// which is why starting a reply had to take the card's pill, and therefore
    /// its whole face. Given a slot of its own at the bottom, the capture stops
    /// competing for the card's: the card keeps its placard, its identity and
    /// its ink, and the microphone says what it is doing underneath.
    ///
    /// ONE slot, three phases (ruling item 3): arming, listening and read-back
    /// all write this one label, and the box does not move between them.
    private var stripLabel: NSTextField!
    private var stripRule: NSView!
    private var contentStack: NSStackView?
    /// The collapsed column. Built once, hidden until the width changes.
    private var strip: CollapsedStrip?
    /// The expanded face's whole view tree, held so the two widths can be
    /// SWAPPED as content views rather than layered inside one.
    ///
    /// Layering was the first attempt and it put the panel off the screen. The
    /// grid's stack pins the content view to 380pt; hiding it does not retire
    /// its constraints, so a `setFrame` to 40pt was silently snapped back to 380
    /// on the next layout pass — while the ORIGIN had already been moved to
    /// `maxX - 40`. The result was a 380pt window hanging 340pt past the right
    /// edge of the display, with only its empty left margin visible.
    private var expandedRoot: NSView?
    private var stackEdges: [NSLayoutConstraint] = []
    private var stripEdges: [NSLayoutConstraint] = []

    /// Collapsed or expanded, and DURABLE — the user owns the width and nothing
    /// else sets it. Persisted because the app installs with a login item and
    /// restarts far more often than the user thinks about it; a width that reset
    /// on every relaunch would not be a preference, it would be a default with
    /// extra steps. See docs/ruling-the-collapsed-strip.md.
    private static let collapsedKey = "panelCollapsed"
    private(set) var isCollapsed: Bool = UserDefaults.standard.bool(forKey: StatusHUD.collapsedKey) {
        didSet {
            UserDefaults.standard.set(isCollapsed, forKey: StatusHUD.collapsedKey)
            Permissions.log("panel: \(isCollapsed ? "collapsed" : "expanded")")
        }
    }

    /// Lamps the collapsed column is currently showing — the drill asserts idle
    /// ones never reach it.
    var collapsedLampCount: Int { strip?.lamps.count ?? 0 }
    var collapsedGlowStrength: CGFloat { strip?.currentGlowStrength ?? 0 }
    /// In a window, visible, and actually in the view tree. NOT
    /// `panel.contentView === strip` any more: the strip is a sibling inside the
    /// panel's rounded background now, so the old check asserted an arrangement
    /// the redesign deliberately abandoned.
    var collapsedIsOnScreen: Bool {
        guard let strip else { return false }
        return strip.window != nil && !strip.isHidden && strip.superview != nil
    }

    /// An agent came back. Mark it on the collapsed strip.
    ///
    /// Only collapsed: expanded, the row itself lights up and a halo would be
    /// the same news twice. And only ever a transient — see `CollapsedStrip.flash`
    /// for why a glow that outlives its moment becomes the notification badge
    /// this product exists to avoid.
    func flashArrival(_ lamp: StateLegend.Lamp) {
        guard isCollapsed else { return }
        Permissions.log("glow: arrival")
        strip?.flash(lamp)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        render()
    }
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
    /// What is being said, in both forms. The card shows the unredacted side;
    /// the voice reports its progress in spoken coordinates, so the highlight
    /// asks this value to translate rather than assuming the two line up.
    private var currentSpoken: SanitizedSpokenText?
    private var countdownTimer: Timer?
    private var onCancelSend: ((_ restartListening: Bool) -> Void)?
    private var onCommitSend: (() -> Void)?
    private var countdownBar: CountdownBarView!
    private var meter: LevelMeterView!
    private var voiceList: NSScrollView!
    private var voiceStack: NSStackView!
    private var voiceListHeight: NSLayoutConstraint!
    private var gearButton: NSButton!
    private var collapseButton: NSButton!
    private var backButton: NSButton!
    private var waitingRows: NSStackView!
    var onPickWaiting: ((String) -> Void)?

    /// Clicking the ◀ breadcrumb goes home (ruled 06 Aug: "there's no reason
    /// it shouldn't be clickable — voiced first while allowing a keyboard
    /// tap"). Only wired for the card states whose ⌃⌥ already means home;
    /// the guard lives in the click handler, the meaning in main.swift.
    var onBreadcrumbHome: (() -> Void)?

    /// Clicking a lit lamp marks that session heard without inviting it
    /// (ruled 06 Aug: "mischief managed" — switch the light off). The host
    /// owns the store write; the grid repaints through the ordinary path.
    var onClearLamp: ((String) -> Void)?
    private var actionRow: NSStackView!
    private static let spokenMark = NSAttributedString.Key("vdSpoken")

    private var currentTarget: (sessionId: String, pid: Int?, label: String)?

    /// The page the agent on stage most recently wrote, if it still exists.
    ///
    /// Derived from `currentTarget` rather than stored beside it. Storing it
    /// would mean clearing it at all four sites that clear the target, and the
    /// one that got missed would leave a button pointing at the previous
    /// agent's page — the exact confusion this feature exists to end. It is the
    /// other half of what the footer starts: the page links back to its agent,
    /// and the agent's card links out to its page.
    private var currentArtifact: String? {
        currentTarget.flatMap { artifactForSession?($0.sessionId) }
    }
    /// Wired by the app onto ArtifactStore. Nil until then, and nil is a
    /// complete answer — most sessions have written no page at all.
    var artifactForSession: ((String) -> String?)?
    /// Wired by the app onto the workspace's "open this file" call.
    var onOpenPage: ((String) -> Void)?

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
        beginCaptureFace(target: target ?? "")
        render()
        return true
    }

    /// Start a capture on the CURRENT face rather than in place of it.
    ///
    /// This is the whole of the strip design (ruling item 1): "a capture
    /// augments the face; it does not replace it." Every capture entry point
    /// used to run `face = Face(listeningTarget:)`, which is why answering a
    /// reply cost you the reply — three faces in sequence for one continuous
    /// act, and a read-back that asked you to check words against a message no
    /// longer on screen.
    ///
    /// With no card to sit under, this IS the old behaviour: a fresh face whose
    /// only content is the strip, which is ruling §E — a capture begun from the
    /// grid has nothing to augment, so the strip is the whole panel.
    ///
    /// The placard is snapshotted because it is the one part of the card the
    /// baseline would otherwise recompute from `state`, and `state` is now the
    /// capture's. `placardOverride` already exists for exactly this — naming a
    /// pill the state cannot name — so the ladder's "◀ FINDINGS" survives a
    /// reply without a second mechanism.
    private func beginCaptureFace(target: String) {
        // The branch decides whether the card lives, so it says which way it
        // went and why. Production disagreed with the drill on 10 Aug — the
        // drill kept the card, the real ⌥ did not — and there was no line in
        // the log that could tell the two apart.
        Permissions.log("capture face: hasCard=\(face.hasCard) "
                        + "body=\(face.body.count) rows=\(face.sessionRows.count) "
                        + "title=\(face.title) state=\(state.name)")
        guard face.hasCard else {
            face = Face(listeningTarget: target)
            return
        }
        if face.placardOverride.isEmpty {
            face.placardOverride = stateLabel.attributedStringValue.string
        }
        face.listeningTarget = target
    }

    /// Paint the capture strip: rule, placard, and an optional second line.
    ///
    /// The branch is the whole of ruling §E. With a card on screen the capture
    /// speaks from the bottom and leaves `stateLabel` to the card; with nothing
    /// underneath, the strip IS the panel and the pill returns to the top,
    /// which is exactly what the panel did before this change — so a capture
    /// from the grid is byte-identical to the one that shipped.
    private func renderCaptureStrip(_ placard: NSAttributedString,
                                    detail: String? = nil) {
        guard face.hasCard else {
            titleLabel.isHidden = true
            stateLabel.attributedStringValue = placard
            return
        }
        stripRule.isHidden = false
        stripLabel.isHidden = false
        let line = NSMutableAttributedString(attributedString: placard)
        if let detail, !detail.isEmpty {
            line.append(NSAttributedString(
                string: "\n" + detail,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: StateLegend.Palette.secondary]))
        }
        stripLabel.attributedStringValue = line
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
        beginCaptureFace(target: currentTarget?.label ?? dictationDestination
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

    /// Returns whether the stage was actually taken. The caller must not speak
    /// when it was not: this returned Void, so a refusal reached nobody and the
    /// audio played into a live microphone anyway (Coordinator.speak).
    @discardableResult
    /// `spoken` carries both forms. The card is painted from the unredacted one —
    /// a listener cannot use `dispatchAttempts` but a reader needs it, and
    /// hearing "a variable" four times while reading four column names is the
    /// whole point of the split.
    ///
    /// The `topic` parameter is gone (10 Aug). It only ever fed the card's second
    /// line, and that line said the same thing as `spoken` with the detail taken
    /// out. Leaving the parameter behind for callers to keep supplying would have
    /// been a slower way of deleting it.
    func showAnnouncement(
        spoken: SanitizedSpokenText, sessionId: String, pid: Int?, project: String,
        cwd: String?, eventId: String? = nil,
        placard: String? = nil
    ) -> Bool {
        // Take the stage BEFORE recording who owns it. These two assignments used
        // to run above the guard, so a refused announcement still repointed
        // `currentTarget` — the routing that decides which terminal your next
        // dictation is typed into. A refusal that paints nothing but silently
        // moves the reply target is worse than one that paints.
        guard transition(to: .speaking(eventId: eventId), because: "audio starting")
        else { return false }
        currentEventId = eventId
        currentSpoken = spoken
        currentTarget = (sessionId, pid, project)
        // Into the fresh Face, never before it: the wholesale rebuild is what
        // clears a previous pull's placard on ordinary announcements.
        face = Face(title: project, body: spoken.displayText,
                    placardOverride: placard ?? "")
        render()
        return true
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
        // The read-back joins the strip instead of taking the stage (ruling
        // item 4): the READBACK placard, the words and the countdown all render
        // under the reply they answer, which is the first time checking one
        // against the other has been possible. With no card to sit under, the
        // strip is the whole panel and this is the old behaviour verbatim.
        if face.hasCard {
            face.readback = text
            face.countdownSeconds = seconds
        } else {
            face = Face(title: label, body: "\u{201C}\(text)\u{201D}",
                        placardOverride: StateLegend.readbackPlacard,
                        countdownSeconds: seconds)
        }
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
        // Ruled 07 Aug: "when I hit ⌃⌥ from the confirmation readback it should
        // IMMEDIATELY show Sending, and then Sent." The receipt was living
        // inside the dispatch task, so it appeared once the send was already
        // under way rather than the instant the press committed it. The label
        // is the readback's own title — the identity the card was showing when
        // you pressed.
        let target = face.title
        // Committing is an explicit act: the send is out of your hands, so the
        // stage is yielded — the advance that follows may paint immediately
        // instead of being refused by a pendingSend that is already over.
        forceTransition(to: .idle(waiting: 0), because: "send committed")
        if !target.isEmpty { showReceipt(.sending(target)) }
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

    @objc nonisolated private func breadcrumbClicked() {
        MainActor.assumeIsolated {
            // Same altitude rule as ⌃⌥: home from a card. Speaking covers the
            // announcement and every ⌃⌃ rung — the states whose breadcrumb
            // says "back the way you came".
            guard case .speaking = state else { return }
            onBreadcrumbHome?()
        }
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
        // A capture phase like the others: the card stays and the strip says
        // what is happening to your words. Without this the card survived the
        // microphone and then died on the way to the transcript, which is the
        // same defect one step later.
        if face.hasCard {
            face.transcription = (cancel: onCancel, retry: onRetry)
            face.captureNote = message
        } else {
            face = Face(title: currentTarget?.label ?? "", body: message,
                        transcription: (cancel: onCancel, retry: onRetry))
        }
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

    /// The microphone is open and nothing is arriving from it — the third tier
    /// of the silence gate, and the only one that is a genuine fault.
    ///
    /// It earns a card where the other two do not, on both counts a card is for:
    /// there is something wrong that saying it again will not fix, and there is
    /// an action that fixes it. So this one keeps the amber, keeps the stage,
    /// and waits — and unlike every other failure it offers a way OUT rather
    /// than back.
    ///
    /// No title, deliberately. `showResult` names the session a failure was
    /// about, and this one is about the machine: the agent did nothing, is owed
    /// nothing, and putting its name at the top of a hardware fault is the same
    /// misattribution the "Needs you" pill used to make on a quiet room.
    func showDeviceFault(_ message: String) {
        guard transition(to: .result, because: "no audio from the input device")
        else { return }
        face = Face(body: message,
                    placardOverride: StateLegend.noAudioPlacard,
                    offersMicSettings: true)
        render()
    }

    /// A page arrived asking for an agent that is not there — the deep link
    /// names a session this Mac has no record of, or whose terminal tab is gone.
    ///
    /// It earns a card on the same two counts the device fault does: there is
    /// something to know, and there is one action that resolves it. Everything
    /// else about it is the opposite. It speaks on the advisory channel, not
    /// amber, because nothing is broken — an artifact simply outlived the
    /// conversation that made it, which is the NORMAL end state of every page
    /// that gets shared. And it carries no session title: there is no agent to
    /// name, which is the whole message.
    ///
    /// This is also the entire experience of a page made on someone else's
    /// machine, so it is the first thing a new user ever sees the app do.
    func showNewSessionInvitation(artifact: String, directory: String, ref: String) {
        guard transition(to: .result, because: "no agent for \(artifact)") else { return }
        invitationRef = ref
        face = Face(body: StateLegend.orphanedArtifact(artifact, directory: directory),
                    placardOverride: StateLegend.startSessionPlacard,
                    lens: .advisory,
                    offersNewSession: true)
        render()
    }

    /// The artifact the live invitation is about. Held here rather than passed
    /// through the button because the button is a target/action pair from
    /// AppKit's era and carries no payload.
    private var invitationRef: String?

    /// Wired by the app onto SessionLauncher, with the artifact in hand.
    var onNewSessionForArtifact: ((String) -> Void)?

    @objc nonisolated private func openPageTapped() {
        MainActor.assumeIsolated {
            guard let page = currentArtifact else { return }
            Permissions.log("openPage: \(page)")
            onOpenPage?(page)
        }
    }

    @objc nonisolated private func newSessionForArtifactTapped() {
        MainActor.assumeIsolated {
            guard let ref = invitationRef else { return }
            onNewSessionForArtifact?(ref)
        }
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

    // MARK: - The grid notice (ruled 08 Aug)

    /// A few seconds of amber in the grid's own strip, where the AGENTS placard
    /// sits — the whole surface for a refusal that is not a failure.
    ///
    /// The silence gate used to paint the full `.result` face: the "Needs you"
    /// pill, the session's title, "Didn't catch that — too short or too quiet.
    /// Nothing sent." Three claims, and the only true one was the mic's. It
    /// read as an incident report about an agent that had done nothing wrong,
    /// it demanded a dismissal for a press that cost nothing, and it took the
    /// stage away from the grid you were looking at. A card is for work left to
    /// do; there is none here but to speak again.
    ///
    /// So: no state, no transition, no dismissal. The notice is a decoration on
    /// idle that expires on its own clock, and it cannot exist anywhere else —
    /// if the panel has moved to a card, whatever that card is about outranks a
    /// stale word about the microphone.
    private var notice: String?
    /// Which channel the live notice speaks on. Amber is the needs-you channel;
    /// advisory blue is news you may ignore. A notice that picked the wrong one
    /// is worse than no notice: amber trains the eye to check, and spending that
    /// on "nothing is wrong, we just stayed quiet" blunts it for the cases that
    /// do need checking.
    private var noticeLens: StateLegend.Lens = .fault
    private var noticeExpiry: DispatchWorkItem?

    func flashNotice(_ text: String, lens: StateLegend.Lens = .fault,
                     seconds: TimeInterval = 5) {
        guard case .idle = state else {
            Permissions.log("notice: refused in \(state.name): \(text)")
            return
        }
        noticeLens = lens
        noticeExpiry?.cancel()
        notice = text
        Permissions.log("notice: \(text)")
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.notice != nil else { return }
            self.clearNotice()
            self.render()
        }
        noticeExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: expiry)
        render()
    }

    /// Whether the strip is currently carrying a notice — the selftest asserts
    /// this returns to false, since nothing but its own clock clears it.
    var noticeIsShowing: Bool { notice != nil }

    private func clearNotice() {
        noticeExpiry?.cancel()
        noticeExpiry = nil
        notice = nil
    }

    /// When the room went empty, and the clock that turns it into a lesson.
    ///
    /// A timestamp rather than a one-shot flag because the empty face repaints
    /// on every ambient tick: a flag would be reset by the tick five seconds in,
    /// and the sentence would never arrive. Elapsed time since the room emptied
    /// is the fact; the work item only exists to paint it when nothing else is
    /// repainting.
    private var emptySince: Date?
    private var gettingStartedWork: DispatchWorkItem?

    /// Retired in the one place state changes, so no path has to remember —
    /// the same discipline the notice follows. A panel that has left idle is a
    /// panel with something to do, and the room is no longer empty.
    private func forgetEmptyRoom() {
        emptySince = nil
        gettingStartedWork?.cancel()
        gettingStartedWork = nil
    }

    /// Paint the sentence when the room has been empty long enough, if nothing
    /// has happened by then. Re-armed on every empty repaint with the time
    /// REMAINING, never restarted from ten.
    private func scheduleGettingStarted(in seconds: TimeInterval) {
        gettingStartedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  case .idle = self.state,
                  self.face.sessionRows.isEmpty,
                  let since = self.emptySince,
                  Date().timeIntervalSince(since) >= StateLegend.gettingStartedAfter
            else { return }
            Permissions.log("empty room: teaching the first press")
            self.face = Face(body: StateLegend.gettingStartedMessage, gettingStarted: true)
            self.render()
        }
        gettingStartedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: work)
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
        // Leaving Preparing cancels its pending paint wherever that happens, so
        // no path has to remember to. A card that arrives 250ms after the thing
        // it was covering for is worse than one that never arrived.
        if case .preparing = next {} else {
            preparingPaint?.cancel(); preparingPaint = nil
        }
        // Same discipline for the grid notice: it belongs to idle alone, and it
        // is retired HERE — in the one place state changes — so render() never
        // has to write to the thing it is painting, and no path has to remember.
        // The hide/show leak this closes: `.hidden` returns out of render before
        // its body runs, so a notice cleared down there survived a dismiss and
        // came back up with the panel.
        if case .idle = next {} else { clearNotice(); forgetEmptyRoom() }
        return true
    }

    /// The user's door. Explicit actions (Dismiss, hiding the panel, committing a
    /// send) are never stale, so they bypass the table — but they announce it.
    private func forceTransition(to next: PanelState, because reason: String) {
        guard next != state else { return }
        Permissions.log("state: \(state.name) -> \(next.name)  (\(reason), user door)")
        state = next
        if case .idle = next {} else { clearNotice(); forgetEmptyRoom() }
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
    func showIdle(note: String? = nil, rows: [StateLegend.SessionRow],
                  because reason: String = "idle repaint") {
        // The transition that used to stomp a live listening pill (an interrupted
        // announce resuming after the gesture that killed it). Now the table
        // refuses it and this returns without painting.
        //
        // `reason` is caller-supplied because it used to be the literal string
        // "idle repaint" for all twenty-five callers, and that made the log lie
        // about provenance: a deliberate return-to-grid and the five-second
        // ambient tick were indistinguishable in app.log. A whole incident was
        // misattributed to ambient churn on the strength of that string, when the
        // ambient path cannot reach a card state at all — `canSurfaceAmbiently`
        // gates it on `allowsAmbientSurface`, which is `.hidden`/`.idle` only.
        let waiting = rows.filter { $0.lamp == .ready }.count
        guard transition(to: .idle(waiting: waiting), because: reason)
        else { return }
        currentTarget = nil; currentEventId = nil

        if rows.isEmpty {
            // An empty room says two different things depending on how long it
            // has been empty. For the first ten seconds it is a room whose
            // agents have not reported in yet, and it describes itself. After
            // that nobody is coming on their own, and the only useful thing the
            // panel can say is how to start one (ruled 08 Aug).
            let since = emptySince ?? Date()
            emptySince = since
            let elapsed = Date().timeIntervalSince(since)
            if elapsed >= StateLegend.gettingStartedAfter {
                face = Face(body: StateLegend.gettingStartedMessage, gettingStarted: true)
            } else {
                // The true empty state — the ONLY surface where the literal app name
                // appears, with the one-line hint.
                face = Face(title: "Tranquility Base",
                            body: [note, "Nothing waiting. Agents appear here as they finish."]
                                .compactMap { $0 }.joined(separator: " "))
                scheduleGettingStarted(in: StateLegend.gettingStartedAfter - elapsed)
            }
        } else {
            // Someone reported in: the room is not empty and the clock is void.
            forgetEmptyRoom()
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
    func dismiss() { clearReceipt(); dismissTapped() }

    func hide() {
        clearReceipt()
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
        var body = "", listeningTarget = ""
        /// Names the pill when a face needs its own placard — the ⌃⌃ ladder
        /// rungs ("◀ FINDINGS") and READBACK. Empty = the state's own placard.
        var placardOverride = ""
        var countdownSeconds: TimeInterval = 0
        var sessionRows: [StateLegend.SessionRow] = []
        var voices: [Voice] = []
        var roster: [String] = []
        var transcription: (cancel: () -> Void, retry: () -> Void)?
        /// The failure card carries a way out to the microphone pane. True only
        /// for a device fault — the one failure in this app whose fix is a
        /// setting rather than saying it again.
        var offersMicSettings = false
        /// Which channel a waiting card speaks on. Amber stays the default
        /// because nearly every card that waits IS a failure. The invitation is
        /// the exception — an artifact outlived its agent, nothing is broken —
        /// and painting that amber would spend the needs-you channel on an
        /// offer, which is exactly what blunted it on the silence gate.
        var lens: StateLegend.Lens = .fault
        /// The invitation's door: start a fresh agent holding this artifact.
        var offersNewSession = false
        /// The empty room has been empty long enough to teach the first press
        /// instead of describing itself. A face of idle, not a state of its own:
        /// nothing about what the panel ADMITS changes, only what it says.
        var gettingStarted = false

        /// How far the read-along got, in DISPLAY coordinates. `nil` is the
        /// unspoken baseline, which is why a fresh `Face()` starts grey.
        ///
        /// The ink is part of the face (ruling §A, docs/ruling-capture-returns
        /// -to-its-card.md). It used to live only in the pixels: `render()`'s
        /// `.speaking` arm called `highlight(upTo: 0)` unconditionally, because
        /// entering `.speaking` had always meant a fresh card. Any repaint of a
        /// face that had been read to therefore reset it to unread grey and
        /// re-armed the loading wash — measured, `20:21:29 highlight upTo=0→0
        /// of 437`. As a field, any repaint of any face restores its own ink,
        /// because the cursor travelled with the face.
        ///
        /// DISPLAY space, not spoken space, and this is load-bearing: the card
        /// shows the unredacted text while the voice counts in the sanitized
        /// one, and `currentSpoken` may have moved on by the time a face is
        /// repainted. Re-mapping a stale spoken index is how the ink would come
        /// back in the wrong place. The mapping happens once, at `highlight`.
        var spokenUpTo: Int?

        /// Whether this face is a CARD — something a capture can sit under.
        ///
        /// The strip ruling's §E: "a capture begun from the grid has no card to
        /// sit under, so the strip is the whole panel, exactly as today." The
        /// question the capture entry points have to answer is therefore not
        /// "what state am I in" but "is there anything here worth keeping", and
        /// the face can answer it about itself. Derived, never stored: a stored
        /// flag is one more thing that can disagree with the face it describes.
        var hasCard: Bool { !body.isEmpty && sessionRows.isEmpty }

        /// The words waiting to be sent, shown in the strip during the undo
        /// window. Separate from `body`, which belongs to the card underneath —
        /// the whole point of the read-back moving into the strip is that the
        /// reply and the message it answers are on screen at the same time.
        var readback: String?

        /// What the strip says during `.transcribing` — "Transcribing your
        /// reply…" and, past twenty seconds, the slow note. On the face rather
        /// than read from the state so the one strip painter has one source.
        var captureNote: String?
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
    ///
    /// **The contract that keeps that true, for anyone adding an arm: a widget
    /// PROPERTY that any arm mutates must be written in the baseline too, not
    /// only the widget's content.** It has been learned twice — the grid's
    /// monospaced key line, then the empty room's 17pt centred body — and both
    /// times the symptom was the same, a later face inheriting type it never
    /// asked for. Setting `.stringValue` and leaving `.font`, `.alignment` or
    /// `.textColor` behind is the residue class this funnel exists to close;
    /// the baseline is not "content", it is every attribute anyone touches.
    private func render() {
        // The leaving state's machinery dies here, in one place: the
        // transcription ticker, and (outside a live capture) the meter.
        // The countdown TIMER is deliberately not stopped here (open issue #8:
        // the paths that end a pending send — commit, cancel, endCapture, its own
        // expiry — say so themselves); only its pixels are, in the baseline.
        endTranscribingUI()
        stopBodyShimmer()
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
        // Part of the baseline for the same reason the hint's font is: the empty
        // room's 17pt centred sentence is the only face that changes either, so
        // a state that never mentions them must not inherit them.
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.alignment = .natural
        // The ink is a BODY ATTRIBUTE, so it belongs to the baseline: the line
        // above writes a plain string and would otherwise erase the read-along
        // on every repaint that is not `.speaking` — which, now that a capture
        // keeps the card, is most of them. Only faces that have actually been
        // read to carry a cursor; a `.result` or `.receipt` card has none and
        // keeps its full-dark body exactly as before.
        if let cursor = face.spokenUpTo { paintInk(displayCursor: cursor) }
        hintLabel.stringValue = ""
        goButton.isHidden = currentTarget?.pid == nil
        // The card's second door. It rides the same rule as "Go to agent" —
        // shown wherever an agent is named — because the two are one pair: this
        // agent, and the last thing it made. A session that has written no page
        // simply has one door, and most do.
        openPageButton.isHidden = currentArtifact == nil
        dontSendButton.isHidden = true
        micSettingsButton.isHidden = true
        newSessionButton.isHidden = true
        countdownBar.isHidden = true; meter.isHidden = true
        // The strip belongs to the capture arms alone. Both the label AND its
        // rule are baselined — a rule left behind is the residue class this
        // funnel exists to close, and it would draw a line across a card that
        // has nothing under it.
        stripLabel.isHidden = true; stripRule.isHidden = true
        stripLabel.stringValue = ""
        voiceList.isHidden = true; waitingRows.isHidden = true
        gearButton.isHidden = false; backButton.isHidden = true
        // Only the grid can be collapsed: a card is a conversation in progress
        // and has no second width to go to.
        collapseButton?.isHidden = true
        // Part of the baseline so the grid's monospaced key line can never leak
        // into another state's hint — a font no arm mentions is at its baseline.
        hintLabel.font = .systemFont(ofSize: 10)
        // Unhidden only by the slow-transcription tick, never by a state's arm.
        cancelTranscriptionButton.isHidden = true; retryTranscriptionButton.isHidden = true

        switch state {
        case .transcribing:
            if let note = face.captureNote {
                renderCaptureStrip(placardText(note))
            }

        case .hidden, .preparing, .receipt:
            break

        case .speaking:
            // Karaoke starts unspoken (ui-pass-7, ruling 6): the card's text
            // first paints entirely in the faint treatment; ink arrives only
            // word-by-word with the voice. The paint IS the initial attribution
            // — without it the baseline's plain stringValue showed every word
            // full-dark until the first word event repainted it.
            //
            // From the face, not from zero (ruling §A). A fresh card carries no
            // cursor and paints grey; a card that has been read to — a ⌃⌃ rung
            // you are part-way through — repaints at the cursor it reached.
            let inkCursor = face.spokenUpTo ?? 0
            paintInk(displayCursor: inkCursor)
            // The card is up but the audio is not here yet. Until now that
            // window had no affordance at all: a full card of grey text, ink
            // that never moved, and nothing to say whether it was loading or
            // dead. On a slow link it could sit there for eleven seconds.
            //
            // Only when nothing has been spoken yet. Re-arming the wash over
            // text that is already half-inked is the other half of the "it
            // reset" symptom — the words go grey AND start loading again.
            if inkCursor == 0 { armBodyShimmer() }

        case .idle where !face.sessionRows.isEmpty:
            // The grid: the idle face IS one row per live session (WS-B, ruled).
            // Ruled strip: a small letterspaced AGENTS placard where the Ready
            // pill would be — no "Ready", no "N waiting" (the count lives in the
            // menu bar) — and the key line at the bottom: every gesture the grid
            // answers to, in the panel's monospaced small type.
            // Tracking 3.2 (was 1.6): the accepted draft's strip is airier —
            // "A G E N T S" — and the title got shorter, so it can afford it.
            // Indented past the collapse toggle, which sits at the panel's far
            // left. Without this the icon draws straight through the "AG" of
            // AGENTS — the two were competing for the same 24pt, and the label
            // won on paint order and lost on legibility.
            let stripTitle = NSMutableAttributedString(attributedString: letterspaced(
                StateLegend.gridStripTitle, size: 10, tracking: 3.2,
                color: StateLegend.Lens.chrome.color))
            let indent = NSMutableParagraphStyle()
            indent.firstLineHeadIndent = 24
            stripTitle.addAttribute(.paragraphStyle, value: indent,
                                    range: NSRange(location: 0, length: stripTitle.length))
            stateLabel.attributedStringValue = stripTitle
            hintLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
            hintLabel.stringValue = StateLegend.gridHint
            waitingRows.isHidden = false
            collapseButton?.isHidden = isCollapsed
            // Settings is an expanded-face affordance. The gear lives on
            // `background` rather than inside the stack, so hiding the stack
            // does not take it with it — it has to be named.
            gearButton?.isHidden = isCollapsed
            // The collapsed column is the same data at another width. Every
            // widget the expanded face owns stays hidden behind it; render()
            // remains the single place either one is decided.
            if isCollapsed { strip?.show(rows: face.sessionRows) }
            rebuildSessionRows()

        case .idle where face.gettingStarted:
            // The empty room, past its ten seconds: ONE sentence and nothing
            // else. Every other element is switched off by name rather than
            // left to the baseline, because the point of this face is what it
            // does NOT show — the app's name, the Ready pill, and the key line
            // are all complexity charged to someone who has not pressed a key
            // yet. The gear stays: it is the only door to settings, and a first
            // -run face that strands the microphone pane is worse than a busy
            // one. Centred and larger, so it reads as the panel's whole purpose
            // rather than a caption on an absence.
            stateLabel.isHidden = true
            titleLabel.isHidden = true
            bodyLabel.font = .systemFont(ofSize: 17, weight: .regular)
            bodyLabel.alignment = .center

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
            // The card, if there is one, is untouched — title, body and ink
            // all stay where the baseline put them. Only when there is nothing
            // to sit under does the pill climb back to the top.
            renderCaptureStrip(armingPill())
            meter.isHidden = false
            meter.reset()

        case .listening:
            // The pill's dot in channel green (ruled): mic open = go.
            renderCaptureStrip(listeningPill())
            meter.isHidden = false

        case .pendingSend:
            // Exactly ONE negative (ruled), as a quiet text action.
            dontSendButton.isHidden = false
            countdownBar.isHidden = false
            // The read-back is the strip's third phase, in the same slot the
            // other two used. The placard names it; the words follow.
            if let readback = face.readback {
                renderCaptureStrip(placardText(StateLegend.readbackPlacard),
                                   detail: "\u{201C}\(readback)\u{201D}")
            }

        case .result:
            // A card that waits until dismissed. Amber presence beyond the glyph
            // (ruled): the placard text itself in the channel's ink — flat, calm.
            // Re-rendered attributed rather than via textColor, which attributed
            // runs ignore. The channel comes from the face, not the state: the
            // invitation waits the same way a failure does and means the
            // opposite.
            stateLabel.textColor = face.lens.color
            stateLabel.attributedStringValue = placardText(
                stateLabel.attributedStringValue.string,
                color: face.lens.color)
            // A device fault is the only failure with somewhere to send you.
            micSettingsButton.isHidden = !face.offersMicSettings
            // The invitation's door out is a door IN: it starts the agent that
            // this page no longer has.
            newSessionButton.isHidden = !face.offersNewSession

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

        // The notice owns the strip while it lives. It can only exist on idle at
        // all — the two transition doors retire it on the way out — so this is a
        // read, and render() stays the pure projection it claims to be.
        if let notice {
            // Unhidden explicitly: the empty room's face switches the strip off,
            // and a notice with nowhere to land is feedback the user never gets.
            stateLabel.isHidden = false
            stateLabel.textColor = noticeLens.color
            stateLabel.attributedStringValue = placardText(notice, color: noticeLens.color)
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

    /// The identity in MONO (matching the grid rows), on one line, alone.
    ///
    /// The topic that used to ride line two is dead (ruled 10 Aug). It was a
    /// 3–6 word compression of the thing the body was about to say in full, so
    /// the card opened by saying the same thing twice at two sizes — and the
    /// second saying was the one carrying no detail. What the card is FOR is the
    /// reason, and the reason is `body`. `showAnnouncement` had already been
    /// half-admitting this: it dropped the topic whenever it equalled the
    /// project, which is the special case of a general truth.
    ///
    /// What the identity is for is getting BACK to the session — so it is now a
    /// door (see `titleIsADoor`), which is the job it was actually doing.
    private func renderTitle() {
        titleLabel.isHidden = face.title.isEmpty
        guard !face.title.isEmpty else { titleLabel.stringValue = ""; return }
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        titleLabel.attributedStringValue = NSAttributedString(
            string: face.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: StateLegend.Palette.ink,
                .paragraphStyle: truncating,
            ])
        // Only a live target has a tab to open. No per-face flag is needed for
        // this: `currentTarget` is already nil on exactly the faces whose title
        // is not a session — it is cleared going idle and again by showVoices,
        // so "Voices" and the empty room's "Tranquility Base" cannot inherit the
        // last session's tab. `titleDoorDrill` holds that alignment.
        titleLabel.isADoor = currentTarget?.pid != nil
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
            string: " \(Self.pillTarget(face.listeningTarget))", attributes: [
                .font: font, .foregroundColor: StateLegend.Lens.chrome.color,
            ]))
        return pill
    }

    /// The pill shares its row with the gear, and a target can be a whole
    /// terminal title — an untruncated one runs clean under the gear glyph
    /// (caught in the 06 Aug ack-bar capture). The placard row is 348pt wide
    /// and the gear owns the last ~34 of it; at 10pt mono that leaves 30
    /// characters, glyph and space included.
    private static func pillTarget(_ target: String) -> String {
        let cap = 28
        guard target.count > cap else { return target }
        return target.prefix(cap - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The arming pill: the listening pill's geometry with the whole thing in
    /// the faint treatment — the dot is not yet "go", it is "maybe". The
    /// target rides along only when it was already in hand (the active
    /// conversation); the arm path never probes for one.
    private func armingPill() -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        // `hint`, not `faint`: the pill names where the words are about to go,
        // which is the one thing you must be able to read before releasing.
        let pill = NSMutableAttributedString(
            string: StateLegend.Glyph.dot, attributes: [
                .font: font, .foregroundColor: StateLegend.Palette.hint,
            ])
        if !face.listeningTarget.isEmpty {
            pill.append(NSAttributedString(
                string: " \(Self.pillTarget(face.listeningTarget))", attributes: [
                    .font: font, .foregroundColor: StateLegend.Palette.hint,
                ]))
        }
        return pill
    }

    /// The action row exists exactly when one of its quiet actions is visible —
    /// the row of lozenge buttons is dead (ruled); this is what replaced its
    /// per-state visibility flag.
    private func updateActionRowVisibility() {
        actionRow.isHidden = [goButton, openPageButton, dontSendButton,
                              micSettingsButton, newSessionButton,
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
            if item.lamp == .ready {
                row.onLampTap = { [weak self] in self?.onClearLamp?(item.id) }
            }
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
        // Collapsed is a fixed frame, so the column never resizes under the
        // user and the lamps never move. It is also the only face that is
        // FLUSH to the screen edge — `position` gives every other face a
        // margin; a sidebar with a gap behind it is a floating card pretending
        // to be a sidebar.
        if isCollapsed, case .idle = state {
            // A WIDTH change and nothing else. The right edge stays exactly
            // where the grid's right edge was — same 16pt margin every other
            // face gets — the corner radius stays, the panel stays. Ruled after
            // the first attempt swapped content views and went flush to the
            // screen edge: "just make it skinny and keep the right edge in the
            // same place, and animate the collapse."
            NSLayoutConstraint.deactivate(stackEdges)
            NSLayoutConstraint.activate(stripEdges)
            contentStack?.isHidden = true
            strip?.isHidden = false
            // Fixed height as well as fixed width — ruled, and load-bearing for
            // the wordmark: inheriting the grid's height gave the strip 150pt on
            // a quiet day, which left no room below the lamps and silently
            // dropped the wordmark. The strip is the same size every time.
            morph(panel, to: NSSize(width: CollapsedStrip.width,
                                    height: CollapsedStrip.height))
            return
        }
        NSLayoutConstraint.deactivate(stripEdges)
        NSLayoutConstraint.activate(stackEdges)
        strip?.isHidden = true
        contentStack?.isHidden = false


        guard let stack = contentStack else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let needed = stack.fittingSize
        let height = max(needed.height, 90)
        // Against the height we last ASKED for, never the live frame: with an
        // animated resize in flight, `panel.frame.height` is a transient, and
        // comparing to it let a render skip its resize because the panel
        // happened to be passing through the target height at that instant.
        // That is why two identical faces settled 12pt apart (Robert's two
        // screenshots of the same card, 06 Aug).
        // The WIDTH has to be checked too, not just the height. Expanding out of
        // the strip is a width-only change — the grid's height is often exactly
        // what the collapsed panel already had — so a height-only guard skipped
        // the resize entirely and left the panel 40pt wide. `position` then
        // placed it from that 40pt width, and the grid rendered off the right of
        // the display. That is the bug the user reported, and this line is it.
        let widthIsWrong = abs(panel.frame.width - 380) > 1
        if widthIsWrong || abs((intendedHeight ?? panel.frame.height) - height) > 1 {
            intendedHeight = height
            // The top edge holds still and the panel grows downward: origin is
            // bottom-left, so the height delta comes out of origin.y. Animated
            // when already on screen (ruled 06 Aug — the snap between
            // different-sized faces was the jarring half of the border bug);
            // the first paint still snaps, a hidden panel has nothing to ease.
            var frame = panel.frame
            let delta = height - frame.height
            frame.origin.y -= delta
            frame.size.height = height
            frame.size.width = 380
            // The ORIGIN has to be right in the animated frame, not corrected
            // afterwards. `position` runs immediately after this call and does
            // set it — and then the in-flight animation lands 0.12s later with
            // the frame it was handed, stomping the correction. Expanding out of
            // the collapsed strip therefore kept the strip's x and put 340pt of
            // grid off the right of the display: measured
            // {{1672, 751}, {380, 317}} against a screen 1728 wide.
            if let screen = NSScreen.main {
                frame.origin.x = screen.visibleFrame.maxX - frame.size.width - 16
            }
            if panel.isVisible {
                // Through the animator, NOT setFrame(animate:) — that call
                // blocks the main thread for the whole animation, which delays
                // every gesture landing behind it (the ack arriving late was
                // the symptom). This one returns immediately.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
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
    /// A bar along the top edge, not a border around the whole panel.
    ///
    /// The full border was sized to the panel at flash time, and states have
    /// different heights — the pulse regularly outlived a resize and its lower
    /// edge cut across the middle of the new face (Robert's report, 06 Aug;
    /// his fix). A bar glued to the top edge has no lower edge to strand.
    ///
    /// It is a subview of the rounded SURFACE, not the content view: the
    /// surface clips, so the bar's ends taper into the corner curve instead of
    /// being "cut off at the start of the corner round". The autoresizing mask
    /// keeps it glued through every resize, and the fade runs as an explicit
    /// CABasicAnimation rather than through the animator proxy — the proxy
    /// silently drops the animation when another one is mid-flight on the same
    /// property, which is exactly what a rapid second gesture produces.
    private var ackBar: NSView?
    private var ackHeld = false
    /// The pending fade. Held so the next press inside the window can cancel it
    /// — cancelling is what turns two presses into one light.
    private var ackStandDown: DispatchWorkItem?
    /// The height last requested of the panel — the resize's own memory, so an
    /// in-flight animation cannot be mistaken for a settled size.
    private var intendedHeight: CGFloat?
    private var surfaceView: NSView?

    /// The bar, positioned and ready. Builds the panel if a gesture arrives
    /// before the first paint — "I should never question whether my control
    /// is having an impact" (ruled) — and returns nil only if even that fails.
    private func ackBarLayer() -> CALayer? {
        let host = surfaceView ?? { _ = build(); return surfaceView }()
        guard let host else { return nil }
        let bar: NSView
        if let existing = ackBar {
            bar = existing
        } else {
            bar = NSView(frame: .zero)
            bar.wantsLayer = true
            // Palette, not controlAccentColor: accent = state, not user
            // preference (ruled) — the light is the same green as the go lamp.
            bar.layer?.backgroundColor = StateLegend.Palette.ready.cgColor
            // Flexible bottom margin = pinned to the top edge; flexible width
            // = pinned to both sides. The bar tracks every frame change.
            bar.autoresizingMask = [.width, .minYMargin]
            ackBar = bar
        }
        // Full width: the surface's own mask decides where it ends.
        bar.frame = CGRect(x: 0, y: host.bounds.height - 3,
                           width: host.bounds.width, height: 3)
        host.addSubview(bar, positioned: .above, relativeTo: nil)
        return bar.layer
    }

    /// The send receipt: a small chip at the top edge that says the words
    /// left, and then that they landed.
    ///
    /// Ruled 06 Aug: "once it's been sent, give me a little awareness… a
    /// little reassurance at the top of, like, sending, and then sent." The
    /// send ceremony was collapsed months ago for good reason — a card for a
    /// thing that went right is noise — but collapsing it left success
    /// SILENT, and silence is indistinguishable from failure to anyone who
    /// has not yet learned to trust the app. This is the middle ground: a
    /// whisper, not a card.
    ///
    /// Deliberately OUTSIDE the render funnel, and that deserves defending,
    /// because "one more painter" is how this panel got sick the first time.
    /// The justification is that a receipt is not state — it is an event,
    /// with a life of its own measured in seconds. It owns exactly one widget
    /// that no arm of render() touches, it never affects layout (it floats
    /// over the top band), it cannot own the stage or block a transition, and
    /// it always ends by fading itself out. The two places that must clear it
    /// early — dismiss and hide — do so explicitly.
    enum Receipt {
        case sending(String)
        case sent
        case queued

        var text: String {
            switch self {
            case .sending(let target):
                // The chip shares the top band with the placard and the gear;
                // a long callsign would run into both.
                let name = target.count > 20
                    ? target.prefix(19).trimmingCharacters(in: .whitespaces) + "…"
                    : target
                return "→ \(name.uppercased()) · SENDING"
            case .sent: return "✓ SENT"
            case .queued: return "✓ QUEUED · SENDS AFTER THIS TURN"
            }
        }
    }

    private var receiptChip: NSTextField?
    private var receiptFade: DispatchWorkItem?

    /// Never surfaces a hidden panel (recommended and ruled): success is not
    /// a summons. If you dismissed the panel, a send landing does not bring
    /// it back — the menu bar and the log carry it.
    func showReceipt(_ receipt: Receipt) {
        guard panel?.isVisible == true, let host = surfaceView else { return }
        let chip: NSTextField
        if let existing = receiptChip {
            chip = existing
        } else {
            chip = NSTextField(labelWithString: "")
            chip.alignment = .center
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 3
            chip.drawsBackground = false
            // Ruled 07 Aug: not centred — tucked against the gear on the
            // right, which is the clean space. Pinned to that corner so a
            // resize keeps it there.
            chip.autoresizingMask = [.minXMargin, .minYMargin]
            host.addSubview(chip)
            receiptChip = chip
        }
        let sent: Bool
        if case .sending = receipt { sent = false } else { sent = true }
        chip.attributedStringValue = letterspaced(
            receipt.text, size: 9, tracking: 1.4,
            color: sent ? StateLegend.Palette.ready : StateLegend.Palette.secondary)
        chip.sizeToFit()
        // Right edge measured from the gear itself rather than a guessed
        // margin, so the two never collide whatever the panel width.
        let gearLeft = gearButton.superview.map { view in
            view.convert(gearButton.frame, to: host).minX
        } ?? host.bounds.width - 34
        chip.frame = CGRect(x: gearLeft - chip.bounds.width - 10,
                            y: host.bounds.height - 22,
                            width: chip.bounds.width, height: chip.bounds.height)
        host.addSubview(chip, positioned: .above, relativeTo: nil)
        chip.layer?.removeAnimation(forKey: "receipt")
        chip.alphaValue = 1

        receiptFade?.cancel()
        Permissions.log("receipt: \(receipt.text) "
            + "[pid \(ProcessInfo.processInfo.processIdentifier) "
            + "chip \(UInt(bitPattern: ObjectIdentifier(chip).hashValue) % 100000) "
            + "alpha \(chip.alphaValue) frame \(Int(chip.frame.minX)),\(Int(chip.frame.minY)) "
            + "host \(Int(host.bounds.height)) siblings \(host.subviews.count)]")

        // Two clocks, because a send is slower than it feels. Measured on a
        // real dispatch: commit at 16:06:28, confirmed at 16:06:35 — SEVEN
        // seconds of "SENDING", and then the outcome flashed past in two.
        // Robert saw the first and not the second and reported no
        // confirmation at all, which is the correct reading of what was on
        // screen.
        //
        // So an outcome lingers long enough to be caught by someone who
        // looked away (4s), and "sending" gets a CEILING: if no outcome
        // arrives, the chip stops claiming a send is in progress rather than
        // sitting there indefinitely asserting something it no longer knows.
        // A dispatch that has neither landed nor failed by then has a bigger
        // problem than its receipt, and the failure card owns that.
        let linger: TimeInterval = sent ? 4.0 : 12.0
        let fade = DispatchWorkItem { [weak self, weak chip] in
            guard let chip else { return }
            if !sent { Permissions.log("receipt: sending timed out on screen") }
            self?.receiptFade = nil
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                chip.animator().alphaValue = 0
            }
        }
        receiptFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: fade)
    }

    /// Whether a receipt is currently claiming the top band. The selftest
    /// asserts this returns to false — a chip outside the render funnel has
    /// to prove it cleans up, since no arm of render() will do it for it.
    var receiptIsShowing: Bool { (receiptChip?.alphaValue ?? 0) > 0 }

    /// Clear a receipt outright — the panel is going away under it.
    func clearReceipt() {
        receiptFade?.cancel()
        receiptFade = nil
        receiptChip?.alphaValue = 0
    }

    /// Hold the light on for as long as the key is down.
    ///
    /// Ruled 06 Aug: "it should just be a reflection that your keystroke is
    /// recognized as a valid command-related key, and it should just be green
    /// while that key is pressed." The previous design pulsed once per
    /// transition, which meant a single hold flashed twice — once at the arm,
    /// again when the microphone opened — and read as a stutter rather than
    /// an acknowledgment. One light, one press.
    func holdAcknowledge() {
        guard let layer = ackBarLayer() else { return }
        // A hold that begins inside an acknowledgment's window takes the light
        // over: cancel the stand-down that would otherwise fade it mid-press,
        // and claim the colour, or a hold following a blue ⌃ would be held in
        // blue and say the wrong thing for as long as the key is down.
        ackStandDown?.cancel(); ackStandDown = nil
        layer.removeAnimation(forKey: "ack")
        layer.removeAnimation(forKey: "ack-colour")
        layer.backgroundColor = Acknowledgement.recognized.color
        layer.opacity = 1
        ackHeld = true
        Permissions.log("ack: held on")
    }

    /// Release the held light. No-op when nothing is holding it, so a stray
    /// release cannot erase a pulse that is mid-fade.
    func releaseAcknowledge() {
        guard ackHeld, let layer = ackBar?.layer else { return }
        ackHeld = false
        layer.removeAnimation(forKey: "ack")
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = 0.25
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "ack")
        Permissions.log("ack: released")
    }

    /// What the light is saying about the press that just landed.
    ///
    /// Two colours, because a press and a gesture are different facts and only
    /// one of them means the app did something. Both are Palette tokens already
    /// carrying these meanings elsewhere in the panel — advisory blue is what
    /// the app uses to say "noted", ready green is what it uses to say "go".
    enum Acknowledgement {
        /// Blue. A key landed and was understood as input, but the gesture it
        /// belongs to has not resolved yet. Today that is the first of a
        /// possible ⌃⌃ — bare ⌃ is the opening key of two chords and means
        /// nothing alone, so it must be visibly *received* without claiming
        /// anything was done.
        case registered
        /// Green. That was a gesture and the app acted on it.
        case recognized

        var color: CGColor {
            switch self {
            case .registered: return StateLegend.Palette.working.cgColor
            case .recognized: return StateLegend.Palette.ready.cgColor
            }
        }
        var name: String {
            switch self {
            case .registered: return "registered (blue)"
            case .recognized: return "recognized (green)"
            }
        }
    }

    /// How long the light stays up after the last press before standing down.
    ///
    /// Half a second, which is the span a sequence lives in: it is longer than
    /// the gap between two taps of the same hand (⌃⌃ and ⌥⌥ run 50–100ms apart,
    /// per HotkeyMonitor's own measurements), so the second tap of a pair always
    /// arrives while the light is still up and RECOLOURS it. That is the whole
    /// design — ⌃ then ⌃ is one light going blue to green, not two flashes.
    private static let ackHold: TimeInterval = 0.5
    /// And out. Slow enough not to snap, fast enough not to linger as state:
    /// the light is a receipt, not a status lamp.
    private static let ackFade: TimeInterval = 0.25

    /// Acknowledge a press: colour the light, hold it, then let it go.
    ///
    /// Supersedes the single 0.5s pulse-to-zero this replaced. The pulse started
    /// fading the instant it appeared, so a two-tap gesture read as two separate
    /// flickers and a press that resolved into something else could not show
    /// that it had — there was no light still up to change. Holding first makes
    /// the colour the signal and the fade merely the ending.
    func acknowledge(_ what: Acknowledgement) {
        // A held light outranks this: a chord arriving mid-hold must not cut
        // the hold's own light short (unchanged from the pulse it replaces).
        guard !ackHeld, let layer = ackBarLayer() else { return }
        ackStandDown?.cancel(); ackStandDown = nil

        let wasLit = layer.opacity > 0
        layer.removeAnimation(forKey: "ack")

        // Recolour visibly when the light is already up. Snapping the colour
        // would land in the same frame as the press and read as a flash — the
        // thing this design exists to avoid — so the change itself is animated
        // and IS the acknowledgment.
        if wasLit, layer.backgroundColor != what.color {
            let recolour = CABasicAnimation(keyPath: "backgroundColor")
            recolour.fromValue = layer.backgroundColor
            recolour.toValue = what.color
            recolour.duration = 0.18
            recolour.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(recolour, forKey: "ack-colour")
        }
        layer.backgroundColor = what.color
        layer.opacity = 1

        let standDown = DispatchWorkItem { [weak self] in
            // A hold that started inside the window owns the light now.
            guard let self, !self.ackHeld, let layer = self.ackBar?.layer else { return }
            layer.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = Self.ackFade
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "ack")
        }
        ackStandDown = standDown
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ackHold, execute: standDown)
        Permissions.log("ack: \(what.name) (visible=\(panel?.isVisible == true))")
    }

    /// Returns false when the stage refused (a reply flow is live) — the caller
    /// must not announce, or the audio would play against a panel that never
    /// changed. Pixels and voice obey the same table.
    @discardableResult
    func showPreparing() -> Bool {
        // The STAGE is claimed immediately — the refusal above is load-bearing,
        // and deferring it would let a reply flow be spoken over.
        guard transition(to: .preparing, because: "announce requested") else { return false }
        // The PIXELS are not. Measured over 118 announcements: p50 0s, p90 1s,
        // and only 5 ran past three seconds. A whole-card "Writing the summary
        // and fetching the voice…" for a wait that is usually imperceptible is
        // a loading screen charging rent on the common case — and now that both
        // the summary and its audio are prefetched, the common case is that
        // there is nothing to wait for at all.
        //
        // So it paints only if it is still true a quarter-second later. The
        // press is never unacknowledged in the meantime: the ⌃⌥ ack pulse
        // already fires on the keypress itself, independently of this.
        preparingPaint?.cancel()
        let paint = DispatchWorkItem { [weak self] in
            guard let self, case .preparing = self.state else { return }
            Permissions.log("preparing: still waiting at 250ms — painting the card")
            // One identity: no app-name masthead — the Preparing pill and the body
            // carry it. The callsign arrives with the announcement itself.
            self.face = Face(body: "Writing the summary and fetching the voice…")
            self.render()
        }
        preparingPaint = paint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: paint)
        return true
    }

    /// Armed by `showPreparing`, cancelled the moment anything else takes the
    /// stage — so a fast announcement never flashes a loading card on its way in.
    private var preparingPaint: DispatchWorkItem?

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
        // `notSent`, not `sent`: the whole point of the drill is that nothing was
        // sent, so the expectation is written here where it is known.
        SelfTest.report("pendingSend", [
            ("cancellable", cancellable), ("cancelled", cancelled), ("notSent", !sent),
        ])

        // And it must stay stopped: the timer should be dead, not merely ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            SelfTest.report("pendingSend.afterWindow", [("stillNotSent", !sent)])
            // Then stand the drill's card down. It is the only drill whose
            // assertion outlives the call that starts it, so it is the only one
            // that cannot clean up before returning — and for as long as its
            // card holds the stage, `pendingSend` refuses every transition the
            // launch tail and every ⌃⌥ afterwards ask for. Measured 08 Aug: a
            // relaunch left the app answering `announce: refused, reply flow on
            // stage` to every press, with ten drills reporting PASS above it.
            //
            // Conditional, because five seconds is long enough for a real
            // announcement to have taken the stage — and an unconditional
            // restore here would yank it off, which is the same bug
            // `returnToGridWork` guards against in main.swift.
            //
            // Through endCapture, not a bare repaint: pendingSend does not admit
            // idle (PanelState.admits), by design, so that a stale repaint can
            // never paint "Ready" over a live undo window. A drill standing its
            // own fixture down is not stale, which is exactly what the user door
            // is for — and it is also what cancels the countdown and drops the
            // send/cancel closures. A bare showIdle here logs a second REFUSED
            // and changes nothing; measured 08 Aug before this line existed.
            guard let self, case .pendingSend = self.state else { return }
            self.endCapture(because: "selftest pendingSend cleanup")
            self.showIdle(rows: [])
        }
    }

    /// Let an in-flight frame animation finish, then lay out. Drills measure
    /// geometry, and geometry is a lie while the animator is running.
    private func settleAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
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
                .init(id: "c", name: "tranquility base", callsign: "", lamp: .ready),
                .init(id: "d", name: "robertnowell-83",
                      callsign: "tranquility base synchronization",
                      lamp: .running),
            ]) }),
            ("preparing", { _ = self.showPreparing() }),
            ("announcement", { self.showAnnouncement(
                spoken: SpokenTextSanitizer().sanitize(long),
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
                .init(id: "b", name: "tranquility base", callsign: "", lamp: .running),
            ]) }),
            ("speaking", { self.showAnnouncement(
                spoken: SpokenTextSanitizer().sanitize(long),
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
            SelfTest.report("arm[\(label)]", [("armed", armed), ("restored", restored)])
            Permissions.log("selftest arm[\(label)] before:  \(before)")
            Permissions.log("selftest arm[\(label)] arming:  \(armingMatrix)")
            Permissions.log("selftest arm[\(label)] after:   \(after)")
        }
        // And the upgrade path: arming admits exactly one successor, listening.
        showArming(target: "promotions copy")
        showListening(level: { 0.3 })
        SelfTest.report("arm[upgrade]", [
            ("becameListening", state.name == "listening"),
            ("meterShown", !meter.isHidden),
        ])
        recordingEnded()
        endCapture(because: "selftest arm cleanup")

        // The ink drill (10 Aug). The defect: a card you have been reading
        // resets to unread grey the moment a capture repaints it, because the
        // ink lived in the pixels instead of the face. That is incident 1 of
        // docs/ruling-capture-returns-to-its-card.md — reported, specified, and
        // until now unbuilt. Arm-and-revert is the path that reproduces it with
        // today's API; it is also the path the capture strip is about to make
        // the MAIN path, which is why this lands before the strip and not with
        // it. Read from the pixels, never from `face.spokenUpTo` — asking the
        // field would only prove the field agrees with itself.
        let inkBody = "Finished the poller and the hero binding, then reran the "
            + "promotions suite; four cases still fail on the same null topic."
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize(inkBody),
            sessionId: "ink", pid: 1, project: "promotions copy", cwd: "/tmp")
        let inkFresh = inkBrightLength
        highlight(upTo: 40)
        let inkRead = inkBrightLength
        showArming(target: "promotions copy")
        let inkArmed = inkBrightLength
        revertArming(because: "selftest ink")
        let inkRestored = inkBrightLength
        SelfTest.report("ink", [
            ("freshCardStartsUnspoken", inkFresh == 0),
            ("readingLightsTheInk", inkRead > 0),
            ("survivesTheCapture", inkRestored == inkRead),
        ])
        Permissions.log("selftest ink: fresh=\(inkFresh) read=\(inkRead) "
                        + "armed=\(inkArmed) restored=\(inkRestored)")
        endCapture(because: "selftest ink cleanup")

        // The strip drill (10 Aug). The promise is one sentence — speaking to
        // an agent does not cost you the thing it said — so the assertions are
        // about the CARD, not about the strip: its identity, its ink and its
        // placard must be byte-identical on the other side of a capture. The
        // strip merely has to show up.
        let stripBody = "Reran the promotions suite after the binding fix; four "
            + "cases still fail on the same null topic."
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize(stripBody),
            sessionId: "strip", pid: 1, project: "promotions copy", cwd: "/tmp")
        highlight(upTo: 30)
        panel?.contentView?.layoutSubtreeIfNeeded()
        let cardTitle = titleLabel.stringValue
        let cardBody = bodyLabel.stringValue
        let cardPlacard = stateLabel.attributedStringValue.string
        let cardInk = inkBrightLength
        let topBefore = panel?.frame.maxY ?? 0

        showArming(target: "promotions copy")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let armedKeepsCard = titleLabel.stringValue == cardTitle
            && bodyLabel.stringValue == cardBody && !titleLabel.isHidden
        let armedKeepsPlacard = stateLabel.attributedStringValue.string == cardPlacard
        let armedInk = inkBrightLength
        let armedStrip = !stripLabel.isHidden && !stripRule.isHidden

        showListening(level: { 0.3 })
        panel?.contentView?.layoutSubtreeIfNeeded()
        let listeningInk = inkBrightLength
        let listeningStrip = !stripLabel.isHidden
        let topDuring = panel?.frame.maxY ?? 0

        // Through transcribing, because that is the real order and the
        // legality table enforces it: `.listening` does not admit
        // `.pendingSend`. The first version of this drill skipped the step and
        // the refusal made the read-back assertion fail for the wrong reason.
        showTranscribing("Transcribing your reply…", onCancel: {}, onRetry: {})
        panel?.contentView?.layoutSubtreeIfNeeded()
        let transcribingInk = inkBrightLength
        let transcribingStrip = !stripLabel.isHidden
        showPendingSend(text: "ship it", label: "promotions copy",
                        seconds: 60, send: {}, cancel: { _ in })
        panel?.contentView?.layoutSubtreeIfNeeded()
        let readbackInStrip = stripLabel.stringValue.contains("ship it")
        let readbackKeepsCard = bodyLabel.stringValue == cardBody
        let readbackInk = inkBrightLength
        let topAfter = panel?.frame.maxY ?? 0
        _ = cancelPendingSend(restartListening: false)
        endCapture(because: "selftest strip cleanup")

        // §E: a capture begun from the grid has nothing to sit under, so the
        // strip is the whole panel — the behaviour that shipped, unchanged.
        showIdle(note: nil, rows: [
            .init(id: "s1", name: "Fix hero image binding",
                  callsign: "promotions copy", lamp: .ready),
        ])
        showArming(target: "promotions copy")
        let gridCaptureIsWholePanel = stripLabel.isHidden && titleLabel.isHidden
        endCapture(because: "selftest strip grid cleanup")

        SelfTest.report("strip", [
            ("cardSurvivesArming", armedKeepsCard),
            ("placardSurvives", armedKeepsPlacard),
            ("inkSurvivesArming", armedInk == cardInk),
            ("inkSurvivesListening", listeningInk == cardInk),
            ("inkSurvivesReadback", readbackInk == cardInk),
            ("stripAppears", armedStrip && listeningStrip && transcribingStrip),
            ("inkSurvivesTranscribing", transcribingInk == cardInk),
            ("readbackJoinsTheStrip", readbackInStrip && readbackKeepsCard),
            ("gridCaptureIsWholePanel", gridCaptureIsWholePanel),
        ])
        // Logged, not asserted: an animated resize may be in flight, so the
        // live frame is a transient and an equality here would be flaky. The
        // top edge is `visibleFrame.maxY - 16` by construction (`position`),
        // and these three lines are how a regression in that would be seen.
        Permissions.log("selftest strip: ink=\(cardInk) top \(topBefore)"
                        + " -> \(topDuring) -> \(topAfter)")

        // The receipt drill. A chip outside the render funnel has to prove it
        // cleans up after itself, because no arm of render() will do it: this
        // is the residue class the arbiter exists to make impossible, and the
        // receipt is the one widget deliberately outside that guarantee.
        showIdle(note: nil, rows: [])
        let matrixBefore = widgetMatrix()
        showReceipt(.sending("promotions copy"))
        let shownWhileVisible = receiptIsShowing
        // The chip shares the top band with the placard and the gear, so a
        // long callsign must truncate rather than run under either. The log
        // line above carries the rendered text for inspection.
        showReceipt(.sending("bookmarks provenance track a rebuild"))
        showReceipt(.sent)
        // A state change must not be disturbed BY the receipt, nor clear it:
        // it floats over the top band and owns no layout.
        showResult("A failure card, arriving under a live receipt.")
        let matrixUnderReceipt = widgetMatrix()
        dismiss()
        let clearedByDismiss = !receiptIsShowing
        // And a receipt must never surface a hidden panel — a send landing is
        // not a summons.
        hide()
        showReceipt(.sent)
        let refusedWhileHidden = !receiptIsShowing
        // layoutUndisturbed is deliberately NOT a check: showResult changed the
        // state in between, so the matrices are expected to differ and comparing
        // them asserts nothing. Logged as context, never as a verdict — a gate
        // that fails on an unobservable is a gate that gets disabled.
        SelfTest.report("receipt", [
            ("shown", shownWhileVisible),
            ("clearedByDismiss", clearedByDismiss),
            ("refusedWhileHidden", refusedWhileHidden),
        ])
        Permissions.log("selftest receipt context: layoutComparable="
                        + "\(matrixBefore == matrixUnderReceipt)")

        // The stomp that froze the app (2026-08-05): a stale idle repaint against a
        // live capture. Must be REFUSED, and the pill must still be on the walls.
        showListening(level: { 0.4 })
        showIdle(rows: [.init(id: "a", name: "promotions copy", callsign: "", lamp: .ready),
                        .init(id: "b", name: "syndit", callsign: "", lamp: .ready)])
        let survived = state.isCapturingAudio && !meter.isHidden
        SelfTest.report("legality", [("idleOverListeningRefused", survived)])
        recordingEnded()
        // Through the user door, exactly as a real abort must go — showIdle alone
        // is (correctly) refused from a capture state.
        endCapture(because: "selftest cleanup")
        showIdle(rows: [])

        // The collapsed strip. Three properties, and the third is the ruling.
        let mixed: [StateLegend.SessionRow] = [
            .init(id: "a", name: "promotions copy", callsign: "promotions", lamp: .ready),
            .init(id: "b", name: "syndit", callsign: "syndit", lamp: .running),
            .init(id: "c", name: "tranquility base", callsign: "tbase", lamp: .working),
            .init(id: "d", name: "kopi", callsign: "kopi", lamp: .running),
            .init(id: "e", name: "bookmarks", callsign: "bookmarks", lamp: .fault),
        ]
        // The drill must not spend the user's preference. `isCollapsed` is
        // durable, `relaunch.sh` runs the selftests on EVERY deploy, and the
        // first version of this ended on setCollapsed(false) — so every relaunch
        // silently expanded a panel the user had collapsed, and wrote that back
        // to disk. Saved and restored.
        let widthBeforeDrill = isCollapsed
        defer { setCollapsed(widthBeforeDrill) }
        setCollapsed(false)
        showIdle(rows: mixed)
        settleAnimations()
        let expandedRightEdge = panel?.frame.maxX ?? 0
        let expandedLeftEdge = panel?.frame.minX ?? 0
        Permissions.log("collapse drill: expanded \(panel.map { NSStringFromRect($0.frame) } ?? "-")")
        setCollapsed(true)
        showIdle(rows: mixed)
        // The morph is animated, so the frame is a transient for ~0.16s. Let it
        // land before measuring — a drill that reads mid-animation measures
        // nothing, which is how the first version passed on a broken panel.
        settleAnimations()
        // Idle lamps do not appear collapsed: five rows in, three are live.
        let idleLampsOmitted = collapsedLampCount == 3
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
        // In a WINDOW, not merely un-hidden. The first version asserted
        // `!isHidden`, which is true of a view that was added to a content view
        // AppKit had already thrown away — so the drill passed on a strip that
        // had never been on screen once.
        let stripShown = collapsedIsOnScreen
        let collapsedSize = panel.map {
            abs($0.frame.width - CollapsedStrip.width) < 1
                && abs($0.frame.height - CollapsedStrip.height) < 1
        } ?? false
        // ON the display, entirely. The bug this exists for put a 380pt window
        // at `maxX - 40`, hanging 340pt into nowhere; every other property here
        // passed while it did.
        let onScreen = panel.map { p in
            NSScreen.main.map { p.frame.maxX <= $0.visibleFrame.maxX + 1
                && p.frame.minX >= $0.visibleFrame.minX - 1 } ?? false
        } ?? false
        let collapsedWidthReal = abs((panel?.frame.width ?? 0) - CollapsedStrip.width) < 1
        Permissions.log("collapse drill: collapsed \(panel.map { NSStringFromRect($0.frame) } ?? "-")")
        // The right edge does not move when the width does. Flush-to-the-screen
        // was the first version and was wrong: "keep the right edge in the same
        // place that it is right now and just animate the collapse."
        let rightEdgeHeld = abs((panel?.frame.maxX ?? 0) - expandedRightEdge) < 1
        // An arrival must not change the width. This is ruling 1 reached from
        // the other side — the app does not open the panel for you, and it does
        // not widen it for you either.
        let widthBefore = panel?.frame.width ?? 0
        showIdle(rows: mixed + [.init(id: "f", name: "new one", callsign: "new", lamp: .ready)])
        let widthHeldOnArrival = abs((panel?.frame.width ?? 0) - widthBefore) < 1
        setCollapsed(false)
        showIdle(rows: mixed)
        settleAnimations()
        // The bug the user reported: expanding out of the strip left the left
        // edge where the strip's was, so 340pt of grid hung off the display.
        Permissions.log("collapse drill: reexpanded \(panel.map { NSStringFromRect($0.frame) } ?? "-") "
            + "wantLeft=\(Int(expandedLeftEdge)) intendedH=\(Int(intendedHeight ?? -1))")
        let expandRestoredLeft = abs((panel?.frame.minX ?? 0) - expandedLeftEdge) < 2
        let expandedAgain = !collapsedIsOnScreen
        // The glow is a TRANSIENT. A version that persisted until acknowledged
        // would be the notification badge this product exists to avoid, so the
        // drill asserts it decays to nothing on its own clock.
        setCollapsed(true)
        showIdle(rows: mixed)
        let realGlow = CollapsedStrip.glowSeconds
        CollapsedStrip.glowSeconds = 0.2
        defer { CollapsedStrip.glowSeconds = realGlow }
        flashArrival(.ready)
        let glowLit = collapsedGlowStrength > 0
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        let glowDecayed = collapsedGlowStrength == 0
        setCollapsed(false)
        flashArrival(.ready)
        let glowIgnoredWhenExpanded = collapsedGlowStrength == 0
        setCollapsed(true)
        showIdle(rows: mixed)
        settleAnimations()

        // Ruling 1, from the panel's side: a dismissed panel is not raised by
        // anything the idle face does. The arrival path guards on `isOnScreen`,
        // and this pins the property the guard depends on — that `showIdle`
        // WOULD raise it, so the guard is load-bearing rather than decorative.
        setCollapsed(false)
        showIdle(rows: mixed)
        dismiss()
        let wentAway = !isOnScreen
        showIdle(rows: mixed)
        let showIdleDoesRaise = isOnScreen
        dismiss()
        let dismissedAgain = !isOnScreen
        setCollapsed(true)
        showIdle(rows: mixed)
        settleAnimations()

        SelfTest.report("collapsed", [
            ("idleLampsOmitted", idleLampsOmitted),
            ("stripShown", stripShown),
            ("collapsedWidthReal", collapsedWidthReal),
            ("entirelyOnScreen", onScreen),
            ("rightEdgeHeld", rightEdgeHeld),
            ("expandRestoresTheLeftEdge", expandRestoredLeft),
            ("widthHeldOnArrival", widthHeldOnArrival),
            ("expandRestoresTheGrid", expandedAgain),
            ("glowLit", glowLit),
            ("glowDecayedOnItsOwn", glowDecayed),
            ("glowOnlyWhenCollapsed", glowIgnoredWhenExpanded),
            ("dismissTakesItAway", wentAway && dismissedAgain),
            ("showIdleWouldRaise", showIdleDoesRaise),
        ])
        showIdle(rows: [])

        // The notice: takes the strip on the grid, refused onto a card, and
        // cleared by the move to one. Nothing outside its own clock clears it,
        // so it has to prove it does not leak — same burden as the receipt.
        flashNotice(StateLegend.noWordsNotice)
        let noticedOnGrid = noticeIsShowing
            && stateLabel.attributedStringValue.string == StateLegend.noWordsNotice
        showResult("A card arriving over a notice.")
        let clearedByCard = !noticeIsShowing
        flashNotice(StateLegend.noWordsNotice)
        let refusedOnCard = !noticeIsShowing
        SelfTest.report("notice", [
            ("onGrid", noticedOnGrid),
            ("clearedByCard", clearedByCard),
            ("refusedOnCard", refusedOnCard),
        ])
        // And the leak the two transition doors close: a notice must not survive
        // a hide and come back up with the panel. `.hidden` returns out of
        // render() before its body runs, so nothing down there can retire it.
        showIdle(rows: [])
        flashNotice(StateLegend.noWordsNotice)
        hide()
        let clearedByHide = !noticeIsShowing
        showIdle(rows: [])
        let stayedGone = !noticeIsShowing


        // The device fault: the ONE failure card with a door out. Ordinary
        // failures must not grow one.
        showDeviceFault("Nothing arrived from the input device.")
        let faultOffersDoor = !micSettingsButton.isHidden && titleLabel.isHidden
        showResult("An ordinary failure, which has nowhere to send you.")
        let plainFailureHasNoDoor = micSettingsButton.isHidden
        SelfTest.report("notice.leak", [
            ("clearedByHide", clearedByHide),
            ("stayedGone", stayedGone),
            ("faultOffersDoor", faultOffersDoor),
            ("plainFailureHasNoDoor", plainFailureHasNoDoor),
        ])

        // The invitation (10 Aug). It waits like a failure and must not look
        // like one: the one card in `.result` that speaks on the advisory
        // channel. The drill asserts both halves, because the amber is what
        // would make a stranger's first sight of this app read as an error.
        showNewSessionInvitation(artifact: "plan.html",
                                 directory: "~/Projects/tranquility-base",
                                 ref: "/tmp/plan.html")
        let invitationOffersTheDoor = !newSessionButton.isHidden
        let invitationIsAdvisory =
            stateLabel.textColor == StateLegend.Lens.advisory.color
        let invitationNamesNoAgent = titleLabel.isHidden
        let invitationNamesTheArtifact = bodyLabel.stringValue.contains("plan.html")
        showResult("An ordinary failure, which starts nothing.")
        let failureStartsNothing = newSessionButton.isHidden
        let failureIsStillAmber =
            stateLabel.textColor == StateLegend.Palette.fault
        // The card's second door. The drill that matters is the ABSENCE one:
        // most sessions have written no page, and a door to nothing would be on
        // every card in the app.
        let priorResolver = artifactForSession
        artifactForSession = { _ in nil }
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("Finished the poller. Go?"),
            sessionId: "drill", pid: 1, project: "promotions copy", cwd: "/tmp")
        let noPageNoDoor = openPageButton.isHidden
        artifactForSession = { _ in "/tmp/tb-drill-page.html" }
        render()
        let pageOpensADoor = !openPageButton.isHidden
        artifactForSession = priorResolver
        SelfTest.report("openPage", [
            ("noPageNoDoor", noPageNoDoor),
            ("pageOpensADoor", pageOpensADoor),
        ])

        SelfTest.report("invitation", [
            ("offersTheDoor", invitationOffersTheDoor),
            ("advisoryNotAmber", invitationIsAdvisory),
            ("namesNoAgent", invitationNamesNoAgent),
            ("namesTheArtifact", invitationNamesTheArtifact),
            ("failureStartsNothing", failureStartsNothing),
            ("failureIsStillAmber", failureIsStillAmber),
        ])
        // The empty room. Its ten seconds are backdated rather than waited out —
        // the clock is a timestamp precisely so it can be reasoned about without
        // a ten-second drill — but everything after the clock is the real path:
        // the same showIdle every ambient tick calls, painting the real panel.
        showIdle(rows: [])
        let describesItselfFirst = !face.gettingStarted
            && titleLabel.stringValue == "Tranquility Base"
        emptySince = Date().addingTimeInterval(-StateLegend.gettingStartedAfter - 1)
        showIdle(rows: [])
        let teaches = face.gettingStarted
            && bodyLabel.stringValue == StateLegend.gettingStartedMessage
            && titleLabel.isHidden && stateLabel.isHidden
            && bodyLabel.alignment == .center
        // The ruling's other half: this surface spells the keys out. A glyph
        // creeping back in is the failure the drill is here to catch.
        let spelledOut = !StateLegend.gettingStartedMessage.contains("⌃")
            && !StateLegend.gettingStartedMessage.contains("⌥")
        // An agent reporting in takes the room back, and the ambient repaint
        // that follows must not inherit the big centred type.
        showIdle(rows: [StateLegend.SessionRow(
            id: "drill", name: "an agent arrives", callsign: "drill", lamp: .ready)])
        let roomTakenBack = !face.gettingStarted && emptySince == nil
            && bodyLabel.alignment == .natural
        SelfTest.report("emptyRoom", [
            ("describesItselfFirst", describesItselfFirst),
            ("teachesAfterTheClock", teaches),
            ("spelledOutNotGlyphs", spelledOut),
            ("roomTakenBack", roomTakenBack),
        ])

        contrastDrill()
        titleDoorDrill()
        quietRowsDrill()

        endCapture(because: "selftest cleanup")
        showIdle(rows: [])
    }

    /// Quiet rows sink, and the active band keeps the order it arrived in.
    ///
    /// The ordering itself is a pure function on an array, so the interesting
    /// half is not "does idle go last" — it is that nothing ELSE moves. The
    /// bands feeding it are recency-ordered, and a partition that quietly
    /// reshuffled ties would spend that ordering without any visible symptom.
    /// So the drill checks positions, not just the tail.
    private func quietRowsDrill() {
        func row(_ id: String, _ lamp: StateLegend.Lamp) -> StateLegend.SessionRow {
            StateLegend.SessionRow(id: id, name: id, callsign: id, lamp: lamp)
        }
        // Deliberately interleaved, and with two of each active lamp, so a
        // comparator that grouped by lamp rather than partitioning would fail.
        let mixed = [row("w1", .working), row("i1", .running), row("r1", .ready),
                     row("i2", .running), row("f1", .fault), row("w2", .working)]
        let sorted = StateLegend.quietRowsLast(mixed).map(\.id)

        SelfTest.report("quietRows", [
            ("quietLast", sorted.suffix(2) == ["i1", "i2"]),
            ("activeKeepsArrivalOrder", Array(sorted.prefix(4)) == ["w1", "r1", "f1", "w2"]),
            ("nothingLost", sorted.count == mixed.count),
            ("allQuietIsStillAllQuiet",
             StateLegend.quietRowsLast([row("i1", .running), row("i2", .running)])
                .map(\.id) == ["i1", "i2"]),
        ])
    }

    /// The identity opens the tab — but only when there is a tab.
    ///
    /// The door is derived from `currentTarget`, not stored per face, which is
    /// correct only for as long as `currentTarget` is nil on every face whose
    /// title is not a session. That is true today (idle and showVoices both
    /// clear it) and it is the kind of thing that stops being true quietly. So
    /// it is asserted rather than trusted: a title that offers to open a tab
    /// that is not there would fail at the click, which is the worst place to
    /// find out.
    ///
    /// Also asserts the topic line stays dead. It was removed because it said
    /// the body's own sentence with the detail taken out, and it is exactly the
    /// sort of thing a later pass restores meaning well.
    private func titleDoorDrill() {
        var checks: [(String, Bool)] = []

        currentTarget = ("drill", 1, "promotions copy")
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("Finished the poller. Go?"),
            sessionId: "drill", pid: 1, project: "promotions copy", cwd: "/tmp")
        checks.append(("sessionTitleIsADoor", titleLabel.isADoor))
        checks.append(("titleIsOneLine", titleLabel.maximumNumberOfLines == 1))
        // The identity, alone. A second line here is the topic coming back.
        checks.append(("noSecondLine", !titleLabel.stringValue.contains("\n")))

        showSettings(voices: [], roster: [], note: "")
        checks.append(("settingsTitleIsNotADoor", !titleLabel.isADoor))

        showIdle(rows: [])
        checks.append(("idleClearsTheTarget", currentTarget == nil))

        SelfTest.report("titleDoor", checks)
    }

    /// Assert the palette still measures what the ruling says it measures.
    ///
    /// This drill renders nothing. It exists because every other drill here
    /// checks that the panel LAID OUT correctly, and a colour that has slipped
    /// under its contrast floor lays out perfectly — it just cannot be read. The
    /// light console shipped `faint` at 2.13:1 and `fault` at 1.72:1 for its
    /// entire life, through every one of these self-tests, because nothing was
    /// looking.
    ///
    /// Four things are asserted, and the last two are the ones that catch drift
    /// rather than typos:
    ///  - every token clears its own floor against the surface;
    ///  - the lamps stay far enough apart in LIGHTNESS to be told apart at 9px;
    ///  - the ink ramp stays ORDERED — ink more legible than secondary, than
    ///    muted, than hint. A single warmed hex can silently invert two tiers,
    ///    and an inverted ramp is a hierarchy that lies;
    ///  - `hint` outranks `faint`, which is the entire point of having split
    ///    them. Re-merging them by accident is how the mushy key line comes back.
    private func contrastDrill() {
        let surface = StateLegend.Palette.surface
        var checks: [(String, Bool)] = []

        for token in StateLegend.contrastFloors {
            let ratio = StateLegend.Measure.contrast(token.ink, surface)
            checks.append(("\(token.name)≥\(token.floor)", ratio >= token.floor))
            Permissions.log(String(
                format: "contrast: %@ = %.2f:1 (floor %.1f) L*=%.1f",
                token.name, ratio, token.floor,
                StateLegend.Measure.lightness(token.ink)))
        }

        let lampGap = StateLegend.Measure.lightnessGap(
            StateLegend.Palette.ready, StateLegend.Palette.working)
        checks.append(("lampΔL*≥\(StateLegend.lampLightnessFloor)",
                       lampGap >= StateLegend.lampLightnessFloor))

        // Ready is the rare lamp that wants you; working is the common one that
        // is only news. On a dark ground that ordering is expressible, and the
        // busy panel was ruled on it — so it is worth defending.
        let readyOutshinesWorking =
            StateLegend.Measure.contrast(StateLegend.Palette.ready, surface)
            > StateLegend.Measure.contrast(StateLegend.Palette.working, surface)
        checks.append(("readyOutshinesWorking", readyOutshinesWorking))

        let ramp = [StateLegend.Palette.ink, StateLegend.Palette.secondary,
                    StateLegend.Palette.muted, StateLegend.Palette.hint]
            .map { StateLegend.Measure.contrast($0, surface) }
        checks.append(("inkRampOrdered", zip(ramp, ramp.dropFirst()).allSatisfy { $0 > $1 }))

        checks.append(("hintOutranksFaint",
                       StateLegend.Measure.contrast(StateLegend.Palette.hint, surface)
                       > StateLegend.Measure.contrast(StateLegend.Palette.faint, surface)))

        // The tick is punched out of the lamp, not the panel, so it is the one
        // pair here measured against something other than the surface. It was a
        // hardcoded near-white until 09 Aug and would have gone invisible at
        // 1.88:1 on the brighter green.
        checks.append(("checkmarkOnReady≥3",
                       StateLegend.Measure.contrast(surface, StateLegend.Palette.ready) >= 3.0))

        Permissions.log(String(format: "contrast: lamp ΔL* = %.1f", lampGap))
        SelfTest.report("contrast", checks)
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
            let findings = SpokenTextSanitizer().sanitize(
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
                      callsign: "promotions copy", lamp: .ready),
                .init(id: "s2", name: "Render pose driver states",
                      callsign: "tranquility base recording", lamp: .ready),
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

        case "needsyou":
            adopt()
            showResult("promotions copy's tab is gone — copied your words to the clipboard.")

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
                .init(id: "a", name: "promotions copy", callsign: "promotions", lamp: .ready),
                .init(id: "b", name: "tranquility base", callsign: "tbase", lamp: .working),
                .init(id: "c", name: "bookmarks", callsign: "bookmarks", lamp: .fault),
            ])
            return true

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
            ("dontSend", dontSendButton), ("micSettings", micSettingsButton),
            ("newSession", newSessionButton), ("openPage", openPageButton),
            ("voices", voiceList),
            ("gear", gearButton), ("back", backButton), ("rows", waitingRows),
            ("cancelTx", cancelTranscriptionButton),
            ("retryTx", retryTranscriptionButton),
        ]
        return widgets.map { "\($0.0)=\($0.1?.isHidden == false ? "1" : "0")" }
            .joined(separator: " ")
    }

    /// Animate the panel between its two widths, holding the right edge still.
    ///
    /// Held, not recomputed: the expanded face sits at `maxX - width - 16`, and
    /// a collapse that recomputes from the NEW width would slide the panel
    /// rightwards as it narrows. Taking the current right edge and keeping it is
    /// what makes this read as one panel getting thinner rather than a second
    /// panel appearing somewhere else.
    private func morph(_ panel: NSPanel, to size: NSSize) {
        let width = size.width
        var frame = panel.frame
        guard abs(frame.width - width) > 0.5 || abs(frame.height - size.height) > 0.5
        else { return }
        frame.size.height = size.height
        // The right edge is computed, not inherited. Holding the CURRENT edge
        // reads well while the panel is already placed and fails completely when
        // it is not: a launch that starts collapsed morphs the default
        // {{0,0},{380,150}} rect and lands at {{340, 0}, {40, 150}} — bottom
        // left, off the working area entirely.
        //
        // Every face sits at `visibleFrame.maxX - width - 16`, so its right edge
        // is always `maxX - 16`. Computing that is identical to holding it, and
        // it is also correct before the panel has ever been on screen.
        if let screen = NSScreen.main {
            frame.origin.x = screen.visibleFrame.maxX - width - 16
            frame.origin.y = screen.visibleFrame.maxY - frame.height - 16
        } else {
            frame.origin.x = frame.maxX - width
        }
        frame.size.width = width
        intendedHeight = frame.height
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        // Collapsed owns its own frame, flush to the edge, and `resizeToFit`
        // has already set it. Returning here rather than special-casing the
        // margin below: this runs immediately AFTER that call on every render,
        // so a margin applied here silently undoes it — which is exactly what
        // the flushRight drill caught on the first deploy.
        let margin: CGFloat = 16
        // No special case for the collapsed strip. It is placed from its own
        // width like every other face, which is what makes its right edge line
        // up with the grid's — and, unlike a panel that positions itself, works
        // on the very first paint before it has ever been on screen.
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
        // 12 → 8 (ruled 06 Aug: "do we want this strong of corner rounding? It
        // seems very default"). 8 is the instrument radius — a milled panel
        // edge, not a system alert.
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        // The ack bar lives INSIDE the clipping surface (06 Aug: "it gets cut
        // off at the start of the corner round"). Full width, clipped by the
        // same rounded mask as the console itself, so its ends taper with the
        // corner instead of colliding with it.
        surfaceView = background

        // Widgets carry no initial visibility: build() is only reached from
        // render(), which writes every widget's visibility before the panel is
        // ever ordered front.
        stateLabel = NSTextField(labelWithString: "")
        stateLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        stateLabel.textColor = StateLegend.Lens.chrome.color
        // The ◀ breadcrumb is clickable (ruled 06 Aug): voiced first, but a
        // pointer tap goes home too. The gesture is on the label always; the
        // handler lets only card states through, so the AGENTS strip and the
        // pills never react.
        stateLabel.addGestureRecognizer(NSClickGestureRecognizer(
            target: self, action: #selector(breadcrumbClicked)))

        titleLabel = DoorLabel(labelWithString: "")
        // The identity face: mono, matching the grid rows (ruled). renderTitle
        // sets the string; this is the fallback style. ONE line since the topic
        // died (10 Aug) — the identity was always the only thing on line one.
        titleLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = StateLegend.Lens.content.color
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        // The second door to the session. GO TO AGENT stays — it is the
        // discoverable one, and you said you use it. This is the shortcut for
        // when your eye is already on the name, which is where it already goes.
        titleLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(goToSession)))

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
            color: StateLegend.Palette.accent)
        // "Open HTML" shares "Go to agent"'s treatment — same kind of move,
        // leave this panel and go to the thing — and differs only in
        // destination: one is a terminal tab, the other a browser. It sits at
        // the row's LEADING edge rather than beside it: the two doors bracket
        // the card, so neither reads as the primary and a mis-click lands on
        // nothing. Named for the file it opens rather than for "page", which
        // named nothing the user had a word for.
        openPageButton = NSButton(title: "Open HTML", target: self,
                                  action: #selector(openPageTapped))
        openPageButton.isBordered = false
        openPageButton.attributedTitle = letterspaced(
            "OPEN HTML \(StateLegend.Glyph.forward)", size: 10.5, tracking: 1.3,
            color: StateLegend.Palette.accent)
        dontSendButton = quietAction("Don't send", #selector(cancelPendingSendTapped))
        // The device-fault card's way out. Quiet like its row-mates: it is a
        // door, not an alarm — the placard and the body have already said how
        // bad this is, and a loud button would say it a third time.
        micSettingsButton = quietAction(StateLegend.micSettingsTitle,
                                        #selector(micSettingsTapped))
        // The invitation's action. Quiet like its row-mates, and deliberately
        // NOT go-green: "Go to agent" navigates to something that exists, and
        // this one creates it. Sharing the promoted ink would make the two
        // read as the same move.
        newSessionButton = quietAction(StateLegend.startSessionTitle,
                                       #selector(newSessionForArtifactTapped))

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
        buttons.addView(openPageButton, in: .leading)
        buttons.addView(dontSendButton, in: .leading)
        buttons.addView(micSettingsButton, in: .leading)
        buttons.addView(newSessionButton, in: .leading)
        buttons.addView(cancelTranscriptionButton, in: .leading)
        buttons.addView(retryTranscriptionButton, in: .leading)
        buttons.addView(goButton, in: .trailing)

        hintLabel.maximumNumberOfLines = 0
        hintLabel.lineBreakMode = .byTruncatingMiddle

        // The strip's own furniture. The rule is what makes the capture read as
        // an extension of the panel rather than another paragraph of the card —
        // and it is hidden with the label, so a face with no capture has no
        // orphan line across it.
        stripLabel = NSTextField(labelWithString: "")
        stripLabel.font = .systemFont(ofSize: 11)
        stripLabel.textColor = StateLegend.Palette.hint
        stripLabel.maximumNumberOfLines = 2
        stripLabel.lineBreakMode = .byTruncatingHead
        stripRule = NSView()
        stripRule.wantsLayer = true
        stripRule.layer?.backgroundColor = StateLegend.Palette.hairline.cgColor
        stripRule.translatesAutoresizingMaskIntoConstraints = false
        stripRule.heightAnchor.constraint(equalToConstant: 1).isActive = true

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

        // The strip's furniture sits BELOW the body and above the meter, so a
        // capture extends the panel downward and the card above it does not
        // move (ruled 10 Aug: "extend below, not move everything down by
        // inserting above"). The panel already grows this way — `position`
        // anchors the top edge — so the strip costs no geometry work.
        let stack = NSStackView(views: [backButton, stateLabel, titleLabel,
                                        waitingRows, bodyLabel,
                                        stripRule, stripLabel,
                                        countdownBar, meter, voiceList, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        background.addSubview(gearButton)

        // Collapse lives on the panel, left of the gear. It was in the menu bar
        // first, which was wrong twice over: clicking the status item already
        // opens the panel, so "Show panel" was a second door to one room, and a
        // control for shrinking the panel belongs on the panel rather than two
        // clicks away in a menu you have to know is there.
        collapseButton = NSButton(
            // A chevron, ruled over the standard sidebar glyph. The sidebar
            // symbol carries a rectangle that reads as a second panel edge
            // inside a panel that already has one, and at 12pt against a 10pt
            // letterspaced title it was the heaviest thing in the strip. The
            // chevron says direction and nothing else, which is all this does —
            // and it matches the one the collapsed strip shows for Expand, so
            // the pair reads as one control pointing two ways.
            image: NSImage(systemSymbolName: "chevron.right",
                           accessibilityDescription: "Collapse")!
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))!,
            target: self, action: #selector(collapseTapped))
        collapseButton.isBordered = false
        collapseButton.contentTintColor = StateLegend.Lens.chrome.color
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        collapseButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        background.addSubview(collapseButton)
        NSLayoutConstraint.activate([
            collapseButton.centerYAnchor.constraint(equalTo: gearButton.centerYAnchor),
            // FAR LEFT, not beside the gear. The top-right of the panel is the
            // receipt's — "→ SENDING", "▶ SENT" — and a second control parked
            // there is a collision waiting for the next send, which is exactly
            // what it looked like. The two corners now own one thing each.
            collapseButton.leadingAnchor.constraint(equalTo: background.leadingAnchor,
                                                    constant: 10),
        ])
        // Held, so collapsing can DEACTIVATE them. The stack pins the panel to
        // 380pt through these; leaving them active while narrowing the window is
        // what snapped the frame back to 380 and threw it off the display.
        stackEdges = [
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ]
        NSLayoutConstraint.activate(stackEdges + [
            bodyLabel.widthAnchor.constraint(equalToConstant: 348),
            hintLabel.widthAnchor.constraint(equalToConstant: 348),
            stripLabel.widthAnchor.constraint(equalToConstant: 348),
            stripRule.widthAnchor.constraint(equalToConstant: 348),
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

        // The strip lives beside the stack rather than inside it: it owns the
        // whole panel when it is up, and nesting it would put the grid's
        // spacing and insets between it and the edges it is flush against.
        let column = CollapsedStrip(frame: NSRect(x: 0, y: 0,
                                                  width: CollapsedStrip.width,
                                                  height: CollapsedStrip.height))
        column.onExpand = { [weak self] in self?.setCollapsed(false) }
        column.onDismiss = { [weak self] in self?.dismiss() }
        column.onNewAgent = { [weak self] in
            MainActor.assumeIsolated { self?.onNewSession?() }
        }
        column.onPick = { [weak self] id in
            MainActor.assumeIsolated { self?.onPickWaiting?(id) }
        }
        panel.contentView = background
        self.expandedRoot = background

        // Inside the SAME rounded background as the grid. Collapsing morphs one
        // panel; it does not swap one window's contents for another's. The
        // radius, the fill and the shadow are the panel's, not the face's.
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isHidden = true
        background.addSubview(column)
        stripEdges = [
            column.topAnchor.constraint(equalTo: background.topAnchor),
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ]
        self.strip = column
        self.panel = panel
        return panel
    }

    @objc private func collapseTapped() { setCollapsed(true) }

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
        // The voice counts in the text it is saying; the card is showing the
        // unredacted text. Where they differ the translation is exact inside
        // ordinary prose and atomic across a name — the whole of
        // `dispatchAttempts` lights the moment "a variable" starts.
        let cursor = currentSpoken?.displayIndex(forSpoken: index) ?? index
        Permissions.log("highlight upTo=\(index)→\(cursor) of \(body.count) "
                        + "thread=\(Thread.isMainThread)")
        // The mapped cursor rides the face from here on. Stored BEFORE the
        // paint, so a face read mid-paint is never behind its own pixels.
        face.spokenUpTo = cursor
        paintInk(displayCursor: cursor)
    }

    /// Paint the body at a display-space cursor. The painting half of
    /// `highlight(upTo:)`, split out so `render()` can repaint a face's ink
    /// without pretending a word event just arrived — the mapping is the part
    /// that must happen once, at the event; the painting must happen on every
    /// repaint or the ink is only as durable as the last paint.
    private func paintInk(displayCursor cursor: Int) {
        guard let body = bodyLabel?.stringValue, !body.isEmpty else { return }
        let clamped = max(0, min(cursor, body.count))
        // The first real word is the only "it started" signal anyone needs, and
        // it is a better one than any spinner: the wash gives way to the thing
        // it was standing in for.
        if clamped > 0 { stopBodyShimmer() }
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

        Permissions.log("highlight rendered bright=\(inkBrightLength)/\(full.length)")
    }

    /// How many characters are currently painted as spoken. Read from the
    /// PIXELS, not from `face.spokenUpTo` — a drill that asked the field would
    /// only prove the field agrees with itself, and the defect being guarded
    /// against is precisely the pixels disagreeing with the face.
    private var inkBrightLength: Int {
        guard let attributed = bodyLabel?.attributedStringValue else { return 0 }
        var bright = 0
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(Self.spokenMark, in: full) { value, range, _ in
            if value != nil { bright += range.length }
        }
        return bright
    }

    // MARK: - Waiting for the voice

    private var shimmerLayer: CAGradientLayer?
    private var shimmerArm: DispatchWorkItem?

    /// A wash that travels across the unspoken text while its audio is still
    /// being fetched.
    ///
    /// It is a SWEEP, not a pulse and not a glow on the first word, and the
    /// direction is the same one the read-along will travel in a moment. That
    /// is the whole argument: a point of light on the first word reads as a
    /// badge — something wrong, or something to click — while a wash moving
    /// left to right is the gesture the highlight itself is about to make, so
    /// it says "the reading starts here, shortly" without a word of text.
    ///
    /// Not blue. Blue in this card already means GO TO AGENT, and a second blue
    /// is a second meaning. This is the card's own ink at low alpha, so the
    /// dimmed text simply brightens as the wash passes and settles back.
    ///
    /// Armed at 400ms, never sooner: below that a person cannot tell a shimmer
    /// from a flicker, and with the clip usually prefetched most announcements
    /// will now start speaking before this ever draws a frame.
    private func armBodyShimmer() {
        shimmerArm?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startBodyShimmer() }
        shimmerArm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func startBodyShimmer() {
        guard case .speaking = state, shimmerLayer == nil,
              let host = bodyLabel, !host.stringValue.isEmpty else { return }
        host.wantsLayer = true
        guard let hostLayer = host.layer, host.bounds.width > 0 else { return }

        // The FIRST WORD only (Robert, 08 Aug). The first version washed the
        // whole card, which is a progress bar wearing a costume — it implies the
        // wait has an extent and that the extent is the text, and neither is
        // true. One word is the honest claim: reading is about to begin HERE.
        // It is also where the eye already is.
        let font = host.font ?? .systemFont(ofSize: 12)
        let firstWord = String(host.stringValue.prefix { !$0.isWhitespace })
        guard !firstWord.isEmpty else { return }
        let wordWidth = min(
            max((firstWord as NSString).size(withAttributes: [.font: font]).width, 24),
            host.bounds.width)
        let lineHeight = ceil(font.boundingRectForFont.height)
        // NSTextField is not flipped, so the first line sits at the TOP of the
        // layer's coordinate space, not the origin.
        let lineY = host.isFlipped ? 0 : max(host.bounds.height - lineHeight, 0)

        let band = max(wordWidth * 0.6, 16)
        let sweep = CAGradientLayer()
        sweep.frame = CGRect(x: 0, y: lineY, width: band, height: lineHeight)
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        let ink = StateLegend.Palette.ink
        // 0.08, down from 0.14. Against text already dimmed to 0.35 this is a
        // suggestion of movement, not a highlight — if you have to decide
        // whether you saw it, it is at the right strength.
        sweep.colors = [
            ink.withAlphaComponent(0).cgColor,
            ink.withAlphaComponent(0.08).cgColor,
            ink.withAlphaComponent(0).cgColor,
        ]
        sweep.locations = [0, 0.5, 1]

        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = -band / 2
        travel.toValue = wordWidth + band / 2
        // 2.6s, up from 1.2. The old pace read as urgent, which is the opposite
        // of what a wait should say — the panel is meant to be the calm thing in
        // the room. Slower over a shorter distance reads as breathing.
        travel.duration = 2.6
        travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.add(travel, forKey: "sweep")

        hostLayer.addSublayer(sweep)
        shimmerLayer = sweep
        Permissions.log("shimmer: started over \"\(firstWord)\" "
                        + "(w=\(Int(wordWidth)) band=\(Int(band)))")
    }

    private func stopBodyShimmer() {
        shimmerArm?.cancel(); shimmerArm = nil
        guard let layer = shimmerLayer else { return }
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
        shimmerLayer = nil
        Permissions.log("shimmer: stopped")
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

    /// PROVISIONAL (08 Aug): opens Settings, which today lands on the Voices
    /// pane — there is no Microphone pane yet. The button is honest about the
    /// destination it WILL have, and lands one tab away from it in the meantime,
    /// which beats both a dead control and a button named after the pane it can
    /// actually reach. Proposal: docs/settings-microphone.html.
    @objc nonisolated private func micSettingsTapped() {
        MainActor.assumeIsolated { onOpenSettings?() }
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
/// The card's identity label, when the identity is also a way back to the tab.
///
/// A click target with no affordance is a secret, and a card that grows a button
/// for something the eye is already resting on is the detail this pass exists to
/// remove. The cursor is the whole affordance: nothing changes until the pointer
/// arrives, and then it says "this opens".
///
/// `isADoor` is false whenever there is no live target — the app's own name on
/// the empty room rides this same label, and a name that offers to open nothing
/// is worse than a name that offers nothing.
private final class DoorLabel: NSTextField {
    var isADoor = false {
        didSet {
            guard isADoor != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isADoor else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The gesture recogniser does the work; this only keeps a dead label from
    /// swallowing clicks meant for the card behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isADoor ? super.hitTest(point) : nil
    }
}

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
    /// The lamp's click target. Equal to the column ON PURPOSE, after trying
    /// wider and backing it out.
    ///
    /// The target is already 20 × 40 — the full row height, not the 9pt dot —
    /// so it is far larger than it looks and past the usual 24pt guidance by
    /// area. Widening it in x has nowhere to go: the name begins at
    /// `lampColumn`, so 28 would have swallowed the name's first 8pt and made
    /// clicking a session's title MUTE it, and buying that space back by
    /// pushing `lampColumn` out would reverse the 05 Aug ruling that tightened
    /// 26 → 20 — with an argument, which rule 4 does not accept. The
    /// discoverability this was reaching for is the hover pill's job instead.
    static let lampHitWidth: CGFloat = lampColumn
    /// How far the hover highlight reaches PAST the row's content on each side.
    ///
    /// The row's content box starts exactly where the lamp starts — the lamp is
    /// pinned flush to `leadingAnchor` — so a highlight drawn to the row's own
    /// bounds put a hard edge against the lamp with no air at all. The panel's
    /// stack already holds 14pt of inset on either side; the highlight borrows
    /// 8 of it so the lamp sits INSIDE the lit area rather than on its border.
    /// Nothing that is drawn moves: this widens the lit rectangle only.
    static let hoverBleed: CGFloat = 8
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

        // Behind everything: the hover pill. A view rather than the row's own
        // layer, because it has to reach wider than the row's content box —
        // see `hoverBleed`. Neither the row nor the stack masks to bounds, so
        // it renders into the panel's inset as intended.
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        addSubview(highlight)
        addSubview(lamp); addSubview(name); addSubview(callsign)
        // A grid with no minted callsigns collapses the column entirely —
        // no phantom 12pt gutter on the right.
        let gutter: CGFloat = auxWidth > 0 ? 12 : 0
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            // Wider than the row on both sides, and inset vertically so it
            // reads as a pill between the rules rather than a band welded to
            // them. The 2pt keeps the hairline rule visible under a hovered row.
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: -Self.hoverBleed),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                constant: Self.hoverBleed),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
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

    /// The hover pill. Held so hover can paint it rather than the row's layer,
    /// which could only ever be exactly as wide as the content.
    private let highlight = NSView()

    override func mouseEntered(with event: NSEvent) {
        highlight.layer?.backgroundColor = StateLegend.Palette.hover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        highlight.layer?.backgroundColor = nil
    }

    /// "Mischief managed" (ruled 06 Aug): clicking a lit lamp switches it off —
    /// marks the turn heard without inviting the session. Set only on rows
    /// whose lamp is lit; nil means the lamp column is just part of the row.
    var onLampTap: (() -> Void)?

    // A cell-less NSControl tracks nothing by default; the whole row is the
    // hit target, and the tap lands on mouse-up like any button's would.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        // The lamp is its own target when it is live: `lampHitWidth` at full
        // row height, not the 9px dot — a click target the size of the glyph
        // would be a trap, and this is the switch that mutes an agent.
        if let onLampTap, point.x <= Self.lampHitWidth {
            onLampTap()
            return
        }
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
        // The marker and its label are one affordance and take one ink.
        plus.textColor = StateLegend.Palette.hint
        plus.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = letterspaced(
            StateLegend.newAgentTitle, size: 9.5, tracking: 1.33,
            color: StateLegend.Palette.hint)
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
        category.textColor = StateLegend.Palette.hint
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
            // Punched out of the lamp, in the housing's own colour: 6.35:1
            // against `ready`. This was a hardcoded near-white, which read fine
            // on the old dark green and would have fallen to 1.88:1 on the
            // brighter one — an invisible tick, visible only at runtime, in one
            // state. Exactly the failure the "no literals outside the Palette"
            // rule exists to prevent.
            mark.textColor = StateLegend.Palette.surface
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
