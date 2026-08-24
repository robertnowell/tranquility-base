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
    /// The content column: where every mark on the panel begins and ends.
    ///
    /// Named because it was a coincidence between three numbers rather than a
    /// fact — the stack's own 14pt inset, which the rules and rows paint to
    /// exactly, and a 10 and a 12 in the header's chrome, whose glyphs then
    /// landed 7pt and 3.5pt inside it. Anything pinned by its BOX subtracts
    /// `ConsoleButton.inkOverhang` from this so the MARK arrives here instead.
    static let contentColumn: CGFloat = 14

    var panel: ConsolePanel?
    var titleLabel: DoorLabel!
    var bodyLabel: CardBodyLabel!
    var stateLabel: DoorLabel!
    var goButton: ConsoleButton!
    /// The readback face's ONE negative (simplification pass, ruled): a quiet
    /// text action, not a lozenge. The Reply/Dismiss buttons are dead — chords
    /// are the interface.
    var dontSendButton: ConsoleButton!
    var micSettingsButton: ConsoleButton!
    var newSessionButton: ConsoleButton!
    var openPageButton: ConsoleButton!
    var hintLabel: NSTextField!
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
    /// What the last Don't send asked for, so the drill can see §D hold.
    /// Nil until the button is pressed; the ruling says it must then be false.
    var dontSendRestartedListening: Bool?
    /// The grid's bottom line: `Controls` left, the wordmark right. Its own
    /// widget rather than more text in `hintLabel`, because it is two things at
    /// two edges and one of them is a hover target — the hint slot stays what
    /// it is, a sentence, and the settings pane keeps using it unchanged.
    var gridFooter: GridFooterView!
    /// The hover sticky, parented to `background` rather than the content
    /// stack: it must appear without moving anything. A revealed ROW would push
    /// the grid up and resize the panel on a mouse-over, which is the same
    /// reflow-on-hover the collapsed strip forbids, for the same reason.
    var controlsSticky: ControlsNoteView!
    /// The card's copy of the word, in the middle of the action row. The grid's
    /// copy lives in its footer; both drive `setControlsNote(open:above:)`, so
    /// there is one note and one behaviour behind two placements.
    var cardControls: ControlsWordView!
    /// Where the note is currently hung. Rebuilt on every open, because the row
    /// that owns the word changes with the face.
    private var stickyPlacement: [NSLayoutConstraint] = []
    var stripLabel: NSTextField!
    var stripRule: NSView!
    /// The drop tray's chips: what would ride the next voice reply to the
    /// session currently addressed. A row in the content stack like any other
    /// — it extends the panel downward rather than displacing the card, the
    /// same geometry the capture strip already uses.
    var trayRow: TrayRowView!
    /// The whole-surface drop invitation, parented to `background` so it
    /// covers every face without joining the stack (a row would resize the
    /// panel mid-drag, which is reflow under the pointer).
    var dropOverlay: DropOverlayView!
    var contentStack: NSStackView?
    /// The collapsed column. Built once, hidden until the width changes.
    var strip: CollapsedStrip?
    /// The expanded face's whole view tree, held so the two widths can be
    /// SWAPPED as content views rather than layered inside one.
    ///
    /// Layering was the first attempt and it put the panel off the screen. The
    /// grid's stack pins the content view to 380pt; hiding it does not retire
    /// its constraints, so a `setFrame` to 40pt was silently snapped back to 380
    /// on the next layout pass — while the ORIGIN had already been moved to
    /// `maxX - 40`. The result was a 380pt window hanging 340pt past the right
    /// edge of the display, with only its empty left margin visible.
    var expandedRoot: NSView?
    var stackEdges: [NSLayoutConstraint] = []
    var stripEdges: [NSLayoutConstraint] = []

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
    /// The ink the column actually painted in a lamp's middle — a state colour
    /// when the lamp is solid, transparent when it is a ring.
    func collapsedLampCentreInk(_ index: Int) -> NSColor? {
        strip?.lampCentreInkForTesting(index)
    }
    /// A full column still clears the band the mark and the controls share.
    var collapsedLampsClearTheMark: Bool {
        strip?.lampsClearTheMarkForTesting ?? false
    }
    /// Ink in the strip's logo slot — the header mark, counted on the render.
    var collapsedHeaderInk: Int { strip?.headerInkForTesting() ?? 0 }
    /// Which face the strip's bottom band last painted, and how much ink it
    /// put there — the mark at rest, the controls on hover.
    var collapsedFloorFace: CollapsedStrip.FloorFace? { strip?.lastFloorPaint }
    var collapsedFloorInk: Int { strip?.floorInkForTesting() ?? 0 }
    var collapsedControlsSitInsideTheMark: Bool {
        strip?.controlsSitInsideTheMarkForTesting ?? false
    }
    /// The type the mark actually rendered at, and whether it clears the floor
    /// a human can read it at.
    var collapsedMarkTypeSize: CGFloat { strip?.lastMarkTypeSize ?? 0 }
    var collapsedMarkTypeIsLegible: Bool {
        strip?.markTypeIsLegibleForTesting ?? false
    }
    func collapsedSetHovering(_ on: Bool) { strip?.setHoveringForTesting(on) }
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
    var awaitingConfirm: Bool { countdownTimer != nil && state.isPendingSend }
    var meterTimer: Timer?
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
    var countdownTimer: Timer?
    private var onCancelSend: ((_ restartListening: Bool) -> Void)?
    private var onCommitSend: (() -> Void)?
    var countdownBar: CountdownBarView!
    var meter: LevelMeterView!
    var voiceList: NSScrollView!
    var pastList: PastAgentsList!
    var settingsTabs: SettingsTabBar!
    var launchRow: SettingRowView!
    var directoryRow: SettingRowView!
    var voiceStack: NSStackView!
    var voiceListHeight: NSLayoutConstraint!
    var gearButton: ConsoleButton!
    var collapseButton: ConsoleButton!
    var backButton: ConsoleButton!
    var pastBackButton: ConsoleButton!
    var waitingRows: NSStackView!
    var onPickWaiting: ((String) -> Void)?
    /// Wired by the app onto `SessionLauncher.resume`. Only ever called for a
    /// row that proved its session is gone and its directory still exists.
    var onRevive: ((_ id: String, _ name: String) -> Void)?
    /// The list's half of the switch: put this session back on the grid,
    /// wearing whatever state it is actually in.
    var onRestoreLamp: ((String) -> Void)?
    /// Right-click → Terminate on a live Past Agents row. The kill itself is
    /// the app layer's job (a process signal is not a paint).
    var onTerminateSession: ((_ id: String, _ name: String) -> Void)?

    /// Clicking the ◀ breadcrumb goes home (ruled 06 Aug: "there's no reason
    /// it shouldn't be clickable — voiced first while allowing a keyboard
    /// tap"). Only wired for the card states whose ⌃⌥ already means home;
    /// the guard lives in the click handler, the meaning in main.swift.
    var onBreadcrumbHome: (() -> Void)?

    /// Clicking a lit lamp marks that session heard without inviting it
    /// (ruled 06 Aug: "mischief managed" — switch the light off). The host
    /// owns the store write; the grid repaints through the ordinary path.
    var onClearLamp: ((String) -> Void)?
    var actionRow: NSStackView!
    private static let spokenMark = NSAttributedString.Key("vdSpoken")

    var currentTarget: (sessionId: String, pid: Int?, label: String)?

    /// What the card's second door opens: the agent's hub, or the one report
    /// this turn just wrote. A door that says one thing and opens another is
    /// worse than no door, so the LABEL follows the destination (ruled 15 Aug,
    /// refining the hub-door ruling of the same day: a fresh report outranks
    /// the hub, and the hub is one click past it via the report's footer).
    enum SecondDoor: Equatable {
        case hub
        case report(String)
    }
    /// Derived from `currentTarget` rather than stored beside it. Storing it
    /// would mean clearing it at all four sites that clear the target, and the
    /// one that got missed would leave a button pointing at the previous
    /// agent's page — the exact confusion this feature exists to end.
    private var currentDoor: SecondDoor? {
        currentTarget.flatMap { doorForSession?($0.sessionId) }
    }
    /// Wired by the app. Nil is a complete answer — a session never
    /// summarized has no hub and no report to open.
    var doorForSession: ((String) -> SecondDoor?)?
    /// Wired by the app; receives the session id, because the app rewrites the
    /// hub fresh before opening it, and the write needs the store the panel
    /// deliberately does not hold.
    var onOpenHub: ((String) -> Void)?
    /// The signature in the grid's bottom-right corner. Not per-agent like the
    /// doors above it — this one is the project.
    var onOpenRepository: (() -> Void)?
    /// Wired by the app onto the workspace's focus-or-open call.
    var onOpenReport: ((String) -> Void)?

    // MARK: - Public surface

    /// While you are talking, the panel's whole job is to prove it can hear you.
    ///
    /// It previously showed the same identity line, the same "hold ⌥ to speak" hint
    /// you were already obeying, and three buttons for actions unrelated to
    /// speaking. A live level meter answers the only question you actually have.
    /// A deep link hands the panel its session before the mic opens, so Listening
    /// can show who the reply is addressed to.
    func adoptTarget(sessionId: String, pid: Int?, label: String, cwd: String?) {
        // A greeting card that has not been bound yet belongs to an agent that
        // does not exist. The capture path adopts whatever `resolveReplyContext`
        // returned, which on that card is the PREVIOUS agent — and the card then
        // grew a GO TO AGENT that opened somebody else's tab (18 Aug, caught in a
        // screenshot at 22:37). A door to the wrong agent is worse than no door,
        // because it is indistinguishable from a right one until you are in the
        // wrong tab. So the greeting card keeps its emptiness until the session it
        // is actually about arrives; `bindGreeting` is the only way in.
        guard !awaitingGreetingBinding else { return }
        currentTarget = (sessionId, pid, label)
        currentEventId = sessionId
        lastAddressed = (sessionId, pid, label)
    }

    /// Attaches a pid to the card already on stage, for the one case a fresh
    /// `showAnnouncement` cannot resolve it itself: `revive()` announces a
    /// session's stored brief BEFORE calling `SessionLauncher.resume` on it
    /// (ruled 18 Aug — a recap has nothing worth waiting on), so the live-pid
    /// lookup inside that announce's `onWillSpeak` runs against a session
    /// that, for a `+stored` brief, has not been relaunched yet: resume is
    /// the very next line. Found live, 23 Aug: the card painted with no GO TO
    /// AGENT, and nothing ever revisited it once the resume that would have
    /// made the button true actually finished a few seconds later.
    ///
    /// Guarded the same way `bindGreeting` guards its own late arrival: only
    /// the card that is STILL about this exact session, and STILL missing a
    /// pid, is touched. A card that has since moved on to a different agent,
    /// or already carries a pid from its own announce, is left alone — the
    /// same "late is not wrong, late and unnoticed would be" rule.
    func attachLivePid(_ pid: Int, sessionId: String) {
        guard let target = currentTarget, target.sessionId == sessionId, target.pid == nil
        else { return }
        currentTarget = (sessionId, pid, target.label)
        lastAddressed = (sessionId, pid, target.label)
        render()
    }

    /// The last agent this panel addressed, kept so a failure card can name it.
    ///
    /// `send()` returns the panel to the grid before the outcome arrives — the
    /// countdown was the confirmation, and waiting on a receipt would be a second
    /// wait already served. That is right, and it left the failure card painting
    /// from idle with no target: no title, and no door, on a card whose whole
    /// message was "check the tab" (18 Aug).
    private var lastAddressed: (sessionId: String, pid: Int?, label: String)?

    /// True between a greeting card painting and its session binding to it.
    ///
    /// The window is five to nine seconds of Terminal opening and Claude Code
    /// booting, and it is long enough to answer the card in — which is the point
    /// of the card. Everything in it must therefore behave as though the agent is
    /// still on its way, rather than silently substituting the last one.
    private var awaitingGreetingBinding = false

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
    private func renderCaptureStrip(_ placard: NSAttributedString?,
                                    detail: String? = nil) {
        guard face.hasCard else {
            // Nothing to sit under: the pill climbs back to the top and this is
            // the panel that shipped. A capture from the grid needs the dot and
            // the name, because nothing else on screen carries either.
            titleLabel.isHidden = true
            if let placard { stateLabel.attributedStringValue = placard }
            return
        }
        stripRule.isHidden = false
        // Under a card the strip says as little as possible (ruled 10 Aug).
        // The pill's two jobs are both already done above it: the green dot
        // means "the mic is open", which the live waveform says better, and the
        // target name means "this is who you are answering", which is the
        // card's own title — so the pill was printing the agent's name twice on
        // one panel. What is left is the meter, which is the only part that was
        // ever telling you something new.
        guard let placard else { return }
        stripLabel.isHidden = false
        let line = NSMutableAttributedString(attributedString: placard)
        if let detail, !detail.isEmpty {
            line.append(NSAttributedString(
                string: "\n" + detail,
                // Prose: the detail slot carries exactly one thing, the
                // read-back, and a read-back is YOUR words waiting to be sent.
                // It was mono on the argument that they are about to be typed
                // into a terminal — but that is a fact about the destination,
                // and by it the card's body would be mono too, since those
                // words came out of one. The rule is about role: an agent's
                // message is prose, and so is yours.
                attributes: [.font: StateLegend.Face.message(11),
                             .foregroundColor: StateLegend.Palette.secondary]))
        }
        stripLabel.attributedStringValue = line
    }

    /// The one door the Controls sticky opens and closes through, so the hover
    /// and the drill can never drift apart — the rule `dismiss()` follows.
    ///
    /// Nothing but a visibility flip: no transition, no render, no resize. A
    /// hover is not a state, and a pointer crossing a word must not be able to
    /// write into the panel's state machine. Closing is owned by render()'s
    /// baseline, which is why leaving the grid closes the note for free.
    /// Open or close the note, hung above the row that owns the word.
    ///
    /// The placement is rebuilt per open rather than fixed at construction: the
    /// grid's footer and a card's action row sit at different heights, and the
    /// same note serves both. Centred on the panel rather than aligned to the
    /// word — the note is wider than the word is long, so a leading-aligned
    /// note hung off a centred word would run off the right edge.
    func setControlsNote(open: Bool, above host: NSView? = nil) {
        guard let controlsSticky else { return }
        if open, let host, let background = controlsSticky.superview {
            NSLayoutConstraint.deactivate(stickyPlacement)
            stickyPlacement = [
                controlsSticky.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                controlsSticky.bottomAnchor.constraint(equalTo: host.topAnchor, constant: -8),
            ]
            NSLayoutConstraint.activate(stickyPlacement)
        }
        controlsSticky.isHidden = !open
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
        // The greeting window belongs to the greeting card; any other face
        // taking the stage ends it, so an unbound launch never mutes the next
        // card's doors.
        awaitingGreetingBinding = false
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

    /// The card a launch paints before there is a session to hang it on.
    ///
    /// Ruled 18 Aug: the card comes FIRST. Everything else about starting an
    /// agent takes seconds that are not ours to spend — Terminal opening a
    /// window, Claude Code coming up, the trust watcher settling, the id
    /// appearing in `claude agents --json` — and the panel waited on all of it
    /// before showing anything. It waits on none of it now: the question is on
    /// screen and in the air the instant the button is pressed, and
    /// `bindGreeting` attaches the session underneath when it exists.
    ///
    /// No target yet, deliberately, rather than a placeholder id: an empty
    /// string in `currentTarget.sessionId` is a session that does not exist,
    /// and every door on this card would be a door to nowhere. Nil is what the
    /// panel already means by "no session on this face", and GO TO AGENT, the
    /// hub link and the title-as-door all read it correctly for free.
    @discardableResult
    func showGreeting(line: String, label: String) -> Bool {
        guard transition(to: .speaking(eventId: nil), because: "greeting") else {
            return false
        }
        currentEventId = nil
        currentSpoken = nil
        currentTarget = nil
        awaitingGreetingBinding = true
        face = Face(title: label, body: line)
        render()
        return true
    }

    /// Attach the session to the greeting card once Claude Code has minted it.
    ///
    /// Refuses unless the greeting card is still the one on stage, unbound. A
    /// binding that arrived after you had moved on would silently repoint the
    /// reply routing at a session you are not looking at, which is the exact
    /// failure `showAnnouncement`'s own guard exists to prevent. Late is not
    /// wrong here; late and unnoticed would be.
    ///
    /// "Still on stage" is `awaitingGreetingBinding`, not `state.isSpeaking`
    /// (changed 19 Aug). The flag says the thing this guard means — a greeting
    /// card is up and has no session yet — and every face that takes the stage
    /// clears it, so the invariant is unchanged. The STATE said something
    /// narrower and accidentally: a microphone fault at 15:35:56 moved the
    /// panel to `.result` without the card going anywhere, and the session that
    /// registered four seconds later was refused a binding it should have had.
    /// The card had not moved on; only the state had.
    @discardableResult
    func bindGreeting(sessionId: String, pid: Int?, label: String, cwd: String?) -> Bool {
        guard awaitingGreetingBinding, currentTarget == nil else { return false }
        // Closed FIRST: this is the one adoption the greeting card wants, and the
        // guard in `adoptTarget` would otherwise refuse the very call it exists
        // to make room for.
        awaitingGreetingBinding = false
        adoptTarget(sessionId: sessionId, pid: pid, label: label, cwd: cwd)
        // The doors are derived from the target, so the card grows GO TO AGENT
        // and its hub link at the moment it acquires one.
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
        // Nil'd, not merely invalidated: `awaitingConfirm` reads the handle, so
        // a dead timer left in place makes it answer true for a window that is
        // already over — the shape that once left every gesture dead-ending on
        // the read-back (12 Aug).
        countdownTimer?.invalidate(); countdownTimer = nil
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

    /// After Don't send has landed the panel somewhere alive: `true` = the card
    /// under the readback was restored (the host re-arms its dwell clock, ruling
    /// 14's shape); `false` = the readback was the whole panel, the stage is
    /// yielded, and the host paints the grid it was covering.
    var onPendingSendStopped: ((_ cardRestored: Bool) -> Void)?

    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated func cancelPendingSendTapped() {
        // FALSE (ruling §D, "no outcome reopens the microphone on its own").
        // Don't send meant "don't send, and start listening again", so the one
        // button whose entire job is to stop cost you an open mic you did not
        // ask for. Holding ⌥ is how you say it again; that path passes false
        // for the same reason and has always been the only one that should
        // restart a capture.
        MainActor.assumeIsolated {
            guard cancelPendingSend(restartListening: false) else { return }
            // Stopping the send is only half the button's job. Cancelling used
            // to end here, which stranded the panel: still `.pendingSend`, but
            // with a dead countdown — so `awaitingConfirm` was false, commit
            // refused, the legality table refused every repaint, and each ⌃⌥
            // press dead-ended (12 Aug: "stuck on the read-back screen, and
            // all inputs are broken"). Land somewhere alive instead.
            guard case .pendingSend = state else { return }
            if face.readback != nil, face.hasCard {
                // The readback rode the strip over a card, and the card never
                // left the face — title, body, ink all intact. Clear the strip
                // and give the stage back to the card.
                face.readback = nil
                face.countdownSeconds = 0
                forceTransition(to: .speaking(eventId: currentEventId),
                                because: "don't send — card restored")
                render()
                onPendingSendStopped?(true)
            } else {
                // The readback WAS the panel (a capture begun from the grid):
                // there is nothing here to restore, so yield the stage and let
                // the host paint the grid it was covering.
                endCapture(because: "don't send — no card to restore")
                onPendingSendStopped?(false)
            }
        }
    }

    /// The faces the breadcrumb is a door on. One declaration, read by the
    /// cursor and by the handler, so the affordance and the behaviour cannot
    /// drift apart.
    private var breadcrumbIsADoor: Bool {
        switch state {
        case .speaking, .preparing: return true
        default: return false
        }
    }

    @objc nonisolated func breadcrumbClicked() {
        MainActor.assumeIsolated {
            // Same altitude rule as ⌃⌥: home from a card. Speaking covers the
            // announcement and every ⌃⌃ rung; preparing is the card BEFORE
            // those, and it was the one face on stage with no door out at all
            // (18 Aug). A wait is exactly the moment you are most likely to
            // change your mind, so it gets the same pill and the same verb.
            switch state {
            case .speaking, .preparing: onBreadcrumbHome?()
            default: return
            }
        }
    }

    // setPaused is dead (simplification pass, ruled): ⇧ pause is an AUDIO
    // behavior; the frozen speaking card — highlight stopped mid-word — IS the
    // pause indication. No pill switch, no hint.

    /// Append a line to the current panel without disturbing what it is showing.
    func note(_ message: String) {
        hintLabel.stringValue = [message, hintLabel.stringValue]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        syncHintVisibility()
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

    /// The agents pane: no host data at all, it reads AgentDefaults. Given its
    /// own entry point so it cannot inherit the title and body of whichever
    /// pane happened to be open before it.
    func showAgentSettings() {
        guard transition(to: .settings, because: "settings opened") else { return }
        currentTarget = nil
        face = Face(title: "Agents", body: "How every agent starts, new ones here, "
                    + "revived ones in their own directory.")
        face.settingsTab = .agents
        render()
    }

    func showSettings(voices: [Voice], roster: [String], note: String,
                      tab: SettingsTab = .agents) {
        guard transition(to: .settings, because: "settings opened") else { return }
        currentTarget = nil
        face = Face(title: "Voices", body: note, voices: voices, roster: roster)
        face.settingsTab = tab
        render()
    }

    /// Wired by the app: hand back the data for a tab, then show it. One door
    /// per pane, so no pane can be drawn against another's payload.
    var onOpenSettingsTab: ((SettingsTab) -> Void)?

    /// The host answers the voices pane's "Recent audio ▸" row by assembling
    /// events and calling `showRecentAudio` — the pane never reads the store.
    var onShowRecentAudio: (() -> Void)?
    /// A row's ⋯ → Retry. The host retries, then `updateRecentAudio`.
    var onRetryAudioEvent: ((String) -> Void)?
    /// A row's ▶/■ — toggle. Play sits on the row, not in the menu, because
    /// it has state a menu cannot show (ruled 13 Aug).
    var onPlayAudioEvent: ((String) -> Void)?
    /// A row's ⋯ → Show in Finder: the audio file, where "download" means
    /// "it was always yours, here it is".
    var onRevealAudioEvent: ((String) -> Void)?

    /// Choose the start directory with the picker rather than by spelling it.
    ///
    /// NSOpenPanel is modal and needs the app frontmost, which this panel
    /// deliberately is not — `.nonactivatingPanel` exists so the app never
    /// steals a keystroke. So the app is activated for the length of the
    /// choice and the panel takes key alongside it, exactly as the typing
    /// faces already do, and both are handed back when the sheet closes.
    func pickAgentDirectory() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Use folder"
        picker.message = "Where new agents start"
        // Open on what is configured, so the picker begins where the setting
        // points rather than wherever AppKit last left someone.
        picker.directoryURL = URL(fileURLWithPath: AgentDefaults.directory())
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }
        AgentDefaults.save(directory: url.path)
        directoryRow.show(url.path)
        Permissions.log("settings: agent directory set to \(url.path)")
    }

    /// Switch tabs without leaving `.settings`.
    ///
    /// The host is asked for the data a tab needs rather than the pane reading
    /// a store — same rule the audio log already had, now applied to all three,
    /// so the panel keeps knowing nothing about where anything lives.
    func showSettingsTab(_ tab: SettingsTab) {
        guard case .settings = state else { return }
        // EVERY tab asks the host for its own data. The first version asked
        // only for RECENT and re-rendered the others in place, which left the
        // previous pane's `face` underneath: clicking VOICES after RECENT drew
        // the title "Recent audio" over an empty roster reading "0 of 0", with
        // the voices hint under it. Three panes' worth of state in one frame,
        // and every individual line of it true.
        //
        // A pane is its data. Switching to one and not fetching it is the same
        // bug as a grid row keeping a lamp from the session it used to show.
        if tab != .agents { releaseKeyboard() }
        onOpenSettingsTab?(tab)
    }

    /// The settings state's second pane (ruled 13 Aug): the log of recent
    /// captures over a second, transcript or its absence, per-row retry.
    /// Reached from the voices pane; back exits to the grid, as settings
    /// always has.
    func showRecentAudio(events: [AudioEventRow], note: String) {
        guard transition(to: .settings, because: "recent audio opened") else { return }
        currentTarget = nil
        face = Face(title: "Recent audio", body: note, audioEvents: events)
        face.settingsTab = .recent
        render()
    }

    /// Re-render with fresh rows without re-entering the state — a retry
    /// round-trips through the host's store and back here, exactly as the
    /// voice roster's toggle does.
    func updateRecentAudio(events: [AudioEventRow]) {
        guard case .settings = state, face.audioEvents != nil else { return }
        face.audioEvents = events
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

    var transcribingTimer: Timer?
    var cancelTranscriptionButton: ConsoleButton!
    var retryTranscriptionButton: ConsoleButton!

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

    @objc nonisolated func cancelTranscriptionTapped() {
        MainActor.assumeIsolated { face.transcription?.cancel() }
    }

    @objc nonisolated func retryTranscriptionTapped() {
        MainActor.assumeIsolated { face.transcription?.retry() }
    }

    /// A failure receipt — the ONLY receipt (simplification pass, ruled): the
    /// Sent face is dead, success says nothing on the panel (status line + log
    /// only, immediate return to the grid). A failure is the case with work
    /// left to do, so it stays until dismissed, titled by the session it is
    /// about — the one displayed identity, in mono.
    /// `about` names the session the failure BELONGS to, when the caller knows
    /// it. It exists because a dispatch failure outlives the attention that
    /// started it: the verification round-trip runs for up to twelve seconds,
    /// and by the time it fails the announce queue has moved the panel to
    /// somebody else's card. On 19 Aug at 16:38 it fired fourteen seconds
    /// late — the words had gone to `recall`, the panel had advanced to
    /// "Microphone initiation issue", and the card said one session's name over
    /// the other session's message. Robert could not place the alert at all,
    /// which is the correct reaction to a card that is half about each of two
    /// agents.
    ///
    /// Nil keeps the old behaviour exactly, for the callers that genuinely have
    /// no session in hand — a microphone fault is about the machine, not about
    /// an agent, and `showDeviceFault` says so by carrying no title at all.
    func showResult(_ message: String,
                    about: (sessionId: String, pid: Int?, label: String)? = nil) {
        // Read BEFORE the transition, which is the only moment that can tell
        // the two kinds of failure apart: one that arrives while the capture
        // flow owns the stage happened TO the capture; one that arrives from
        // idle or a card — the invitation, an orphaned artifact — did not, and
        // keeps the full card it has always had. Two drills caught this being
        // applied to both (notice.leak's plainFailureHasNoDoor and
        // invitation's failureIsStillAmber), which is exactly the overreach
        // they exist to refuse.
        let failedDuringCapture = state.ownsStage
        // The third kind, added 19 Aug: a fault that arrives while a greeting
        // card is waiting for its session. `.speaking` does not own the stage,
        // so this used to take the branch below — which rebuilds the face and
        // clears `awaitingGreetingBinding`, unbinding an agent that was six
        // seconds from registering. The microphone failing is not a reason to
        // throw away the launch you were answering, so it joins the strip like
        // any other capture fault and the card keeps its stage, its identity,
        // and its right to be bound.
        let greetingAwaitsItsSession = awaitingGreetingBinding
        // A failure joins the card on stage only when it is a failure OF that
        // card. `about` names the session that actually failed; if the panel has
        // since moved to a different one, attaching the message here would
        // print it under a stranger's name — and the strip is the one slot with
        // no room to say whose it is. It gets its own card below instead.
        let cardIsTheSubject = about.map { $0.sessionId == currentEventId } ?? true
        guard transition(to: .result, because: "reply failed") else { return }
        // A failure that happened TO a capture joins the strip, for the same
        // reason the read-back did. Amber either way; the channel does not
        // change, only the slot it speaks from.
        if face.hasCard, cardIsTheSubject, failedDuringCapture || greetingAwaitsItsSession {
            face.captureFault = message
        } else {
            // The card names the agent the failure is ABOUT, and therefore carries
            // its door. Without this the panel had already gone home to the grid,
            // so the card painted with no target: an empty title and no GO TO
            // AGENT under a message that said "check the tab before repeating
            // yourself". A card that names an action must afford it.
            awaitingGreetingBinding = false
            // The failure's OWN session wins, when the caller knows it. The
            // fallback below only ever covered "the panel went home" — it takes
            // `lastAddressed` when there is no target at all — and said nothing
            // about the case that actually bites: the panel moved ON, so
            // `currentTarget` is non-nil and names the wrong agent. Reading the
            // subject from whatever happens to be on stage is how a card ends up
            // titled for one session and bodied for another.
            if let about {
                currentTarget = (sessionId: about.sessionId, pid: about.pid, label: about.label)
                currentEventId = about.sessionId
            } else if currentTarget == nil, let last = lastAddressed {
                currentTarget = last
                currentEventId = last.sessionId
            }
            face = Face(title: currentTarget?.label ?? "", body: message)
        }
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

    @objc nonisolated func openHubTapped() {
        MainActor.assumeIsolated {
            guard let id = currentTarget?.sessionId, let door = currentDoor else { return }
            switch door {
            case .hub:
                Permissions.log("openHub: \(id.prefix(8))")
                onOpenHub?(id)
            case .report(let path):
                Permissions.log("openReport: \(path)")
                onOpenReport?(path)
            }
        }
    }

    @objc nonisolated func newSessionForArtifactTapped() {
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
    var noticeExpiry: DispatchWorkItem?

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
    var emptySince: Date?
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
            leaving(for: next)
            Permissions.log("state: \(state.name) -> \(next.name)  (\(reason))")
            state = next
        }
        entered(next)
        return true
    }

    /// The user's door. Explicit actions (Dismiss, hiding the panel, committing a
    /// send) are never stale, so they bypass the table — but they announce it.
    func forceTransition(to next: PanelState, because reason: String) {
        guard next != state else { return }
        leaving(for: next)
        Permissions.log("state: \(state.name) -> \(next.name)  (\(reason), user door)")
        state = next
        entered(next)
    }

    /// What LEAVING the current state owes — run by BOTH doors, before the move.
    ///
    /// Its opposite number is `entered`. The pair exists because "leaving X tears
    /// down X's machinery" is a property of leaving, not of whichever caller
    /// happened to do it: every time that obligation lived at a call site instead,
    /// some call site forgot, and the forgetting was silent.
    private func leaving(for next: PanelState) {
        releasePendingSend(for: next)
    }

    /// What ARRIVING somewhere owes, wherever the arrival came from.
    ///
    /// These two lines used to live in `transition` alone, so the user's door
    /// quietly skipped the preparing-paint cancel. Nothing depended on that
    /// asymmetry — the paint work item re-checks `.preparing` before it draws —
    /// but a rule with one door out of two is not a rule.
    private func entered(_ next: PanelState) {
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
    }

    /// Do what `PanelState.releasesPendingSend` decides: leaving the read-back
    /// cancels the send it was offering. Ruled 18 Aug.
    ///
    /// The countdown IS the send: `render()` hands the send closure to a one-shot
    /// `Timer` BY VALUE, so clearing `onCommitSend` afterwards stops nothing and
    /// only invalidating the timer does. That is why this is not a repaint
    /// concern — a read-back that leaves the screen with its timer alive still
    /// sends, and it sends silently.
    ///
    /// The incident (app.log 18 Aug 22:39): ⌥⌥ from the read-back opened a new
    /// capture through `showListening`, the countdown kept running underneath it,
    /// and four seconds later `state: listening -> idle (countdown completed)`
    /// dispatched the words the gesture had just rejected — into a live
    /// microphone, which the app noticed only well enough to drop its own send
    /// earcon. The gesture was not the bug. The door was.
    ///
    /// So the obligation moves off the call sites and onto leaving itself. Every
    /// legitimate exit already invalidates the timer BEFORE it transitions —
    /// `commitPendingSendNow`, `cancelPendingSend`, `endCapture`, and the
    /// countdown's own completion all do — so this is a no-op on all four and a
    /// rescue on anything new. A commit can never be turned into a cancel here,
    /// because a commit has already nil'd the timer by the time it moves.
    private func releasePendingSend(for next: PanelState) {
        guard !releasingPendingSend else { return }
        guard state.releasesPendingSend(movingTo: next) else { return }
        guard awaitingConfirm else { return }
        releasingPendingSend = true
        defer { releasingPendingSend = false }
        Permissions.log("pendingSend: left for \(next.name) with the countdown live"
                        + " — cancelling the send")
        // FALSE for the same reason the button passes false: whatever is taking
        // the stage is already the next thing, and restarting a capture from
        // here would double-start it.
        cancelPendingSend(restartListening: false)
    }

    /// Guards `releasePendingSend` against a cancel closure that transitions.
    /// Production's does not (it marks the utterance discarded and closes the
    /// delivery window), but a door that can be re-entered is a door that will be.
    private var releasingPendingSend = false

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
        // The greeting window belongs to the greeting card; any other face
        // taking the stage ends it, so an unbound launch never mutes the next
        // card's doors.
        awaitingGreetingBinding = false
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
        // The greeting window belongs to the greeting card; any other face
        // taking the stage ends it, so an unbound launch never mutes the next
        // card's doors.
        awaitingGreetingBinding = false
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
    /// The drills own the panel while they run.
    ///
    /// Earned 13 Aug, and it had been lying in both directions for a day. The
    /// launch drills paint synthetic faces and then measure their geometry —
    /// but the intake timer paints the REAL grid on its own schedule, and
    /// `allowsAmbientSurface` is true for `.idle`, which is the state the
    /// drills spend almost all of their time in. So a repaint carrying the
    /// machine's actual sessions could land between a drill's setup and its
    /// assertion.
    ///
    /// The symptom was a deploy gate that changed its mind with the session
    /// census: 3a8e143 passed 27 verdicts twice one day and failed
    /// `collapsedWidthReal`, `collapseClearsPlacard` and `lanesAreInOrder` the
    /// next, on the same screen, with no code between the two runs. The
    /// collapse drill's own log shows the intruder — "grid: 3 of 3 rows
    /// (1 ready, 2 closed, 1 revivable)", a REVIVABLE row inside a drill whose
    /// fixture has no such thing — and a collapsed frame of 380pt wide, because
    /// `resizeToFit` only morphs to the strip while the state is idle and the
    /// ambient repaint had moved it.
    ///
    /// False FAILs are the loud half. The quiet half is worse: the same race
    /// can hand a drill a real grid that happens to satisfy it, which is a PASS
    /// that proves nothing. Rule 7 makes these drills the panel's only
    /// evidence, so evidence that varies with how many agents you had open is
    /// not evidence.
    var canSurfaceAmbiently: Bool { !drillsHoldThePanel && state.allowsAmbientSurface }

    /// Set for the length of the launch drills and nothing else.
    ///
    /// `internal`, not `private` (App-lane P4, 23 Aug): `beginDrills`/
    /// `endDrills` (the only writers) moved to `SelfTestDriver.swift` — a
    /// `private` witness is invisible across that file boundary.
    var drillsHoldThePanel = false
    var drillRelease: DispatchWorkItem?

    var isOnScreen: Bool { panel?.isVisible ?? false }

    // MARK: - Rendering

    /// What the current state is about — the strings and closures PanelState
    /// deliberately does not carry. Stashed whole by each show* entry point;
    /// state + face is render()'s entire input.
    struct Face {
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
        /// Non-nil switches the settings state to its second pane: the
        /// recent-audio log (ruled 13 Aug — every capture over a second, its
        /// transcript or its absence, and a per-row manual retry). Same
        /// `.settings` state, a different face payload: the pane is a
        /// projection, not a new place the machine can be.
        var audioEvents: [AudioEventRow]? = nil
        var settingsTab: SettingsTab = .agents
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

        /// A capture that ended badly, said in the strip instead of the card.
        /// The failure is ABOUT the reply you just spoke, so it belongs under
        /// the message you spoke it to — taking the whole panel for it throws
        /// away the one thing you would need in order to try again.
        var captureFault: String?
    }
    var face = Face()

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
        case .settings, .pastAgents: return .settings
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
    func render() {
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
        stateLabel.attributedStringValue = Widgets.placardText(
            face.placardOverride.isEmpty
                ? (row?.stateText ?? "") : face.placardOverride)
        stateLabel.isHidden = false
        stateLabel.textColor = StateLegend.Lens.chrome.color
        // A baseline property like every other (see the contract above): the
        // breadcrumb is a door on exactly the faces `breadcrumbClicked` lets
        // through, so a pointer never offers a way back from a face that has
        // none.
        stateLabel.isADoor = breadcrumbIsADoor
        // A title exists exactly when the face carries one; an empty label still
        // reserves a line's height, which reads as a hole. The identity renders
        // in MONO, matching the grid rows; the topic joins in the regular face.
        renderTitle()
        bodyLabel.stringValue = face.body
        // Part of the baseline for the same reason the hint's font is: the empty
        // room's 17pt centred sentence is the only face that changes either, so
        // a state that never mentions them must not inherit them.
        bodyLabel.font = StateLegend.Face.message(12)
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
        // shown wherever an agent is named. The label follows the destination:
        // a report this turn just wrote, or the hub. Retitled per render
        // because the same button serves both and a stale label would lie.
        let door = currentDoor
        openPageButton.isHidden = door == nil
        if let door {
            let label = { if case .report = door { return StateLegend.openReportTitle }
                          return StateLegend.openHubTitle }()
            // The words, not the string: the button rebuilds them through the
            // same `BottomLine.door` when the pointer steps its ink.
            openPageButton.wordmark = "\(label) \(StateLegend.Glyph.forward)"
        }
        dontSendButton.isHidden = true
        micSettingsButton.isHidden = true
        newSessionButton.isHidden = true
        countdownBar.isHidden = true; meter.isHidden = true
        // The strip belongs to the capture arms alone. Both the label AND its
        // rule are baselined — a rule left behind is the residue class this
        // funnel exists to close, and it would draw a line across a card that
        // has nothing under it.
        stripLabel.isHidden = true; stripRule.isHidden = true
        // The chips are baselined off like every other widget and re-derived
        // below. Never left standing from a previous face: a chip belongs to
        // one session, and a face that addresses nobody must not show one.
        trayRow.isHidden = true
        // The footer belongs to the grid alone, and the sticky dies with it: a
        // note left open while the face changes underneath is exactly the
        // residue class render()'s baseline exists to make impossible.
        gridFooter.isHidden = true; controlsSticky.isHidden = true
        stripLabel.stringValue = ""
        voiceList.isHidden = true; waitingRows.isHidden = true
        pastList?.isHidden = true
        pastBackButton?.isHidden = true
        settingsTabs?.isHidden = true
        launchRow?.isHidden = true; directoryRow?.isHidden = true
        // Key status is a widget like any other, and the baseline owns it: any
        // state that is not the list face gives the keyboard back. Written here
        // rather than at each door out — back button, row pick, dismiss, an
        // arrival — because a door added later would otherwise leave the panel
        // holding a keyboard it has no face for, which is the away channel's
        // one unforgivable bug.
        // Two faces ask for typing now — the list's filter and settings'
        // launch/directory rows — and every other one gives the keyboard back.
        switch state {
        case .pastAgents, .settings: break
        default: releaseKeyboard()
        }
        gearButton.isHidden = false; backButton.isHidden = true
        // Only the grid can be collapsed: a card is a conversation in progress
        // and has no second width to go to.
        collapseButton?.isHidden = true
        // Part of the baseline so the grid's monospaced key line can never leak
        // into another state's hint — a font no arm mentions is at its baseline.
        hintLabel.font = StateLegend.Face.chrome(10)
        // Unhidden only by the slow-transcription tick, never by a state's arm.
        cancelTranscriptionButton.isHidden = true; retryTranscriptionButton.isHidden = true

        switch state {
        case .transcribing:
            if let note = face.captureNote {
                renderCaptureStrip(Widgets.placardText(note))
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
            // No count here. It said "8 OF 45" and shared a lane with the send
            // receipt, so "✓ SENT" and the count fought for the same pixels —
            // and the count was answering a question the list face now owns
            // outright. The placard is a placard again.
            let stripTitle = NSMutableAttributedString(attributedString: Widgets.letterspaced(
                StateLegend.gridStripTitle, size: 10, tracking: 3.2,
                color: StateLegend.Lens.chrome.color))
            let indent = NSMutableParagraphStyle()
            indent.firstLineHeadIndent = 24
            stripTitle.addAttribute(.paragraphStyle, value: indent,
                                    range: NSRange(location: 0, length: stripTitle.length))
            stateLabel.attributedStringValue = stripTitle
            hintLabel.font = StateLegend.Face.chrome(9.5)
            gridFooter.isHidden = false
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
            bodyLabel.font = StateLegend.Face.message(17)
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
            renderCaptureStrip(face.hasCard ? nil : armingPill())
            meter.isHidden = false
            meter.reset()

        case .listening:
            // The pill's dot in channel green (ruled): mic open = go.
            renderCaptureStrip(face.hasCard ? nil : listeningPill())
            meter.isHidden = false

        case .pendingSend:
            // Exactly ONE negative (ruled), as a quiet text action.
            dontSendButton.isHidden = false
            countdownBar.isHidden = false
            // The read-back is the strip's third phase, in the same slot the
            // other two used. The placard names it; the words follow.
            if let readback = face.readback {
                renderCaptureStrip(Widgets.placardText(StateLegend.readbackPlacard),
                                   detail: "\u{201C}\(readback)\u{201D}")
            }

        case .result where face.captureFault != nil:
            // The card keeps its own placard, identity and ink; the fault
            // speaks from the strip, in the needs-you channel.
            renderCaptureStrip(NSAttributedString(
                string: "\(StateLegend.Glyph.needsYou) \(face.captureFault ?? "")",
                attributes: [.font: StateLegend.Face.chrome(11, .medium),
                             .foregroundColor: StateLegend.Palette.fault]))
            micSettingsButton.isHidden = !face.offersMicSettings

        case .result:
            // A card that waits until dismissed. Amber presence beyond the glyph
            // (ruled): the placard text itself in the channel's ink — flat, calm.
            // Re-rendered attributed rather than via textColor, which attributed
            // runs ignore. The channel comes from the face, not the state: the
            // invitation waits the same way a failure does and means the
            // opposite.
            stateLabel.textColor = face.lens.color
            stateLabel.attributedStringValue = Widgets.placardText(
                stateLabel.attributedStringValue.string,
                color: face.lens.color)
            // A device fault is the only failure with somewhere to send you.
            micSettingsButton.isHidden = !face.offersMicSettings
            // The invitation's door out is a door IN: it starts the agent that
            // this page no longer has.
            newSessionButton.isHidden = !face.offersNewSession

        case .pastAgents:
            // Built on OPEN and never repainted while you read it. That is not
            // an optimisation, it is what makes this the one face that may
            // scroll: the grid tears its rows down on every content change, and
            // a list that did that under a scroll offset would throw you back
            // to the top every time a lamp somewhere changed colour.
            // Indented clear of the back chevron sharing this row (x 10–36;
            // the stack's left inset is 14, so 30 puts the "P" at x 44 with an
            // 8pt gap). The placardClearsChevron drill holds this geometry.
            stateLabel.attributedStringValue = Widgets.letterspaced(
                StateLegend.pastAgentsTitle, size: 10, tracking: 3.2,
                color: StateLegend.Lens.chrome.color, headIndent: 30)
            // One row, like the grid's: chevron, placard, gear. The gear stays
            // — settings is reachable from here as it is from everywhere — and
            // the collapse chevron is the one control this face replaces.
            gearButton.isHidden = false
            backButton.isHidden = true
            collapseButton?.isHidden = true
            pastBackButton?.isHidden = false
            hintLabel.font = StateLegend.Face.chrome(9.5)
            hintLabel.stringValue = pastList?.summary ?? ""
            pastList?.isHidden = false

        case .settings:
            // A TAB BAR, as the design always had it. One scrolling column
            // holding voices, an audio log behind a link row, and launch
            // settings stacked on top was three unrelated concerns in one
            // list — which is how a pane stops being navigable.
            stateLabel.stringValue = ""
            gearButton.isHidden = true; backButton.isHidden = false
            settingsTabs.isHidden = false
            settingsTabs.select(face.settingsTab)
            hintLabel.font = StateLegend.Face.chrome(9.5)

            switch face.settingsTab {
            case .agents:
                launchRow.isHidden = false; directoryRow.isHidden = false
                launchRow.show(AgentDefaults.load())
                directoryRow.show(AgentDefaults.directoryAsTyped())
                bodyLabel.stringValue = face.body
                setHint("return to save · choose… picks a folder")
                // Settings is the second face that asks for typing, so it takes
                // the keyboard the way the list does, and gives it back through
                // the same baseline door.
                if let panel = panel as ConsolePanel?, !panel.acceptsKey {
                    panel.acceptsKey = true
                    panel.makeKeyAndOrderFront(nil)
                }

            case .voices:
                voiceList.isHidden = false
                bodyLabel.stringValue =
                    "\(face.roster.count) of \(face.voices.count) on roster. \(face.body)"
                setHint("check = on roster · ▶ preview · drag ≡ to reorder")
                rebuildVoiceRows()

            case .recent:
                voiceList.isHidden = false
                bodyLabel.stringValue = face.body
                setHint("▶ plays the capture · ⋯ copy, retry, reveal")
                rebuildAudioRows(face.audioEvents ?? [])
            }
        }

        // The notice owns the strip while it lives. It can only exist on idle at
        // all — the two transition doors retire it on the way out — so this is a
        // read, and render() stays the pure projection it claims to be.
        if let notice {
            // Unhidden explicitly: the empty room's face switches the strip off,
            // and a notice with nowhere to land is feedback the user never gets.
            stateLabel.isHidden = false
            stateLabel.textColor = noticeLens.color
            stateLabel.attributedStringValue = Widgets.placardText(notice, color: noticeLens.color)
        }

        // The drop tray's chips, derived rather than stored: whatever Core
        // has staged for the session THIS panel would send to. One resolution
        // answers "who gets a drop" and "whose chips are these", so the files
        // you can see are exactly the files that would ride — the invariant
        // the whole feature rests on, held by construction instead of by two
        // call sites agreeing.
        //
        // Suppressed on the faces that address nobody: the list and the
        // settings panes are not conversations, and chips there would name a
        // session the face does not show. If the chips cannot be rendered,
        // the files do not ride — the disclosure IS the license to attach.
        switch state {
        case .settings, .pastAgents, .hidden:
            break
        default:
            if let target = replyTargetForDrop?() {
                let staged = stagedFiles?(target.sessionId) ?? []
                trayRow.apply(staged)
                trayRow.isHidden = staged.isEmpty
            } else {
                trayRow.apply([])
            }
        }

        // Controls belongs to every face where a gesture is the next thing you
        // might do, not to the grid alone (ruled 18 Aug). That is the grid — in
        // its own footer — and a card on stage, in the middle of its action
        // row. Deliberately NOT while a capture is in flight: arming,
        // listening, transcribing and the send countdown are the panel
        // mid-transaction, and a note explaining how to start the thing you are
        // already doing is furniture. Written as one rule off the state rather
        // than unhidden by each arm, so a face added later inherits the answer.
        cardControls.isHidden = !state.isCardOnStage

        // The action row exists exactly when a quiet action is visible. (The
        // slow-transcription tick unhides its own actions later and re-runs
        // this.)
        updateActionRowVisibility()
        // And the same rule for the line under it: an empty hint is not a line.
        syncHintVisibility()

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
                .font: ChromeType.mono(ofSize: 13, weight: .semibold),
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
        let font = ChromeType.mono(ofSize: 10, weight: .medium)
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
        let font = ChromeType.mono(ofSize: 10, weight: .medium)
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
    func updateActionRowVisibility() {
        // `cardControls` counts: it is a row member like any other, and a card
        // with no buttons but a Controls word still has a bottom line.
        actionRow.isHidden = [goButton, openPageButton, dontSendButton,
                              micSettingsButton, newSessionButton,
                              cancelTranscriptionButton, retryTranscriptionButton,
                              cardControls]
            .allSatisfy { $0?.isHidden ?? true }
        if let panel { resizeToFit(panel); position(panel) }
    }

    /// A hint with no words is not a line, and a label that says nothing still
    /// bills the face for one.
    ///
    /// `NSStackView` detaches HIDDEN views and only hidden ones, so an empty
    /// `hintLabel` costs its full line height plus the stack's 6pt spacing on
    /// every face that has no hint to give — most of them, and the grid is one.
    /// That is the ~19pt of dead air under the footer: the bottom line read as
    /// floating above the panel's floor instead of resting on the 12pt inset
    /// every other edge uses. Called from both writers of the text — render()'s
    /// arms and `note()` — so the two can never disagree about whether the line
    /// exists.
    /// The hint line, composed. Several hints name a mark — "▶ plays the
    /// capture", "drag ≡ to reorder" — and a mark typed into a `stringValue` is
    /// a mark nobody measured. Everything that writes this line goes through
    /// here.
    private func setHint(_ text: String) {
        hintLabel.attributedStringValue = ChromeType.line(
            text, font: hintLabel.font ?? StateLegend.Face.chrome(10),
            color: hintLabel.textColor ?? StateLegend.Lens.guidance.color)
        syncHintVisibility()
    }

    private func syncHintVisibility() {
        hintLabel.isHidden = hintLabel.stringValue.isEmpty
    }

    /// The grid's content width: the 380 panel minus the stack's 14pt insets.
    static let gridWidth: CGFloat = 352

    /// The ruled grid (draft variant C, ruled 05 Aug): 26px lamp, then the
    /// session NAME (the tab's string) owning the row, the minted callsign
    /// right-aligned in the remaining ≤38% — at a fixed 40px height, a
    /// hairline rule between rows (none after the last), capped at 8. Below
    /// the rows: a quiet "+ NEW SESSION" placard, then the strong rule above
    /// the key line. Tap = invite that session. Fixed height plus single-line
    /// labels is what kills the orphan fragments and ragged gaps the old
    /// free-height attributed-title rows produced.
    /// The floor. Eight rows is what the panel has always shown and what it
    /// shows on a quiet day: enough to hold the work you are actually doing.
    static let gridRowFloor = 8

    /// The ceiling, and it is a taste decision rather than an arithmetic one.
    /// A panel holding twenty agents is already at the edge of what reads as an
    /// instrument rather than a directory, and the graveyard exists for
    /// everything past it.
    static let gridRowCeiling = 20

    /// How many rows will FIT, which is a different question on every machine.
    ///
    /// Measured across the range, using the panel's own margins and the chrome
    /// it carries above and below the rows (top band, placard rule, the
    /// + NEW AGENT row, the key line, the footer — ~153pt):
    ///
    ///   13" 1440×900, the oldest baseline   16 rows
    ///   13.6" MacBook Air, default scaled   18 rows
    ///   14" MacBook Pro, default scaled     20 rows
    ///   16" MacBook Pro                     22 rows
    ///
    /// So the ceiling binds on every Mac from a 14" up, and the arithmetic
    /// binds below that. Computed rather than picking one number for all
    /// screens, because the one number would have to be 16 — and it would then
    /// be wrong by six rows on the machine this is being built on.
    static func gridRowCapacity(screen: NSScreen? = NSScreen.main) -> Int {
        guard let screen else { return gridRowFloor }
        let usable = screen.visibleFrame.height - 32   // the panel's own margins
        let forRows = usable - gridChromeHeight
        let fits = Int(forRows / (GridRowView.height + 1))
        return max(gridRowFloor, min(gridRowCeiling, fits))
    }

    /// Everything the grid face draws that is not a session row. Derived once
    /// from a measured panel rather than summed from constants, because half of
    /// it is intrinsic type height that no constant states.
    private static let gridChromeHeight: CGFloat = 153

    /// The two surfaces PARTITION one ordered list: what the grid draws, and
    /// everything else. Ruled 12 Aug — "if they're on the main grid, they
    /// should not appear here, by definition."
    ///
    /// Stated as a split of one array rather than as a filter on two queries,
    /// because a filter can be wrong in both directions at once and a split
    /// cannot: every session is in exactly one of these, and the proof is that
    /// they are a prefix and its remainder. A session that leaves the grid
    /// because something more urgent arrived appears in the list the moment it
    /// does, with no second rule to keep in agreement.
    static func pastAgents(_ rows: [StateLegend.SessionRow],
                           screen: NSScreen? = NSScreen.main) -> [StateLegend.SessionRow] {
        // Everything the grid did not draw, named by id rather than counted
        // off the front. It WAS a `dropFirst` of the grid's count, which is
        // only correct while the array is sorted so the grid's rows are its
        // leading run — and the moment membership became a predicate rather
        // than a length, that stopped being true. It failed loudly the same
        // evening: `gridAndListAreDisjoint` and `nothingIsLost` both went red,
        // which is a session drawn on neither face.
        let drawn = Set(gridRows(rows, screen: screen).map(\.id))
        return rows.filter { !drawn.contains($0.id) }
    }

    /// The rows the grid actually DRAWS — the count below, filled in
    /// priority order: lit first, then alive-but-quiet, then dead last.
    ///
    /// Ruled 18 Aug, on Robert's screenshot of row `0f2ea0d4` sitting on the
    /// grid with a dark socket while the process agreed it was idle: *"Why is
    /// there an idle fucking lamp? A turned-off lamp? In the goddamn grid. The
    /// grid. Is for lit. Fucking lamps. Idle lamps going past agents."* That
    /// ruling itself pre-empted exactly this reversal, in its own doc comment
    /// on the ORIGINAL version of this function: "Dead rows still sort last
    /// and still only reach the grid when the floor has slots going spare. If
    /// that is also wrong it is a separate ruling, with its own drills." It
    /// was: reversed 23 Aug, on a fresh screenshot — a dead test session
    /// (killed minutes earlier, on purpose) sitting in a floor slot while a
    /// genuinely live, idle session was bumped to the list instead. `.running`
    /// (alive, quiet) now competes for floor slots ahead of `.unlit` (dead) —
    /// still behind lit, and still gone the moment something urgent needs the
    /// room, same as before.
    ///
    /// `switchedOff` still leaves entirely, same reasoning as 18 Aug: the
    /// switch's whole job is to make a session idle by hand, and a row that
    /// competes for a floor slot despite being switched off would make the
    /// switch look broken. It is simply no longer classed WITH `.running` for
    /// that purpose — it is its own exclusion, checked first.
    ///
    /// Split from `gridRowsShown` because that number is GEOMETRY — how tall
    /// the panel is worth being, which is why it may exceed the rows that
    /// exist and why the floor holds on a quiet machine. Folding membership
    /// into it collapsed the floor and shipped a regression earlier the same
    /// evening (18 Aug).
    static func gridRows(_ rows: [StateLegend.SessionRow],
                         screen: NSScreen? = NSScreen.main) -> [StateLegend.SessionRow] {
        let eligible = rows.filter { !$0.switchedOff }
        let lit = eligible.filter { $0.lamp.isLit }
        let alive = eligible.filter { $0.lamp == .running }
        let dead = eligible.filter { $0.lamp == .unlit }
        return Array((lit + alive + dead)
                  .prefix(gridRowsShown(rows, screen: screen)))
    }

    /// How many row-slots the panel is worth: every LIT session, or your top
    /// eight, whichever is larger — clamped to what the screen can hold.
    ///
    /// RE-RULED 18 Aug, reversing the entitlement half of `27a49fd` on Robert's
    /// instruction and his screenshot: *"Why is there an idle fucking lamp? A
    /// turned-off lamp? In the goddamn grid. The grid. Is for lit. Fucking
    /// lamps. Idle lamps going past agents."* Row `0f2ea0d4` was drawn on the
    /// grid with an unlit socket; the process agreed it was idle.
    ///
    /// That earlier rule made ALIVENESS the entitlement, to stop live sessions
    /// being sent to page two while slots stood empty. Its case survives intact
    /// and is why the reversal is narrow: the sessions it was protecting were
    /// working or blocked, and both are LIT, so they still hold their rows. The
    /// only rows this takes back are the ones that are alive with nothing in
    /// flight — which is precisely the state the user's own switch produces,
    /// and it would be incoherent for the panel to file a session away when he
    /// turns its lamp off and keep it when it goes out by itself.
    ///
    /// So the grid is the instrument for NOW, in one sentence: it draws lit
    /// lamps. Everything else — idle, switched off, exited — is the list.
    static func gridRowsShown(_ rows: [StateLegend.SessionRow],
                              screen: NSScreen? = NSScreen.main) -> Int {
        let lit = rows.filter { $0.lamp.isLit && !$0.switchedOff }.count
        return min(gridRowCapacity(screen: screen), max(gridRowFloor, lit))
    }

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
        let shown = Self.gridRows(face.sessionRows)
        // ONE callsign column (ruled 05 Aug): sized to the widest callsign on
        // show, capped at 38% of the grid. Per-row widths made every name
        // truncate at its own x and the right side read as a rag, not a
        // column; a shared width gives one vertical boundary, callsigns
        // right-aligned into it, names truncating against it.
        let auxWidth = min(
            Self.gridWidth * GridRowView.auxFraction,
            shown.map {
                ceil(($0.aux as NSString)
                    .size(withAttributes: [.font: GridRowView.auxFont]).width)
            }.max() ?? 0)
        for (index, item) in shown.enumerated() {
            let row = GridRowView(item: item, auxWidth: auxWidth, target: self,
                                  action: #selector(sessionRowTapped(_:)))
            // The lamp column is the session's power switch, on every row.
            // Until 18 Aug only `.ready` got a target, so the column was a
            // control on one row in ten and part of the row everywhere else —
            // and a dark lamp, the one people reach for to bring a session
            // back, did whatever the ROW did. See `StateLegend.lampAction`.
            switch StateLegend.lampAction(for: item, on: .grid) {
            // On the grid the lamp files a session away. Every lit row, not
            // just green: "clicking an ON lamp turns it off. Turns it to idle.
            // It does not kill the process."
            case .turnOff:
                row.onLampTap = { [weak self] in self?.onClearLamp?(item.id) }
            case .revive:
                row.onLampTap = { [weak self] in
                    self?.onRevive?(item.id, item.name)
                }
            case .turnOn:
                // Unreachable: a filed row is never drawn on the grid — see
                // `gridRowsShown`. Logged rather than ignored, because if it
                // ever fires the membership rule has come apart.
                Permissions.log("grid: row \(item.id.prefix(8)) asked for turnOn "
                    + "on the grid — a filed row was drawn where it cannot be")
            }
            // GO TO AGENT and END SESSION ride the right-click, on exactly the
            // rows that have a process behind them — the same grammar the Past
            // Agents face has used since 13 Aug, now on the face people actually
            // look at. The terminate item NAMES its target, and that IS the
            // confirmation: a right-click, then a click on a sentence containing
            // the right name. No dialog after that, and none here either — the
            // grid would otherwise be the only surface in the app that asks twice.
            row.menu = rowMenu(for: item)
            waitingRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.gridWidth).isActive = true
            if index < shown.count - 1 {
                waitingRows.addArrangedSubview(hairline(StateLegend.Palette.hairlineSoft))
            }
        }
        // The proactive half (ruled 05 Aug addendum): the "+" placard kicks off
        // a fresh session — same code path as the menu item. Ruled 12 Aug it
        // shares its row with PAST AGENTS: both are ways of putting an agent on
        // this list, one by starting it and one by bringing it back, and two
        // 32pt rows for two halves of one idea was a row too many.
        waitingRows.addArrangedSubview(hairline(StateLegend.Palette.hairlineSoft))
        let newRow = SplitPlacardRowView(
            width: Self.gridWidth, target: self,
            leading: (StateLegend.newAgentTitle, "+", #selector(newSessionRowTapped)),
            trailing: (StateLegend.pastAgentsTitle, "↺", #selector(pastAgentsRowTapped)))
        waitingRows.addArrangedSubview(newRow)
        newRow.widthAnchor.constraint(equalToConstant: Self.gridWidth).isActive = true
        // The key line's top rule; the hint label follows in the outer stack.
        waitingRows.addArrangedSubview(hairline(StateLegend.Palette.hairline))

        // The layout self-check: geometry is ruled, so the log states it — and
        // singleLine proves the labels can never recreate the orphan fragments
        // ("**Voices for lif") between rows.
        let ready = shown.filter { $0.lamp == .ready }.count
        let closed = shown.filter { $0.lamp == .unlit }.count
        let revivable = shown.filter(\.revivable).count
        let singleLine = shown.allSatisfy {
            !$0.name.contains("\n") && !$0.aux.contains("\n")
        }
        Permissions.log("grid: \(shown.count) of \(face.sessionRows.count) rows "
            + "(\(ready) ready, \(closed) closed, \(revivable) revivable) "
            + "rowH=\(Int(GridRowView.height)) "
            + "cols=\(Int(GridRowView.lampColumn))/flex/aux\(Int(auxWidth)) "
            + "lamps=circular singleLine=\(singleLine)")
    }

    /// Wired by the app onto SessionLauncher.launch().
    var onNewSession: (() -> Void)?

    /// Wired by the app: build the list and show it.
    var onOpenPastAgents: (() -> Void)?
    /// Wired by the app: focus a LIVE session's terminal tab.
    var onGoToSession: ((String) -> Void)?

    // MARK: - The drop tray's three wires

    /// What is staged for a session right now, asked at render time rather
    /// than pushed and cached. The chips are then a PROJECTION of Core's tray
    /// — they cannot go stale, and there is no second copy of the truth to
    /// keep in step (the five-booleans lesson, applied to data instead of
    /// state).
    var stagedFiles: ((String) -> [String])?
    /// A drop landed on the panel. The app resolves the target, persists
    /// image data that has no file behind it, and stages. Returns false when
    /// it could not be taken, so the surface can say so instead of eating it.
    var onFilesDropped: (([DroppedItem]) -> Bool)?
    /// One chip's ✕: unstage that path for this session.
    var onUnstage: ((_ session: String, _ path: String) -> Void)?

    /// Who a drop would go to, and whose chips are therefore on screen. Nil
    /// refuses the drag outright — no overlay, no promise the app cannot keep
    /// (a "drop here" that then reports "nothing to reply to" is worse than a
    /// cursor that never invited you).
    ///
    /// ONE closure answers both questions on purpose. The invariant this
    /// feature lives or dies by is that the chips you can see are exactly the
    /// files that will ride; two resolutions could disagree, and the failure
    /// would be a file riding to a session the panel never named.
    ///
    /// Must be CHEAP — render() calls it on every repaint, and rule 9 says
    /// the main actor never waits. The app answers from a value it refreshes
    /// on its own tick, never by probing `claude agents --json` here.
    var replyTargetForDrop: (() -> (sessionId: String, label: String)?)?

    /// The name a picked row was showing, for the receipt.
    func pastListName(_ id: String) -> String {
        face.sessionRows.first { $0.id == id }?.name ?? StateLegend.shortId(id)
    }

    @objc nonisolated private func pastAgentsRowTapped() {
        MainActor.assumeIsolated { onOpenPastAgents?() }
    }

    /// Enter the list face. The rows are handed in whole and applied once —
    /// see `PastAgentsList`: this face does not refresh while it is read.
    /// Widen the open list's haystacks with what the sessions said, once the
    /// background read has finished. Refused unless the list is still the face
    /// on stage: a harvest that lands after the reader has moved on must not
    /// reach into a face nobody is looking at.
    func widenPastAgents(_ extra: [String: [UInt8]]) {
        guard case .pastAgents = state else { return }
        pastList?.widen(extra)
        hintLabel.stringValue = pastList?.summary ?? ""
    }

    func showPastAgents(items: [PastAgentsList.Item]) {
        guard transition(to: .pastAgents, because: "past agents opened") else { return }
        currentTarget = nil
        face = Face()
        pastList.apply(items: items)
        render()
        // The one face that asks for typing, so the one face that takes key
        // status — and it takes it only after the face is on screen, so a
        // failed transition can never leave the panel holding the keyboard.
        if let panel {
            panel.acceptsKey = true
            panel.makeKeyAndOrderFront(nil)
            pastList.beginFiltering()
        }
    }

    @objc nonisolated private func newSessionRowTapped() {
        MainActor.assumeIsolated { onNewSession?() }
    }

    /// The roster pane's rows: roster members first, in assignment order, then
    /// the rest grouped by category. Rows draw their own bottom hairline (no
    /// interleaved rule views), so an arranged index IS a row index — the ≡
    /// drag's arithmetic depends on that.
    private func rebuildVoiceRows() {
        voiceStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Same hazard as the agents probe in sessionRowsNow: `uniqueKeysWithValues:`
        // traps on a duplicate key, and `voices` is decoded from voices.json — data
        // from the account, not a literal we control. A repeated voice id would kill
        // the app on opening settings. First-seen wins; a duplicate id is the same
        // voice twice, so which copy survives cannot matter.
        let byId = Dictionary(face.voices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A roster id the catalog no longer lists has no row (nothing to play,
        // nothing to name); it stays in the persisted roster untouched until
        // the user next reorders, which saves exactly what is on screen.
        let cast = face.roster.compactMap { byId[$0] }
        // Caller order, not a re-sort.
        //
        // This sorted by (category, name), which was wrong twice over. It put
        // "Compact" ahead of "Premium" alphabetically, and once the category column
        // became a SIZE it started comparing "132 MB" < "479 MB" < "99 MB" as strings
        // — so Susan, the one row that is not installed, landed third in the list
        // instead of last. The catalogue already returns quality-ordered voices; the
        // view's job is to show them in the order it was given.
        let bench = face.voices.filter { !face.roster.contains($0.id) }
        // Except for rows you cannot use yet, which always sit at the bottom.
        let (offers, owned) = bench.reduce(into: ([Voice](), [Voice]())) { acc, v in
            if SystemVoiceCatalog.isDownloadRow(v.id) { acc.0.append(v) } else { acc.1.append(v) }
        }
        for voice in cast + owned + offers {
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
        // The door to the settings state's other pane, as a last row rather
        // than masthead chrome: the placard band's lanes are drilled and
        // spoken for (see the lane comment above), and a row costs nothing.
        // The "Recent audio ▸" link row is gone: it is a TAB now, so the voices
        // list stops carrying a door to somewhere else in the middle of itself.
        // That row was the whole reason this pane read as one long column.
        voiceListHeight.constant = min(
            CGFloat(voiceStack.arrangedSubviews.count) * VoiceRowView.height, 340)
        Permissions.log("roster pane: \(cast.count) cast + \(bench.count) bench rows")
    }

    /// The recent-audio pane's rows, into the same stack the roster pane uses
    /// — one list slot, whichever pane owns the face. Rows draw their own
    /// hairline, same as the roster's.
    private func rebuildAudioRows(_ events: [AudioEventRow]) {
        voiceStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for event in events {
            let row = AudioEventRowView(
                event: event,
                onPlay: { [weak self] in self?.onPlayAudioEvent?(event.id) },
                onRetry: { [weak self] in self?.onRetryAudioEvent?(event.id) },
                onReveal: { [weak self] in self?.onRevealAudioEvent?(event.id) })
            voiceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.gridWidth).isActive = true
        }
        voiceListHeight.constant = min(
            CGFloat(voiceStack.arrangedSubviews.count) * AudioEventRowView.height, 340)
        Permissions.log("recent-audio pane: \(events.count) row(s), "
            + "\(events.filter { $0.transcript == nil }.count) without a transcript")
    }

    var audioEventRowCount: Int {
        voiceStack.arrangedSubviews.compactMap { $0 as? AudioEventRowView }.count
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
    ///
    /// `internal`, not `private` (App-lane P5, 24 Aug): read and written from
    /// `Receipt.swift`'s `ackBarLayer()`/`holdAcknowledge()`/`releaseAcknowledge()`/
    /// `acknowledge()`, which moved there while these stored properties — which
    /// Swift extensions cannot add — stayed here.
    var ackBar: NSView?
    var ackHeld = false
    /// The pending fade. Held so the next press inside the window can cancel it
    /// — cancelling is what turns two presses into one light.
    var ackStandDown: DispatchWorkItem?
    /// The height last requested of the panel — the resize's own memory, so an
    /// in-flight animation cannot be mistaken for a settled size.
    var intendedHeight: CGFloat?
    /// `internal`, not `private` (App-lane P5, 24 Aug): set by `build()` (now
    /// in `Build.swift`), read by `Receipt.swift`'s receipt/acknowledge code —
    /// both moved out of this file, this stayed for the same reason `ackBar`
    /// did.
    var surfaceView: NSView?
    /// The same view as `surfaceView`, typed: the drill drives the drag
    /// callbacks directly, since a synthetic NSDraggingInfo is not something
    /// a launch drill can conjure.
    var dropSurface: DropSurfaceView?
    /// The send-receipt chip and its pending fade — stored here for the same
    /// reason as `ackBar` above; `showReceipt`/`clearReceipt` (`Receipt.swift`)
    /// read and write both.
    var receiptChip: NSTextField?
    var receiptFade: DispatchWorkItem?

    /// Shown the instant ⌃⌥ is tapped, so the gap before audio isn't dead air.
    /// Summarizing and fetching the voice take a few seconds; without this the app
    /// looks broken for the whole of it.
    ///
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

    func goHomeFromPastAgents() {
        releaseKeyboard()
        showIdle(rows: [])
    }

    /// Give the keyboard back. Called on every door out of the list face, and
    /// safe to call when it was never taken: a panel that cannot become key
    /// cannot be holding it.
    private func releaseKeyboard() {
        guard let panel, panel.acceptsKey else { return }
        panel.acceptsKey = false
        panel.makeFirstResponder(nil)
        panel.resignKey()
        // Ordering front without key hands focus back to whatever had it,
        // rather than leaving a keyboard nobody owns.
        panel.orderFront(nil)
    }



    @objc func collapseTapped() { setCollapsed(true) }

    // MARK: - Actions

    /// True while a "go to session" jump is in flight. Re-clicks on a stalled
    /// jump were how one slow osascript became eleven hang reports (issue 14):
    /// each click queued another synchronous walk behind the first.
    var goToSessionInFlight = false

    /// Bring the originating terminal tab to the front.
    ///
    /// Same addressing chain the dispatcher uses — pid to tty to tab — so "go to
    /// session" lands on exactly the tab a reply would be typed into, rather than
    /// merely activating Terminal and leaving you to find it.
    ///
    /// Everything that can block — the ps spawn, the Apple events — runs off the
    /// main actor. A busy Terminal is entitled to sit on an Apple event for up to
    /// its two-minute default timeout, and a main-thread block past ~1 s trips the
    /// event-tap watchdog and silently kills the hotkeys; the 12 Aug beach ball
    /// (issue 14) was this method paying both prices at once. Main only flips the
    /// in-flight guard and paints labels.
    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated func goToSession() {
        MainActor.assumeIsolated {
            guard !goToSessionInFlight else { return }
            guard let target = currentTarget, let pid = target.pid else {
                bodyLabel.stringValue = "That agent is no longer running, so there's no tab to open."
                return
            }
            let sessionId = target.sessionId
            goToSessionInFlight = true
            let priorBody = bodyLabel.stringValue
            bodyLabel.stringValue = "Opening that session's tab…"
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let tty = ProcessProbe.tty(of: pid) else {
                    Permissions.log("goToSession: no tty for pid \(pid)")
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.goToSessionInFlight = false
                        self.bodyLabel.stringValue =
                            "Couldn't find a terminal for process \(pid). It may have exited."
                    }
                    return
                }
                // No parallel human+tmux session, ever (ruled 23 Aug):
                // bringing a hand-started session forward TRANSFERS it, the
                // same mechanism `Coordinator.dispatch`'s `resumeTwin` uses
                // on its first reply — not a special case for typing into
                // it. A tmux-owned tty already means this happened before;
                // only a bare tty (no pane) triggers the transfer here.
                if TmuxOwnership.pane(forTty: tty) == nil {
                    Permissions.log("goToSession: \(tty) is hand-started — transferring to tmux")
                    guard let transferred = SessionLauncher.OwnershipTransfer.toTmux(sessionId: sessionId)
                    else {
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.goToSessionInFlight = false
                            self.bodyLabel.stringValue =
                                "Couldn't move that session under tmux — it may still be "
                                + "running in its own terminal. Nothing was closed."
                        }
                        return
                    }
                    await MainActor.run { [weak self] in
                        self?.attachLivePid(transferred.pid, sessionId: sessionId)
                    }
                    let outcome = await TerminalTabFocus.focus(tty: transferred.pane.paneTty)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.goToSessionInFlight = false
                        switch outcome {
                        case .focused:
                            self.bodyLabel.stringValue = priorBody
                            Permissions.log("goToSession: transferred and focused "
                                + "\(transferred.pane.paneTty)")
                        default:
                            // The transfer itself succeeded — a follow-up window
                            // failing to open is the SAME class of failure the
                            // outcomes below already report, just one hop later.
                            self.bodyLabel.stringValue =
                                "Moved that session under tmux, but couldn't open a window "
                                + "for it. It's reachable — try Go to Agent again."
                            Permissions.log("goToSession: transfer ok, open failed: \(outcome)")
                        }
                    }
                    return
                }
                let outcome = await TerminalTabFocus.focus(tty: tty)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.goToSessionInFlight = false
                    switch outcome {
                    case .focused:
                        // The jump worked; the card says what it said before,
                        // not a stale "Opening…".
                        self.bodyLabel.stringValue = priorBody
                        Permissions.log("goToSession: focused \(tty)")
                    case .tabGone:
                        self.bodyLabel.stringValue =
                            "That agent's tab isn't open in Terminal any more (\(tty))."
                        Permissions.log("goToSession: tab not found for \(tty)")
                    case .timedOut(let seconds):
                        self.bodyLabel.stringValue =
                            "Terminal didn't answer within \(seconds) seconds, it looks busy. The tab is still there; try again in a moment."
                        Permissions.log("goToSession TIMEOUT after \(seconds)s for \(tty)")
                    case .failed(let message):
                        self.bodyLabel.stringValue = "Couldn't control Terminal: \(message)"
                        Permissions.log("goToSession FAILED: \(message)")
                    }
                }
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
            .font, value: StateLegend.Face.message(12), range: full)
        bodyLabel.attributedStringValue = attributed

        Permissions.log("highlight rendered bright=\(inkBrightLength)/\(full.length)")
    }

    /// `paintInk` under a name that says why a drill is calling it: to repaint
    /// the body without changing a word of it.
    func paintInkForTesting(displayCursor: Int) { paintInk(displayCursor: displayCursor) }

    /// How many characters are currently painted as spoken. Read from the
    /// PIXELS, not from `face.spokenUpTo` — a drill that asked the field would
    /// only prove the field agrees with itself, and the defect being guarded
    /// against is precisely the pixels disagreeing with the face.
    ///
    /// `internal`, not `private` (App-lane P2, 23 Aug): a `TestSurface`
    /// requirement, conformed to from `TestSurface.swift` rather than from
    /// an extension inside this file — a `private` witness is invisible
    /// across that file boundary.
    var inkBrightLength: Int {
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
    @objc nonisolated func micSettingsTapped() {
        MainActor.assumeIsolated { onOpenSettings?() }
    }

    @objc nonisolated func gearTapped() {
        MainActor.assumeIsolated { onOpenSettings?() }
    }

    // The separate waiting-list face is gone (WS-B): the idle grid IS the list,
    // so showWaitingList/onOpenWaitingList and the clickable count pill went
    // with it — one face, not two near-identical lists.

    /// One tap, two verbs, and the row decides which.
    ///
    /// A live row is answered; a row whose session has exited is brought back.
    /// The branch is on the ROW rather than on the lamp alone, because
    /// `revivable` carries the guard that matters: an unlit row whose liveness
    /// was merely unprovable offers nothing, and tapping it must do nothing
    /// rather than announce a session that is not there.
    @objc nonisolated func sessionRowTapped(_ sender: NSControl) {
        MainActor.assumeIsolated {
            guard let id = sender.identifier?.rawValue else { return }
            guard let row = face.sessionRows.first(where: { $0.id == id }) else {
                onPickWaiting?(id); return
            }
            switch StateLegend.action(for: row) {
            case .announce: onPickWaiting?(id)
            // Amber has one useful destination and it is not the voice: the
            // row already carries the reason in its own column, and the thing
            // it cannot tell you is which tab to fix it in.
            case .goToAgent: onGoToSession?(id)
            case .revive: onRevive?(id, row.name)
            case .none:
                Permissions.log("grid: tap on \(id.prefix(8)) — unlit and not revivable, "
                    + "no action (liveness unproven, or its directory is gone)")
            }
        }
    }

    /// The right-click menu for a grid row, or nil for a row with no process
    /// behind it.
    ///
    /// Liveness decides, not the lamp's colour: an unlit row is either a session
    /// that has already exited (REVIVE is its verb) or one whose liveness could
    /// not be proven, and offering to kill a process we cannot see is a control
    /// that can only lie. `StateLegend.isLive` asks that question through the
    /// same function the left-click branches on, so the two can never drift.
    ///
    /// Two items, in that order (ruled 18 Aug). GO TO AGENT first because it is
    /// the harmless one and by far the common one — the card has carried that
    /// door since the beginning, and the grid is where you are actually looking
    /// when you want it. END SESSION keeps the bottom, behind a separator, so
    /// the destructive item is never where the pointer lands by momentum.
    ///
    /// GO TO AGENT is offered on EVERY live row, amber included, where it
    /// duplicates the left-click. That repetition is deliberate: a menu that
    /// hid the item on the one lamp whose tap already does it would be teaching
    /// the exception rather than the rule.
    private func rowMenu(for item: StateLegend.SessionRow) -> NSMenu? {
        guard StateLegend.isLive(item) else { return nil }
        let menu = NSMenu()
        let go = NSMenuItem(title: "Go to agent",
                            action: #selector(goToAgentGridRowPicked(_:)),
                            keyEquivalent: "")
        go.target = self
        go.representedObject = item.id
        menu.addItem(go)
        menu.addItem(.separator())
        // The item NAMES its target, and that IS the confirmation.
        let end = NSMenuItem(title: "End session \u{201C}\(item.name)\u{201D}",
                             action: #selector(terminateGridRowPicked(_:)),
                             keyEquivalent: "")
        end.target = self
        end.representedObject = item.id
        menu.addItem(end)
        return menu
    }

    @objc nonisolated private func goToAgentGridRowPicked(_ sender: NSMenuItem) {
        // Same hop discipline as the terminate item below: the id is lifted out
        // here, where the menu item is task-isolated, and only a Sendable String
        // crosses to the main actor.
        let picked = sender.representedObject as? String
        MainActor.assumeIsolated {
            guard let id = picked else { return }
            onGoToSession?(id)
        }
    }

    @objc nonisolated private func terminateGridRowPicked(_ sender: NSMenuItem) {
        // The id is lifted out of the menu item BEFORE the hop. Handing the
        // NSMenuItem itself to a main-actor closure is what the compiler calls a
        // data race, and it is right: the item is task-isolated here. A String
        // is Sendable and carries everything this needs.
        let picked = sender.representedObject as? String
        MainActor.assumeIsolated {
            guard let id = picked,
                  let row = face.sessionRows.first(where: { $0.id == id }) else { return }
            onTerminateSession?(id, row.name)
        }
    }

    /// For the launch drill: which grid rows exist and whether each carries the
    /// row menu — asserted against liveness, never assumed from it.
    var gridRowsForTesting: [(id: String, hasMenu: Bool)] {
        waitingRows.arrangedSubviews.compactMap {
            guard let row = $0 as? GridRowView, let id = row.identifier?.rawValue
            else { return nil }
            return (id, row.menu != nil)
        }
    }

    @objc nonisolated func backTapped() {
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
