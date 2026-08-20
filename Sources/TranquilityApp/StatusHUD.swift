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

    private var panel: ConsolePanel?
    private var titleLabel: DoorLabel!
    private var bodyLabel: CardBodyLabel!
    private var stateLabel: DoorLabel!
    private var goButton: ConsoleButton!
    /// The readback face's ONE negative (simplification pass, ruled): a quiet
    /// text action, not a lozenge. The Reply/Dismiss buttons are dead — chords
    /// are the interface.
    private var dontSendButton: ConsoleButton!
    private var micSettingsButton: ConsoleButton!
    private var newSessionButton: ConsoleButton!
    private var openPageButton: ConsoleButton!
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
    /// What the last Don't send asked for, so the drill can see §D hold.
    /// Nil until the button is pressed; the ruling says it must then be false.
    private var dontSendRestartedListening: Bool?
    /// The grid's bottom line: `Controls` left, the wordmark right. Its own
    /// widget rather than more text in `hintLabel`, because it is two things at
    /// two edges and one of them is a hover target — the hint slot stays what
    /// it is, a sentence, and the settings pane keeps using it unchanged.
    private var gridFooter: GridFooterView!
    /// The hover sticky, parented to `background` rather than the content
    /// stack: it must appear without moving anything. A revealed ROW would push
    /// the grid up and resize the panel on a mouse-over, which is the same
    /// reflow-on-hover the collapsed strip forbids, for the same reason.
    private var controlsSticky: ControlsNoteView!
    /// The card's copy of the word, in the middle of the action row. The grid's
    /// copy lives in its footer; both drive `setControlsNote(open:above:)`, so
    /// there is one note and one behaviour behind two placements.
    private var cardControls: ControlsWordView!
    /// Where the note is currently hung. Rebuilt on every open, because the row
    /// that owns the word changes with the face.
    private var stickyPlacement: [NSLayoutConstraint] = []
    private var stripLabel: NSTextField!
    private var stripRule: NSView!
    /// The drop tray's chips: what would ride the next voice reply to the
    /// session currently addressed. A row in the content stack like any other
    /// — it extends the panel downward rather than displacing the card, the
    /// same geometry the capture strip already uses.
    private var trayRow: TrayRowView!
    /// The whole-surface drop invitation, parented to `background` so it
    /// covers every face without joining the stack (a row would resize the
    /// panel mid-drag, which is reflow under the pointer).
    private var dropOverlay: DropOverlayView!
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
    private var pastList: PastAgentsList!
    private var settingsTabs: SettingsTabBar!
    private var launchRow: SettingRowView!
    private var directoryRow: SettingRowView!
    private var voiceStack: NSStackView!
    private var voiceListHeight: NSLayoutConstraint!
    private var gearButton: ConsoleButton!
    private var collapseButton: ConsoleButton!
    private var backButton: ConsoleButton!
    private var pastBackButton: ConsoleButton!
    private var waitingRows: NSStackView!
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
    private var actionRow: NSStackView!
    private static let spokenMark = NSAttributedString.Key("vdSpoken")

    private var currentTarget: (sessionId: String, pid: Int?, label: String)?

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

    /// The top band is shared, and this is the only thing that says so.
    ///
    /// Four things want the strip above the first row, and they arrive from
    /// four unrelated places: the collapse chevron (far left, a constraint),
    /// the state placard (leading, in the stack), the send receipt (right, a
    /// floating chip positioned in code from the gear's own frame) and the gear
    /// (trailing, a constraint). Nothing composes them — each one is correct on
    /// its own and the collisions only exist between them.
    ///
    /// They have collided twice. The collapse control was first parked beside
    /// the gear, where the next send drew "→ SENDING" straight through it; it
    /// now owns the far-left corner and the comment on its constraint says why.
    /// The grid's AGENTS placard then drew through the chevron, and the 24pt
    /// first-line indent on that string is the fix. Both were found by looking
    /// at the panel, which is the expensive way.
    ///
    /// So the rule, stated once: **the top band is divided into four lanes that
    /// may touch but never overlap, in this order — collapse, placard, receipt,
    /// gear.** Anything new in that band takes a lane or takes someone's.
    private func topBandDrill() {
        guard let host = panel?.contentView else { return }
        func rect(_ v: NSView?) -> CGRect {
            guard let v, !v.isHidden, let parent = v.superview else { return .null }
            return parent.convert(v.frame, to: host)
        }
        // The placard's LABEL is 348pt wide by constraint; what occupies the
        // band is its ink, offset by whatever indent the string carries.
        func inkRect(_ label: NSTextField?) -> CGRect {
            guard let label, !label.isHidden else { return .null }
            var r = rect(label)
            guard !r.isNull else { return .null }
            let text = label.attributedStringValue
            guard text.length > 0 else { return .null }
            let indent = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                            as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
            r.origin.x += indent
            r.size.width = min(r.width - indent, ceil(text.size().width) + 1)
            return r
        }
        func clear(_ a: CGRect, _ b: CGRect) -> Bool {
            a.isNull || b.isNull || !a.intersects(b)
        }

        // Expanded, explicitly. The collapsed drill runs before this one and
        // leaves the panel 40pt wide, where the placard and the gear are both
        // hidden — so this measured a band that wasn't on screen. It is the
        // EXPANDED top band that has four tenants; the collapsed strip has its
        // own geometry and its own drill.
        setCollapsed(false)
        // The worst case on purpose: the grid (which is the only face showing
        // the chevron) under a receipt whose callsign is long enough to reach.
        showIdle(note: nil, rows: [
            .init(id: "t1", name: "Fix hero image binding",
                  aux: "a8323d60", lamp: .ready),
        ])
        showReceipt(.sending("bookmarks provenance track a rebuild"))
        // Not layoutSubtreeIfNeeded alone: expanding out of the collapsed strip
        // animates the frame from 40pt to 380pt, and a lane measured while that
        // is in flight reads the stack's leading edge wherever the animator
        // happens to have left it. Measured mid-flight on the first run —
        // collapse=10..36 placard=26..87, a 10pt overlap that does not exist
        // once the panel has stopped moving. Geometry is a lie while the
        // animator is running, which is exactly what settleAnimations is for.
        settleAnimations()

        let collapse = rect(collapseButton)
        let placard = inkRect(stateLabel)
        let chip = rect(receiptChip)
        let gear = rect(gearButton)

        SelfTest.report("topBand", [
            ("collapseClearsPlacard", clear(collapse, placard)),
            ("placardClearsReceipt", clear(placard, chip)),
            ("receiptClearsGear", clear(chip, gear)),
            ("collapseClearsReceipt", clear(collapse, chip)),
            ("lanesAreInOrder", collapse.isNull || placard.isNull
                || collapse.maxX <= placard.minX),
        ])
        // `.null` is how `rect` says "not on screen", and its minX is
        // infinity — which `Int(_:)` does not convert, it TRAPS. That killed
        // the whole self-test run on the first deploy after this drill landed,
        // in the log line rather than the assertions, and the assertions had
        // already reported PASS. A diagnostic that can crash the thing it is
        // diagnosing is worse than no diagnostic.
        func span(_ r: CGRect) -> String {
            r.isNull || !r.minX.isFinite || !r.maxX.isFinite
                ? "—" : "\(Int(r.minX))..\(Int(r.maxX))"
        }
        Permissions.log("selftest topBand: collapse=\(span(collapse))"
            + " placard=\(span(placard)) receipt=\(span(chip))"
            + " gear=\(span(gear))")
        clearReceipt()
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

    @objc nonisolated private func breadcrumbClicked() {
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

    /// One audio event the pane can show: a capture over a second, with the
    /// FULL transcript it has (nil = none — a row that failed every provider,
    /// or was cancelled before one answered). Full, not pre-truncated: the
    /// label truncates visually, and the ⋯ menu's Copy hands over the whole
    /// thing — the pane is where a clipped transcript gets un-clipped.
    struct AudioEventRow {
        let id: String
        let timeLabel: String
        let durationLabel: String
        let transcript: String?
        var playing = false
        var retrying = false
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
    private func pickAgentDirectory() {
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

    private var transcribingTimer: Timer?
    private var cancelTranscriptionButton: ConsoleButton!
    private var retryTranscriptionButton: ConsoleButton!

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
                    about: (sessionId: String, label: String)? = nil) {
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
                currentTarget = (sessionId: about.sessionId, pid: nil, label: about.label)
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

    @objc nonisolated private func openHubTapped() {
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
            leaving(for: next)
            Permissions.log("state: \(state.name) -> \(next.name)  (\(reason))")
            state = next
        }
        entered(next)
        return true
    }

    /// The user's door. Explicit actions (Dismiss, hiding the panel, committing a
    /// send) are never stale, so they bypass the table — but they announce it.
    private func forceTransition(to next: PanelState, because reason: String) {
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
    private var drillsHoldThePanel = false
    private var drillRelease: DispatchWorkItem?

    /// Take the panel. Idempotent, and it always arms a release.
    private func beginDrills() {
        drillsHoldThePanel = true
        drillRelease?.cancel()
        // A hard ceiling, because relaunch.sh passes --selftest-hud on EVERY
        // deploy: a flag that stuck would leave the panel permanently deaf to
        // its own sessions, and it would do it quietly, on every machine, after
        // every merge. The drills take well under this; the timeout exists to
        // be wrong in the safe direction.
        let release = DispatchWorkItem { [weak self] in self?.endDrills() }
        drillRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: release)
        Permissions.log("selftest: drills hold the panel — ambient repaints suspended")
    }

    private func endDrills() {
        guard drillsHoldThePanel else { return }
        drillsHoldThePanel = false
        drillRelease?.cancel()
        drillRelease = nil
        Permissions.log("selftest: drills released the panel")
    }

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
            // No count here. It said "8 OF 45" and shared a lane with the send
            // receipt, so "✓ SENT" and the count fought for the same pixels —
            // and the count was answering a question the list face now owns
            // outright. The placard is a placard again.
            let stripTitle = NSMutableAttributedString(attributedString: letterspaced(
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
                renderCaptureStrip(placardText(StateLegend.readbackPlacard),
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
            stateLabel.attributedStringValue = placardText(
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
            stateLabel.attributedStringValue = letterspaced(
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
                // The per-section legends carry the counts now, so the masthead
                // stops reporting a total across two rosters — "26 of 56" was a
                // sum of two things and described neither.
                bodyLabel.stringValue = face.body
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
            stateLabel.attributedStringValue = placardText(notice, color: noticeLens.color)
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
    private func updateActionRowVisibility() {
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

    /// The rows the grid actually DRAWS — the count below, minus the sessions
    /// whose lamp is out because nothing is in flight.
    ///
    /// Ruled 18 Aug, on Robert's screenshot of row `0f2ea0d4` sitting on the
    /// grid with a dark socket while the process agreed it was idle: *"Why is
    /// there an idle fucking lamp? A turned-off lamp? In the goddamn grid. The
    /// grid. Is for lit. Fucking lamps. Idle lamps going past agents."*
    ///
    /// So `.running` leaves, and it leaves alongside `switchedOff` because they
    /// are the SAME STATE arrived at two ways — the switch's whole job is to
    /// make a session idle, and a panel that files one and keeps the other
    /// makes the switch look broken.
    ///
    /// **Deliberately narrow: `.unlit` is NOT excluded here.** A first attempt
    /// read the ruling as "lit only" and took the dead rows too, which turned
    /// four unrelated drills red — they seed closed rows and read them back off
    /// the grid — and none of that was asked for. He pointed at an idle lamp,
    /// not a dead one, and the 11 Aug ruling that a session keeps its row after
    /// its process ends has not been revisited. Dead rows still sort last and
    /// still only reach the grid when the floor has slots going spare. If that
    /// is also wrong it is a separate ruling, with its own drills.
    ///
    /// Split from `gridRowsShown` because that number is GEOMETRY — how tall
    /// the panel is worth being, which is why it may exceed the rows that
    /// exist and why the floor holds on a quiet machine. Folding membership
    /// into it collapsed the floor and shipped a regression earlier the same
    /// evening.
    static func gridRows(_ rows: [StateLegend.SessionRow],
                         screen: NSScreen? = NSScreen.main) -> [StateLegend.SessionRow] {
        Array(rows.filter { $0.lamp != .running && !$0.switchedOff }
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

    /// One dragged item, already resolved to something durable. A file drag
    /// carries a path; a drag out of a browser carries bitmap data with no
    /// file behind it, which the app writes to disk before this reaches Core.
    enum DroppedItem {
        case file(String)
        case imageData(Data, suggestedName: String)
    }

    /// The name a picked row was showing, for the receipt.
    private func pastListName(_ id: String) -> String {
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

        // TWO lists, because there are two rosters.
        //
        // One flat list was not a presentation choice, it was the bug's habitat:
        // the pane listed both families and its toggle appended whatever was
        // checked to the single ElevenLabs roster, so checking a system voice put
        // an Apple identifier into the cloud rotation and ElevenLabs answered
        // HTTP 400 `invalid_uid` every five seconds. Storage is two files now, and
        // this is the pane finally saying so.
        //
        // Order inside a section is unchanged — cast in roster order, then the
        // bench in catalogue order, then rows you do not own — so nothing about
        // reading a section is new. Only the boundary is.
        func isSystem(_ v: Voice) -> Bool {
            SystemVoiceCatalog.isSystemVoice(v.id) || SystemVoiceCatalog.isDownloadRow(v.id)
        }
        var headerAir: CGFloat = 0
        let sections: [(title: String, note: String?, voices: [Voice], available: Int)] = [
            ("ElevenLabs",
             "spoken when available",
             cast.filter { !isSystem($0) } + owned.filter { !isSystem($0) },
             face.voices.filter { !isSystem($0) }.count),
            ("System",
             "the fallback, per agent",
             cast.filter(isSystem) + owned.filter(isSystem) + offers,
             face.voices.filter(isSystem).count),
        ]

        for section in sections {
            // A section with nothing in it is not drawn. A machine with no
            // ElevenLabs key has no paid rows at all, and an empty legend over
            // empty space would be the pane describing something absent.
            guard !section.voices.isEmpty else { continue }
            let onRoster = section.voices.filter { face.roster.contains($0.id) }.count
            let followingRows = !voiceStack.arrangedSubviews.isEmpty
            headerAir += VoiceSectionHeaderView.height(followingRows: followingRows)
            voiceStack.addArrangedSubview(VoiceSectionHeaderView(
                title: section.title, onRoster: onRoster,
                available: section.available, note: section.note,
                followingRows: followingRows))
            voiceStack.arrangedSubviews.last?
                .widthAnchor.constraint(equalToConstant: Self.gridWidth).isActive = true

            for voice in section.voices {
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
        }
        // Height counts BOTH kinds of view, or the list clips by one header per
        // section — the rows are a fixed height and so is a legend, so this stays
        // arithmetic rather than a layout pass.
        let rowCount = voiceStack.arrangedSubviews.compactMap { $0 as? VoiceRowView }.count
        let headerCount = voiceStack.arrangedSubviews.count - rowCount
        voiceListHeight.constant = min(
            CGFloat(rowCount) * VoiceRowView.height + headerAir, 340)
        Permissions.log("roster pane: \(cast.count) cast + \(bench.count) bench rows"
                        + " across \(headerCount) section(s)")
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
    /// A drag reorders a voice within ITS OWN roster.
    ///
    /// Two things changed with the pane's two sections. The stack now holds
    /// section legends as well as rows, so a filtered row index is no longer a
    /// stack index — the old code used one as the other, which was correct only
    /// while the two lists were one. And a voice cannot be dragged into the other
    /// roster, because which roster it belongs to is a fact about the voice, not
    /// a position in a list.
    private func dragRosterRow(_ row: VoiceRowView, by steps: Int) {
        guard steps != 0 else { return }
        let views = voiceStack.arrangedSubviews
        let system = SystemVoiceCatalog.isSystemVoice(row.voiceId)
            || SystemVoiceCatalog.isDownloadRow(row.voiceId)
        // The cast rows of this row's own section, as STACK indices.
        let peers = views.indices.filter { index in
            guard let peer = views[index] as? VoiceRowView, peer.isOnRoster else { return false }
            let peerIsSystem = SystemVoiceCatalog.isSystemVoice(peer.voiceId)
                || SystemVoiceCatalog.isDownloadRow(peer.voiceId)
            return peerIsSystem == system
        }
        guard let from = views.firstIndex(of: row), let slot = peers.firstIndex(of: from)
        else { return }
        let targetSlot = max(0, min(peers.count - 1, slot + steps))
        guard targetSlot != slot else { return }
        voiceStack.removeArrangedSubview(row)
        voiceStack.insertArrangedSubview(row, at: peers[targetSlot])
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
    /// The same view as `surfaceView`, typed: the drill drives the drag
    /// callbacks directly, since a synthetic NSDraggingInfo is not something
    /// a launch drill can conjure.
    private var dropSurface: DropSurfaceView?

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
        /// Tapping a row whose session has exited. A receipt rather than a card
        /// for the same reason a send is: it is an event, not state, and a
        /// Terminal window is about to appear and say the rest.
        case reviving(String)
        /// The refusal that keeps the app alive. Between the last grid refresh
        /// and the tap, the session came back on its own — resuming it now
        /// would put two processes under one id, which crashed the app twice.
        case alreadyAwake
        /// The switch was thrown and the session did NOT come back, for a
        /// reason that is not "it was already running".
        ///
        /// Split out of `alreadyAwake` on 18 Aug. That case was carrying three
        /// different outcomes — live, directory gone, liveness unprovable — and
        /// telling you the same thing about all of them, so two thirds of the
        /// time the panel's only word on the subject was false. Tolerable while
        /// revive lived behind a hover verb; not tolerable now that the lamp is
        /// the switch, because a switch that lies about why it did nothing is
        /// worse than one that does nothing.
        case notRevived(String)

        /// Green is for a thing that landed. Reviving is in flight, and a
        /// refusal did not land at all.
        var landed: Bool {
            switch self {
            case .sent, .queued: return true
            case .sending, .reviving, .alreadyAwake, .notRevived: return false
            }
        }

        /// Still happening, so the chip gets the longer ceiling and logs if no
        /// outcome ever replaces it. A refusal is an outcome already.
        var inFlight: Bool {
            switch self {
            case .sending, .reviving: return true
            case .sent, .queued, .alreadyAwake, .notRevived: return false
            }
        }

        var text: String {
            switch self {
            case .reviving(let target):
                let name = target.count > 18
                    ? target.prefix(17).trimmingCharacters(in: .whitespaces) + "…"
                    : target
                return "↺ \(name.uppercased()) · RESUMING"
            case .alreadyAwake: return "ALREADY RUNNING"
            case .notRevived(let why): return "↺ \(why.uppercased())"
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
        chip.attributedStringValue = letterspaced(
            receipt.text, size: 9, tracking: 1.4,
            color: receipt.landed ? StateLegend.Palette.ready : StateLegend.Palette.secondary)
        chip.sizeToFit()
        // Right edge measured from the gear itself rather than a guessed
        // margin, so the two never collide whatever the panel width.
        let gearLeft = gearButton.superview.map { view in
            view.convert(gearButton.frame, to: host).minX
        } ?? host.bounds.width - 34
        // LEFT edge measured from the placard's ink, for the same reason, and
        // this half was missing: a long callsign simply grew leftwards until it
        // was drawing through "A G E N T S". Found by topBandDrill on its first
        // run — placardClearsReceipt=false — which is the collision the top
        // band's whole lane rule exists to prevent, sitting in the shipping
        // build the entire time.
        //
        // The chip yields, not the placard: the placard is the face's own name
        // for itself and is already as short as it goes, while the chip is a
        // callsign that reads perfectly well truncated, because its first
        // words are the ones that identify it.
        var placardRight: CGFloat = 0
        if !stateLabel.isHidden, stateLabel.attributedStringValue.length > 0,
           let parent = stateLabel.superview {
            let box = parent.convert(stateLabel.frame, to: host)
            let text = stateLabel.attributedStringValue
            let indent = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                            as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
            placardRight = box.minX + indent + ceil(text.size().width)
        }
        let lane = max(40, gearLeft - 10 - (placardRight + 12))
        let chipWidth = min(chip.bounds.width, lane)
        chip.lineBreakMode = .byTruncatingTail
        chip.frame = CGRect(x: gearLeft - chipWidth - 10,
                            y: host.bounds.height - 22,
                            width: chipWidth, height: chip.bounds.height)
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
        let linger: TimeInterval = receipt.inFlight ? 12.0 : 4.0
        let fade = DispatchWorkItem { [weak self, weak chip] in
            guard let chip else { return }
            if receipt.inFlight { Permissions.log("receipt: \(receipt.text) timed out on screen") }
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

    /// Prove that LEAVING the read-back stops the send — not just pressing the
    /// button whose name says so.
    ///
    /// `selfTestPendingSend` below calls `cancelPendingSend` directly, which is
    /// the one door that was never broken; it could not have caught 18 Aug's
    /// incident and did not. This drill goes through the door the GESTURE uses:
    /// a new capture takes the stage out of `.pendingSend`, exactly as ⌥⌥ does.
    ///
    /// Synchronous, and it stands its own fixture down, so it must run BEFORE
    /// `selfTestPendingSend` — that one owns the panel for five more seconds and
    /// releases the drill hold when it finishes.
    func selfTestReadbackDoor() {
        var sent = false
        var cancelled = false
        currentTarget = ("selftest", 1, "promotions")
        showPendingSend(text: "words a new capture rejected", label: "promotions",
                        seconds: 4, send: { sent = true }, cancel: { _ in cancelled = true })
        let armed = awaitingConfirm
        // The gesture's door. `.pendingSend` admits `.listening` on purpose —
        // re-recording during the window is the whole point — so this is a legal
        // move, and the send must not survive it.
        showListening(level: { 0 })
        SelfTest.report("readbackDoor", [
            ("armed", armed),
            ("newCaptureTookTheStage", state.isCapturingAudio),
            ("countdownReleased", countdownTimer == nil),
            ("sendCancelled", cancelled),
            ("notSent", !sent),
        ])
        endCapture(because: "selftest readbackDoor cleanup")
        // And it must stay dead past the window it was armed for — the same
        // assertion `pendingSend.afterWindow` makes, through the other door.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            SelfTest.report("readbackDoor.afterWindow", [("stillNotSent", !sent)])
        }
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
            guard let self else { return }
            // The last drill, so the panel goes back to its owner here —
            // before the fixture is stood down, so the first ambient repaint
            // lands on a panel that is already idle rather than racing the
            // teardown it was suspended for.
            defer { self.endDrills() }
            guard case .pendingSend = self.state else { return }
            self.endCapture(because: "selftest pendingSend cleanup")
            self.showIdle(rows: [])
        }
    }

    /// Let an in-flight frame animation finish, then lay out. Drills measure
    /// geometry, and geometry is a lie while the animator is running.
    private func settleAnimations() {
        // Waits for the frame to STOP MOVING, not for a fixed interval.
        //
        // A flat 0.3s was enough for a 0.16s animation on an idle machine and
        // not on a loaded one — `collapsedWidthReal` failed on a deploy while
        // another session was building, measuring a frame still in flight. A
        // drill that fails on machine load teaches people to re-run it until it
        // passes, which is worse than not having it.
        // …and it did not, because "stopped moving" and "has not started yet"
        // are the same reading. `stableReads` began at zero, so two samples
        // taken BEFORE the animator's first tick satisfied it: the loop
        // returned after ~0.1s, the 0.16s animation then ran, and the drill
        // measured a frame in flight. The failure it produced is verbatim the
        // one this function's own comment documents as mid-flight —
        // `collapse=10..36 placard=26..87` — which is how it was found.
        //
        // So stability is necessary and not sufficient: nothing may conclude
        // before one whole animation could have started AND finished. The
        // minimum covers the animator's start latency plus the 0.16s frame
        // animation; the stability check then catches anything slower, and the
        // deadline catches a frame that never settles at all.
        let start = Date()
        let minimum: TimeInterval = 0.35
        var last = panel?.frame ?? .zero
        var stableReads = 0
        let deadline = start.addingTimeInterval(2)
        while Date() < deadline,
              stableReads < 2 || Date().timeIntervalSince(start) < minimum {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let now = panel?.frame ?? .zero
            stableReads = now.equalTo(last) ? stableReads + 1 : 0
            last = now
        }
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
    }

    /// Render every state with worst-case text and confirm nothing is clipped.
    /// Run with `--selftest-hud`.
    func selfTest() {
        beginDrills()
        let long = String(repeating: "Product image binding is fixed across the stack. ", count: 8)
        currentTarget = ("selftest", 1, "promotions")
        for (label, block) in [
            ("idle", { self.showIdle(note: long, rows: []) }),
            // The idle grid: mixed lamps, a long name, a worst-case callsign,
            // and rows not yet minted (empty right column).
            ("idleGrid", { self.showIdle(rows: [
                .init(id: "a", name: "Fix hero image binding across the stack",
                      aux: "a8323d60", lamp: .ready),
                .init(id: "b", name: long, aux: "9ca8815c", lamp: .running),
                .init(id: "c", name: "tranquility base", aux: "", lamp: .ready),
                .init(id: "d", name: "robertnowell-83",
                      aux: "6bfb2087",
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
            // The settings state's second pane. What must hold: a
            // transcriptless row still offers its retry (that row IS the
            // pane's reason to exist) but not a copy of nothing; play carries
            // its state on the row (■ while playing); taps reach the host;
            // a retrying row's menu item is spent; and no control sits in
            // the scroller's gutter — the 13 Aug report was a ↻ parked
            // exactly under the scroll bar, unclickable. Worst cases on the
            // record: a 27-minute duration label and a transcript long
            // enough to force truncation.
            ("recentAudio", {
                var retried: String?
                var played: String?
                // The host's wiring, held for restoration. The drill borrows
                // these two handlers to prove taps arrive; assigning nil on
                // the way out — which is what shipped — left EVERY deployed
                // build with a dead ▶ and Retry, because the deploy path runs
                // this drill after the real handlers are installed (19 Aug:
                // Reveal logged all day, play/retry never once).
                let hostRetry = self.onRetryAudioEvent
                let hostPlay = self.onPlayAudioEvent
                self.onRetryAudioEvent = { retried = $0 }
                self.onPlayAudioEvent = { played = $0 }
                self.showRecentAudio(events: [
                    .init(id: "e1", timeLabel: "Aug 13 07:05", durationLabel: "39s",
                          transcript: "I'm not sure I fully understand, but please "
                              + "recommend what the specific course of action should be.",
                          playing: true),
                    .init(id: "e2", timeLabel: "Aug 12 20:52", durationLabel: "27m14s",
                          transcript: nil),
                    .init(id: "e3", timeLabel: "Aug 12 14:26", durationLabel: "2s",
                          transcript: String(repeating: "a transcript that cannot fit ",
                                             count: 12),
                          retrying: true),
                ], note: "Captures over a second.")
                self.panel?.contentView?.layoutSubtreeIfNeeded()
                let rows = self.voiceStack.arrangedSubviews
                    .compactMap { $0 as? AudioEventRowView }
                func row(_ id: String) -> AudioEventRowView? {
                    rows.first { $0.eventId == id }
                }
                row("e2")?.performRetryForSelfTest()
                row("e2")?.tapPlayForSelfTest()
                SelfTest.report("recentAudio", [
                    ("threeRowsRendered", rows.count == 3),
                    ("transcriptlessRowOffersRetryNotCopy",
                     row("e2")?.menuTitlesForSelfTest ==
                        ["Retry transcription", "Show audio in Finder"]),
                    ("transcribedRowOffersCopy",
                     row("e1")?.menuTitlesForSelfTest.first == "Copy transcript"),
                    ("retryReachesTheHost", retried == "e2"),
                    ("playReachesTheHost", played == "e2"),
                    ("playingRowShowsStop", row("e1")?.playButtonTitle == "■"),
                    ("stoppedRowShowsPlay", row("e2")?.playButtonTitle == "▶"),
                    ("retryingRowIsSpent", row("e3")?.retryEnabled == false),
                    ("controlsClearTheScroller",
                     rows.allSatisfy(\.controlsClearTheScroller)),
                    // Guards the restoration below, not the borrow above: on a
                    // deploy the host wired real handlers before this drill, so
                    // nil here means the drill (or a future edit to it) ate them.
                    ("hostHandlersSurviveTheDrill",
                     hostRetry != nil && hostPlay != nil),
                ])
                self.onRetryAudioEvent = hostRetry
                self.onPlayAudioEvent = hostPlay
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
                      aux: "a8323d60", lamp: .ready),
                .init(id: "b", name: "tranquility base", aux: "", lamp: .running),
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
        // The RULE, not the label: under a card the strip is deliberately
        // wordless for arming and listening, so asserting on the label would
        // now assert the opposite of the ruling.
        let armedStrip = !stripRule.isHidden && stripLabel.isHidden

        showListening(level: { 0.3 })
        panel?.contentView?.layoutSubtreeIfNeeded()
        let listeningInk = inkBrightLength
        let listeningStrip = !stripRule.isHidden && stripLabel.isHidden
        let topDuring = panel?.frame.maxY ?? 0

        // Through transcribing, because that is the real order and the
        // legality table enforces it: `.listening` does not admit
        // `.pendingSend`. The first version of this drill skipped the step and
        // the refusal made the read-back assertion fail for the wrong reason.
        showTranscribing("Transcribing your reply…", onCancel: {}, onRetry: {})
        panel?.contentView?.layoutSubtreeIfNeeded()
        let transcribingInk = inkBrightLength
        let transcribingStrip = !stripRule.isHidden
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
                  aux: "a8323d60", lamp: .ready),
        ])
        showArming(target: "promotions copy")
        let gridCaptureIsWholePanel = stripLabel.isHidden && titleLabel.isHidden
        endCapture(because: "selftest strip grid cleanup")

        // §D: Don't send must not reopen the microphone. The button and the
        // chord share `cancelPendingSend`, so the drill drives the BUTTON's
        // door — the one that was passing true — and asserts the capture is
        // actually over rather than merely repainted.
        showTranscribing("Transcribing your reply…", onCancel: {}, onRetry: {})
        showPendingSend(text: "do not send this", label: "promotions copy",
                        seconds: 60, send: {}, cancel: { restart in
                            self.dontSendRestartedListening = restart
                        })
        dontSendRestartedListening = nil
        cancelPendingSendTapped()
        let dontSendKeptMicShut = dontSendRestartedListening == false
        endCapture(because: "selftest dontSend cleanup")

        // §D2: Don't send from a readback that rode a CARD returns to the card,
        // alive. The cancel used to stop the countdown and nothing else, which
        // left `.pendingSend` with no timer — a face whose legality table then
        // refused every repaint, so the readback never left and every gesture
        // dead-ended (12 Aug). The drill drives the button's door and asserts
        // the landing, not just the stop.
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize(stripBody),
            sessionId: "d2", pid: 1, project: "promotions copy", cwd: "/tmp")
        let d2Body = bodyLabel.stringValue
        showListening(level: { 0.1 })
        showTranscribing("Transcribing your reply…", onCancel: {}, onRetry: {})
        showPendingSend(text: "stop this one", label: "promotions copy",
                        seconds: 60, send: {}, cancel: { _ in })
        cancelPendingSendTapped()
        panel?.contentView?.layoutSubtreeIfNeeded()
        let dontSendRestoresCard = state.isSpeaking
            && bodyLabel.stringValue == d2Body
        let dontSendClearsReadback = !stripLabel.stringValue.contains("stop this one")
            && dontSendButton.isHidden && countdownBar.isHidden
        endCapture(because: "selftest dontSend card cleanup")

        // A capture failure keeps the card it was about. The one thing you
        // need in order to say it again is the message you were answering.
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize(stripBody),
            sessionId: "fault", pid: 1, project: "promotions copy", cwd: "/tmp")
        highlight(upTo: 30)
        let faultCardInk = inkBrightLength
        showListening(level: { 0.2 })
        showResult("This recording lost its address. Audio kept; nothing sent.")
        let faultKeepsCard = bodyLabel.stringValue == cardBody
            && inkBrightLength == faultCardInk
        let faultIsInTheStrip = stripLabel.stringValue.contains("lost its address")
        endCapture(because: "selftest fault cleanup")

        // The chrome drill: every mark in the vocabulary sits on the cap line
        // of the word beside it, at the same optical weight, whichever face it
        // is actually drawn from.
        //
        // Asserted as a MEASUREMENT rather than a look, because this is the
        // class of defect that survives every review — 0.4pt is invisible in a
        // diff, unmistakable on a screen, and the numbers are the only way to
        // hold it. The errors are logged in full so a regression names the
        // glyph that moved.
        let placardErrors = ChromeType.centringError(
            font: StateLegend.placardFont, markScale: 0.68)
        let rowErrors = ChromeType.centringError(
            font: ChromeType.mono(
                ofSize: StateLegend.BottomLine.size, weight: .medium))
        let worstMark = (placardErrors + rowErrors).map { abs($0.1) }.max() ?? 0
        // One optical size for every mark on a face, whatever family it comes
        // from: `◀` is monospaced and `⚠` is not, and before this they were
        // 10px and 5px tall on the same 15px cap band.
        let markHeights = ChromeType.vocabulary.compactMap { ch -> CGFloat? in
            let f = ChromeType.markFont(for: ch, textFont: StateLegend.placardFont,
                                        fraction: 0.68)
            return ChromeType.inkMetrics(ch, in: f)?.height
        }
        let capBand = ChromeType.inkMetrics("H", in: StateLegend.placardFont)?.height ?? 0
        let markSpread = (markHeights.max() ?? 0) - (markHeights.min() ?? 0)
        // Nothing clipped under whichever face is installed. A swapped family
        // changes advance widths, and the panel's text column is fixed — so the
        // failure mode of a font it has never seen is a label quietly cut off,
        // which no arithmetic about baselines would catch.
        let chromeColumn = Self.gridWidth
        let placardWidth = ChromeType
            .line(StateLegend.legend("Needs you"), font: StateLegend.placardFont,
                  color: .white, markScale: 0.68).size().width
        let doorWidth = StateLegend.BottomLine
            .door("\(StateLegend.goToAgentTitle) \(StateLegend.Glyph.forward)").size().width
        let quietWidth = StateLegend.BottomLine.quiet(StateLegend.controlsTitle).size().width
        let markWidth = StateLegend.BottomLine.quiet(StateLegend.wordmark).size().width
        let bottomRowFits = doorWidth * 2 + quietWidth + 24 <= chromeColumn
        let footerFits = quietWidth + markWidth + 24 <= chromeColumn

        // Every door answers the cursor, and nothing else does. A pointing hand
        // over a word that does not react is a promise the pixels are not
        // keeping — which is exactly what the pill was doing.
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("Hover check."),
            sessionId: "hv", pid: 1, project: "projects", cwd: "/tmp")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let pillResting = stateLabel.attributedStringValue
        stateLabel.setHovered(true)
        let pillHovered = stateLabel.attributedStringValue
        stateLabel.setHovered(false)
        let pillRestored = stateLabel.attributedStringValue
        func firstColour(_ text: NSAttributedString) -> NSColor? {
            guard text.length > 0 else { return nil }
            return text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        let pillAnswersTheCursor = stateLabel.isADoor
            && firstColour(pillHovered) != firstColour(pillResting)
            && firstColour(pillRestored) == firstColour(pillResting)
        // The TITLE, which is the one the ramp could not answer: it rests at
        // `ink`, the ramp's top rung, so `hovered` handed it back unchanged and
        // the card's identity took a pointing hand while staying exactly the
        // colour it was ("it does show the cursor pointer, but it doesn't have
        // the change text colour impact", 18 Aug). Asserted separately from the
        // pill because they fail separately: the pill rests mid-ramp and passed
        // this whole time.
        let titleResting = titleLabel.attributedStringValue
        titleLabel.setHovered(true)
        let titleHovered = titleLabel.attributedStringValue
        titleLabel.setHovered(false)
        let titleAnswersTheCursor = titleLabel.isADoor
            && firstColour(titleHovered) != firstColour(titleResting)
            && firstColour(titleLabel.attributedStringValue) == firstColour(titleResting)
        // Through the button's own hover seam, not a cast to a class it is not.
        // The first version of this claim cast `goButton` to a type that had
        // never been in the tree — the panel already had `ConsoleButton` with an
        // ink ramp, written in parallel — so the cast produced nil, the hover
        // never ran, and the drill failed on its first deploy. It was right to.
        let goResting = goButton.attributedTitle
        goButton.setHovered(true)
        let goHovered = goButton.attributedTitle
        goButton.setHovered(false)
        let doorAnswersTheCursor = firstColour(goHovered) != firstColour(goResting)
            && firstColour(goButton.attributedTitle) == firstColour(goResting)
        // And the grid strip does NOT: it names a face, it is not a control.
        showIdle(note: nil, rows: [.init(id: "h1", name: "row", aux: "", lamp: .running)])
        panel?.contentView?.layoutSubtreeIfNeeded()
        let stripIsNotADoor = !stateLabel.isADoor

        // A row lights in both registers. Asserted on the NAME as well as the
        // wash, because the wash was there all along and the question the audit
        // asked was whether it is enough on its own.
        showIdle(note: nil, rows: [.init(id: "hr", name: "hover row", aux: "a1", lamp: .ready)])
        panel?.contentView?.layoutSubtreeIfNeeded()
        let row = waitingRows.arrangedSubviews.compactMap { $0 as? GridRowView }.first
        let rowResting = row?.nameLabel.textColor
        row?.setHovered(true)
        let rowHovered = row?.nameLabel.textColor
        row?.setHovered(false)
        let rowLightsItsName = rowResting != nil && rowHovered != rowResting
            && row?.nameLabel.textColor == rowResting

        // The face census. One rule — the machine speaks in mono, the message
        // speaks in prose — asserted over the widgets rather than trusted to
        // every call site, because the way this went wrong was not a decision:
        // it was eight files each picking a font that looked fine on its own.
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("Face census."),
            sessionId: "fc", pid: 1, project: "promotions copy", cwd: "/tmp")
        panel?.contentView?.layoutSubtreeIfNeeded()
        func isMono(_ font: NSFont?) -> Bool {
            guard let font else { return false }
            return font.isFixedPitch
                || font.familyName == ChromeType.preferredFamily
        }
        // The face is in the STRING for anything drawn from an attributed
        // title, and `.font` on those is whatever AppKit defaulted to — which
        // is how this claim failed its first deploy naming a stray that was
        // never on screen. Read what draws, not what is adjacent to it.
        func drawnFont(_ view: NSView) -> NSFont? {
            if let button = view as? NSButton, button.attributedTitle.length > 0 {
                return button.attributedTitle
                    .attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            }
            guard let field = view as? NSTextField else { return nil }
            if field.attributedStringValue.length > 0,
               let font = field.attributedStringValue
                .attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                return font
            }
            return field.font
        }
        let chromeWidgets: [(String, NSFont?)] = [
            ("state", drawnFont(stateLabel)), ("title", drawnFont(titleLabel)),
            ("hint", drawnFont(hintLabel)), ("strip", drawnFont(stripLabel)),
            ("door", drawnFont(goButton)), ("quiet", drawnFont(dontSendButton)),
        ]
        let strays = chromeWidgets.filter { !isMono($0.1) }.map(\.0)
        // And the one exception, said out loud: an agent's words are prose.
        let bodyIsProse = !isMono(drawnFont(bodyLabel))

        // The mark census: walk the ACTUAL view tree and find any mark drawn
        // without going through the composer. The chip's ▣ was a plain
        // `labelWithString: "▣"` in its own view, frame-centred and visibly
        // low, and the first audit missed it because it looked for glyphs in
        // the files it had already touched. A tree walk cannot be fooled that
        // way: whatever is on screen is what it reads.
        //
        // A mark is composed when its run carries a baseline offset. Zero is a
        // legitimate answer for a glyph that needs none, so the test is that
        // the ATTRIBUTE exists — which only `ChromeType.line` puts there.
        //
        // A mark ALONE in its own control is exempt: ▶, ⋯, ■ and the filter's
        // ⌕ are centred in their frames, which is the right answer when there
        // is no cap line to sit on. The rule is about a mark that shares a line
        // with words, which is the only case where "level with the text" means
        // anything.
        func needsComposing(_ text: String) -> Bool {
            text.contains(where: ChromeType.isMark) && text.contains(where: \.isLetter)
        }
        func uncomposedMarks(_ view: NSView) -> [String] {
            var found: [String] = []
            if let field = view as? NSTextField, needsComposing(field.stringValue) {
                let text = field.attributedStringValue
                let plain = field.stringValue
                for (i, ch) in plain.enumerated() where ChromeType.isMark(ch) {
                    let index = min(i, max(0, text.length - 1))
                    let composed = text.length > 0
                        && text.attribute(.baselineOffset, at: index,
                                          effectiveRange: nil) != nil
                    if !composed { found.append("\(ch)@\(type(of: view))") }
                }
            }
            if let button = view as? NSButton, button.attributedTitle.length > 0,
               needsComposing(button.attributedTitle.string) {
                let text = button.attributedTitle
                for (i, ch) in text.string.enumerated() where ChromeType.isMark(ch) {
                    let index = min(i, max(0, text.length - 1))
                    if text.attribute(.baselineOffset, at: index, effectiveRange: nil) == nil {
                        found.append("\(ch)@\(type(of: view))")
                    }
                }
            }
            return found + view.subviews.flatMap(uncomposedMarks)
        }
        var loose: [String] = []
        for probe in ["grid", "speaking", "needsyou", "settings", "recent-audio"] {
            _ = pose(probe)
            panel?.contentView?.layoutSubtreeIfNeeded()
            if let root = panel?.contentView { loose += uncomposedMarks(root) }
        }
        let everyMarkComposed = loose.isEmpty

        // The header's MARKS sit on the content column, not its boxes.
        //
        // Asserted through `inkOverhang` rather than by reading pixels, so the
        // drill states the intent: box origin plus the box's own padding is
        // where the glyph starts, and that is what must equal the column the
        // rules and rows paint to. Reported 20 Aug — "the rows of agents'
        // widths expand beyond the top bar a little bit" — and it was 7pt on
        // the left, 3.5 on the right.
        showIdle(note: nil, rows: [
            .init(id: "hc", name: "Validate hero image binding", aux: "a8323d60", lamp: .ready),
        ])
        panel?.contentView?.layoutSubtreeIfNeeded()
        let chevronInk = collapseButton.frame.minX + collapseButton.inkOverhang.leading
        let gearInk = (panel?.contentView?.bounds.maxX ?? 0)
            - (gearButton.frame.maxX - gearButton.inkOverhang.trailing)
        let headerSitsOnTheColumn = abs(chevronInk - StatusHUD.contentColumn) <= 0.5
            && abs(gearInk - StatusHUD.contentColumn) <= 0.5
        Permissions.log(String(format: "chrome: column %.1f · chevron ink %.1f · gear ink %.1f",
                               StatusHUD.contentColumn, chevronInk, gearInk))

        SelfTest.report("chrome", [
            ("headerSitsOnTheColumn", headerSitsOnTheColumn),
            ("marksSitOnTheLine", worstMark <= 0.25),
            ("marksShareOneOpticalSize", markSpread <= 0.5),
            ("marksAreSmallerThanTheCaps", (markHeights.max() ?? 0) < capBand),
            ("placardFitsTheColumn", placardWidth <= chromeColumn),
            ("bottomRowFits", bottomRowFits),
            ("footerFits", footerFits),
            ("pillAnswersTheCursor", pillAnswersTheCursor),
            ("titleAnswersTheCursor", titleAnswersTheCursor),
            ("doorAnswersTheCursor", doorAnswersTheCursor),
            ("stripIsNotADoor", stripIsNotADoor),
            ("rowLightsItsName", rowLightsItsName),
            ("chromeIsMono", strays.isEmpty),
            ("theMessageIsProse", bodyIsProse),
            ("everyMarkComposed", everyMarkComposed),
        ])
        Permissions.log("selftest chrome: loose marks "
            + "\(loose.isEmpty ? "none" : Set(loose).sorted().joined(separator: " ")) · strays "
            + "\(strays.isEmpty ? "none" : strays.joined(separator: ",")) · face "
            + "\(ChromeType.preferredFamily ?? "system mono") · "
            + "worst \(String(format: "%.2f", worstMark))pt "
            + "spread \(String(format: "%.2f", markSpread))pt cap \(String(format: "%.2f", capBand))pt "
            + "· widths placard \(Int(placardWidth)) door \(Int(doorWidth)) "
            + "quiet \(Int(quietWidth)) mark \(Int(markWidth)) of \(Int(chromeColumn)) · "
            + (placardErrors + rowErrors)
                .map { "\($0.0)\(String(format: "%+.2f", $0.1))" }.joined(separator: " "))

        // The greeting drill. The card exists before the session does, which is
        // the whole ruling and also the whole risk: an unbound card must not
        // pretend to have an agent, and a binding that arrives after you have
        // moved on must not repoint the reply routing at a session you are no
        // longer looking at.
        let greetingLine = LaunchGreeting.lines[0]
        let greetingPainted = showGreeting(line: greetingLine, label: "projects")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let greetingSaysOnlyTheQuestion = bodyLabel.stringValue == greetingLine
        let greetingHasNoAgentYet = currentTarget == nil && goButton.isHidden
        let greetingNamesItsDirectory = titleLabel.stringValue == "projects"
        // The door that opened somebody else's tab (18 Aug, 22:37). Starting a
        // capture on the greeting card adopts whatever the reply routing last
        // resolved — the PREVIOUS agent, because this one has not registered —
        // and the unbound card grew a GO TO AGENT pointing at it. The adoption
        // is refused now, so the card stays honestly empty until it is bound.
        adoptTarget(sessionId: "someone-else", pid: 99, label: "elsewhere", cwd: "/tmp")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let unboundCardRefusesAForeignAgent = currentTarget == nil && goButton.isHidden
        let bound = bindGreeting(sessionId: "g1", pid: 42, label: "projects", cwd: "/tmp")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let bindingGivesItTheAgent = bound && currentTarget?.sessionId == "g1"
            && !goButton.isHidden
        // Moved on: the grid is up, and a late registration must be ignored.
        showIdle(note: nil, rows: [.init(id: "z1", name: "something else",
                                         aux: "", lamp: .running)])
        let lateBindingRefused = !bindGreeting(sessionId: "g2", pid: 7,
                                               label: "elsewhere", cwd: "/tmp")
        // The failure card names the agent it is about, and therefore carries its
        // door. `send()` returns the panel to the grid before the outcome arrives,
        // so this paints from idle — where it used to paint with no target at all,
        // giving an empty title and no GO TO AGENT under the words "check the tab
        // before repeating yourself" (18 Aug).
        showIdle(note: nil, rows: [])
        adoptTarget(sessionId: "f1", pid: 314, label: "promotions", cwd: "/tmp")
        showIdle(note: nil, rows: [])
        showResult("Typed it into promotions, but couldn't confirm it landed.")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let failureKeepsItsAgent = currentTarget?.sessionId == "f1"
            && titleLabel.stringValue == "promotions" && !goButton.isHidden
        // The 19 Aug incident, drilled. A microphone fault arrived while a
        // greeting card was waiting for its session — and because `.speaking`
        // does not own the stage, the fault took the whole card, cleared
        // `awaitingGreetingBinding`, and the session that registered three
        // seconds later was refused. The reply routing lived inside that
        // refusal, so every word after it went to the previous agent, in
        // another repository. The card must survive its microphone.
        showGreeting(line: greetingLine, label: "projects")
        showResult("Couldn't open the microphone, audio stack unresponsive.")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let micFaultKeepsTheCard = bodyLabel.stringValue == greetingLine
            && titleLabel.stringValue == "projects" && currentTarget == nil
        let micFaultSpeaksFromTheStrip = face.captureFault != nil
        let boundAfterAMicFault = bindGreeting(sessionId: "g3", pid: 8,
                                               label: "projects", cwd: "/tmp")
            && currentTarget?.sessionId == "g3"
        // And the refusal it must NOT weaken: once the panel has genuinely
        // moved on, a late binding is still wrong. Same assertion as
        // `lateBindingRefused`, re-asked after the fault path to prove the
        // exemption above is scoped to a card that is still on stage.
        showIdle(note: nil, rows: [])
        let lateBindingStillRefusedAfterAFault = !bindGreeting(
            sessionId: "g4", pid: 9, label: "elsewhere", cwd: "/tmp")
        SelfTest.report("greeting", [
            ("cardPaintsAtOnce", greetingPainted),
            ("saysOnlyTheQuestion", greetingSaysOnlyTheQuestion),
            ("namesItsDirectory", greetingNamesItsDirectory),
            ("noAgentUntilBound", greetingHasNoAgentYet),
            ("unboundCardRefusesAForeignAgent", unboundCardRefusesAForeignAgent),
            ("bindingGivesItTheAgent", bindingGivesItTheAgent),
            ("lateBindingRefused", lateBindingRefused),
            ("failureKeepsItsAgent", failureKeepsItsAgent),
            ("micFaultKeepsTheCard", micFaultKeepsTheCard),
            ("micFaultSpeaksFromTheStrip", micFaultSpeaksFromTheStrip),
            ("boundAfterAMicFault", boundAfterAMicFault),
            ("lateBindingStillRefusedAfterAFault", lateBindingStillRefusedAfterAFault),
        ])

        // The Controls drill. The collapse only pays if opening the note costs
        // nothing, so the claims are asserted rather than asserted about: the
        // footer belongs to the grid, the note opens, the PANEL DOES NOT MOVE
        // when it does, it fits inside the panel it overlays, and leaving the
        // grid closes it. That last one is the residue class — a note still
        // open over the face that replaced its owner.
        showIdle(note: nil, rows: [
            .init(id: "c1", name: "Fix hero image binding",
                  aux: "a8323d60", lamp: .ready),
            .init(id: "c2", name: "tranquility base", aux: "", lamp: .running),
        ])
        panel?.contentView?.layoutSubtreeIfNeeded()
        let footerOnGrid = !gridFooter.isHidden
        // The bottom line sits ON the floor. The grid has no hint to give, and
        // an empty `hintLabel` is still a laid-out line — it and the stack's
        // spacing put ~19pt of nothing under the footer, which read as the
        // wordmark and Controls floating rather than resting on the panel's
        // own 12pt inset.
        //
        // Asserted STRUCTURALLY: nothing visible may follow the footer in the
        // stack, which is what makes the stack's own 12pt bottom inset the
        // whole gap. The first version of this drill measured the footer
        // against the content view's edges and failed its first deploy at
        // 23pt with the fix working perfectly — `resizeToFit` animates the
        // frame over 0.12s, so anything read from the panel's live bounds
        // immediately after a face change is a transient. The strip drill's
        // own note says exactly this about the top edge; the geometry is
        // logged below for eyes and never asserted. This form is also the
        // better claim: the regression class is a widget left standing under
        // the footer, and that is what it names.
        let hintIsNotALine = hintLabel.isHidden
        let underTheFooter = (contentStack?.arrangedSubviews ?? [])
            .drop(while: { $0 !== gridFooter }).dropFirst()
        let footerIsTheLastRow = underTheFooter.allSatisfy(\.isHidden)
        let contentBox = panel?.contentView?.bounds ?? .zero
        let footerBox = panel?.contentView
            .map { gridFooter.convert(gridFooter.bounds, to: $0) } ?? .zero
        let floorGap = min(footerBox.minY - contentBox.minY,
                           contentBox.maxY - footerBox.maxY)
        // Centred, not left-aligned: the word must sit in the same place on
        // every face that has it, and on a card both edges are already spent.
        let gridWordIsCentred = abs(
            gridFooter.controls.frame.midX - gridFooter.frame.width / 2) < 1
        // The signature is a door (18 Aug). Three things, because they fail
        // separately: it says so, it answers the pointer, and the tap reaches
        // the host — a door wired to nothing is the same secret as a door with
        // no cursor, one layer further in.
        let signatureIsADoor = gridFooter.mark.isADoor
        let signatureResting = gridFooter.mark.attributedStringValue
        gridFooter.mark.setHovered(true)
        let signatureHovered = gridFooter.mark.attributedStringValue
        gridFooter.mark.setHovered(false)
        func firstInk(_ text: NSAttributedString) -> NSColor? {
            text.length == 0 ? nil
                : text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        let signatureAnswersTheCursor =
            firstInk(signatureHovered) != firstInk(signatureResting)
            && firstInk(gridFooter.mark.attributedStringValue) == firstInk(signatureResting)
        var signatureTapped = false
        let priorRepository = onOpenRepository
        onOpenRepository = { signatureTapped = true }
        gridFooter.onWordmark?()
        onOpenRepository = priorRepository
        let heightShut = panel?.frame.height ?? 0
        setControlsNote(open: true, above: gridFooter)
        panel?.contentView?.layoutSubtreeIfNeeded()
        let heightOpen = panel?.frame.height ?? 0
        let noteOpens = !controlsSticky.isHidden
        let noteWidth = controlsSticky.frame.width
        let column = (panel?.frame.width ?? 0) - 28
        showResult("A failure card, arriving under an open Controls note.")
        let closedOnLeave = controlsSticky.isHidden && gridFooter.isHidden

        // The other half of the ruling: the word does not belong to the grid.
        // A card on stage carries it in the middle of its action row, and the
        // note opens over that row rather than over a footer that is not there.
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("What would you like to work on?"),
            sessionId: "cw", pid: 1, project: "projects", cwd: "/tmp")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let cardKeepsTheWord = !cardControls.isHidden && !actionRow.isHidden
        // One lexicon on the bottom line: same face, same size, same case for
        // the doors and the quiet words alike. Asserted on the FONT rather than
        // by eye, because "these look different" is exactly what nobody notices
        // until the row has three treatments in four words.
        func rowFace(_ text: NSAttributedString) -> NSFont? {
            text.length == 0 ? nil
                : text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        }
        let doorFace = rowFace(goButton.attributedTitle)
        let wordFace = rowFace(cardControls.wordValue)
        // FAMILY, not name: the lexicon's whole design is that weight carries
        // the difference between a door and a hint, and the chrome face
        // returns a different fontName per weight — so comparing names asserted
        // that the two roles look identical, which is the opposite of the rule.
        // Failed its first deploy saying exactly that.
        let oneLexicon = doorFace?.familyName == wordFace?.familyName
            && doorFace?.pointSize == wordFace?.pointSize
            && doorFace?.pointSize == StateLegend.BottomLine.size
            // Title case, not capitals: the placard beside it says "Speaking".
            && goButton.attributedTitle.string != goButton.attributedTitle.string.uppercased()
        // Air under the last line of the card. Measured to the WORD rather than
        // to the row: the row's frame includes the 6pt top inset that provides
        // the air, so a frame-to-frame gap would report the stack's 6 and miss
        // the point. Sibling geometry inside one settled layout pass, never the
        // panel's own animating bounds — that mistake is recorded two drills up.
        let stackBox = contentStack
        let wordBox = stackBox.map { cardControls.convert(cardControls.bounds, to: $0) }
            ?? .zero
        let bodyBox = stackBox.map { bodyLabel.convert(bodyLabel.bounds, to: $0) } ?? .zero
        // Logged for eyes, asserted by nobody.
        //
        // This was a gate (`bottomLineHasAir >= 11.5`) and it was the wrong
        // shape of check twice over. It measured a rendered gap to defend a
        // quantity that is DECLARED — 6pt of stack spacing plus the row's own
        // 6pt top inset — and while the layout underneath it was
        // non-deterministic it spent a day failing the launches where the panel
        // was RIGHT: the 12.0 it wanted came from a word centred in an
        // over-tall row, and the 8.5 it rejected was the compact row the design
        // describes (issue 26, measured).
        //
        // The layout is deterministic now, by construction, in
        // `ControlsWordView` — which is where a guarantee about spacing
        // belongs. Ruled 19 Aug: "this is a minor check on what should be a
        // deterministic guarantee... I don't even know why we need a measured
        // gate for this." The same conclusion the drill two above reached about
        // the footer's floor gap, for the same reason, and it is logged there
        // exactly like this.
        let bottomLineAir = max(bodyBox.minY - wordBox.maxY, wordBox.minY - bodyBox.maxY)
        setControlsNote(open: true, above: actionRow)
        panel?.contentView?.layoutSubtreeIfNeeded()
        let cardNoteOpens = !controlsSticky.isHidden
        // Hung over the card's own bottom line and inside the panel's column —
        // the note is wider than the word, so a placement that followed the
        // word's leading edge would hang off the right of the panel.
        let cardNoteBox = panel?.contentView
            .map { controlsSticky.convert(controlsSticky.bounds, to: $0) } ?? .zero
        let cardNoteFitsThePanel = cardNoteBox.width > 0
            && cardNoteBox.width <= (panel?.frame.width ?? 0) - 28
        setControlsNote(open: false)
        // Mid-capture the panel is in a transaction, and a note about how to
        // start one is furniture.
        showListening(level: { 0.1 })
        panel?.contentView?.layoutSubtreeIfNeeded()
        let captureDropsTheWord = cardControls.isHidden
        endCapture(because: "selftest controls cleanup")
        // Every face that offers a gesture keeps the word. Asserted over the
        // list rather than at one face, because the regression is a NEW face
        // that quietly does not inherit the rule.
        var wordSurvivesEveryFace = true
        for probe in [PanelState.speaking(eventId: nil), .preparing,
                      .receipt, .result] {
            forceTransition(to: probe, because: "selftest controls sweep")
            render()
            if cardControls.isHidden { wordSurvivesEveryFace = false }
        }
        endCapture(because: "selftest controls sweep cleanup")
        SelfTest.report("controls", [
            ("footerOnGrid", footerOnGrid),
            ("noteOpens", noteOpens),
            ("noReflow", heightOpen == heightShut),
            ("noteFitsColumn", noteWidth > 0 && noteWidth <= column),
            ("closedOnLeave", closedOnLeave),
            ("hintIsNotALine", hintIsNotALine),
            ("footerIsTheLastRow", footerIsTheLastRow),
            ("gridWordIsCentred", gridWordIsCentred),
            ("signatureIsADoor", signatureIsADoor),
            ("signatureAnswersTheCursor", signatureAnswersTheCursor),
            ("signatureReachesTheHost", signatureTapped),
            ("cardKeepsTheWord", cardKeepsTheWord),
            ("oneLexicon", oneLexicon),
            ("cardNoteOpens", cardNoteOpens),
            ("cardNoteFitsThePanel", cardNoteFitsThePanel),
            ("captureDropsTheWord", captureDropsTheWord),
            ("wordSurvivesEveryFace", wordSurvivesEveryFace),
        ])
        Permissions.log("selftest controls: panelH \(heightShut)->\(heightOpen) "
                        + "noteW=\(noteWidth) column=\(column) "
                        + "lines=\(StateLegend.controlsNote.count) "
                        + "floorGap=\(floorGap) bottomLineAir=\(bottomLineAir)")

        SelfTest.report("strip", [
            ("dontSendKeepsTheMicShut", dontSendKeptMicShut),
            ("dontSendRestoresTheCard", dontSendRestoresCard),
            ("dontSendClearsTheReadback", dontSendClearsReadback),
            ("faultKeepsTheCard", faultKeepsCard),
            ("faultSpeaksFromTheStrip", faultIsInTheStrip),
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
        showIdle(rows: [.init(id: "a", name: "promotions copy", aux: "", lamp: .ready),
                        .init(id: "b", name: "syndit", aux: "", lamp: .ready)])
        let survived = state.isCapturingAudio && !meter.isHidden
        SelfTest.report("legality", [("idleOverListeningRefused", survived)])
        recordingEnded()
        // Through the user door, exactly as a real abort must go — showIdle alone
        // is (correctly) refused from a capture state.
        endCapture(because: "selftest cleanup")
        showIdle(rows: [])

        // The collapsed strip. Three properties, and the third is the ruling.
        let mixed: [StateLegend.SessionRow] = [
            .init(id: "a", name: "promotions copy", aux: "a8323d60", lamp: .ready),
            .init(id: "b", name: "syndit", aux: "9ca8815c", lamp: .running),
            .init(id: "c", name: "tranquility base", aux: "6bfb2087", lamp: .working),
            .init(id: "d", name: "kopi", aux: "0f2ea0d4", lamp: .running),
            .init(id: "e", name: "bookmarks", aux: "bookmarks", lamp: .fault),
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
        showIdle(rows: mixed + [.init(id: "f", name: "new one", aux: "new", lamp: .ready)])
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

        // The invitation must not fatten the strip.
        //
        // A HIDDEN view still holds its constraints. The drop overlay is pinned
        // to all four edges of the background, and its label is pinned to both
        // of the overlay's — so the label refusing to be narrower than its own
        // text puts a required floor under the window's width, and a window
        // whose content view has one does not go below it whatever frame it is
        // handed. Seen within the hour of shipping the invitation on 16 Aug: the
        // first drag left a sentence in the label, and every collapse after it
        // landed ~197pt wide with the lamps floating in the middle of a column
        // that is supposed to be 40.
        //
        // Collapsed AFTER a drag has populated the invitation, because that is
        // the only state that reproduces it — the label is empty until the first
        // drag, and every drill above this one collapsed against an empty label
        // and passed all morning while the panel on screen was chubby.
        dropOverlay.show(target: "promotions copy")
        setCollapsed(false)
        showIdle(rows: mixed)
        settleAnimations()
        setCollapsed(true)
        showIdle(rows: mixed)
        settleAnimations()
        let thinAfterInvitation =
            abs((panel?.frame.width ?? 0) - CollapsedStrip.width) < 1
        Permissions.log("collapse drill: after invitation "
            + (panel.map { NSStringFromRect($0.frame) } ?? "-"))
        dropOverlay.isHidden = true

        // The column carries the READ state, and it carries the whole roster.
        //
        // Both halves of what Robert saw on 16 Aug, side by side: a grid with
        // one solid green and eight hollow ones, and a strip showing nine
        // identical solid greens, eight of them — the two blues cut by a cap of
        // 8 in a column with room for more. So the strip was overstating who
        // wants him AND hiding who is working, at the same time.
        //
        // The ink is SAMPLED off the rendered column rather than recomputed.
        // The defect was a view that never asked whether a lamp had been
        // opened, so any drill that asks the question itself passes on the
        // broken build — the expression was correct everywhere it existed.
        let readMix: [StateLegend.SessionRow] = [
            .init(id: "u", name: "unread", aux: "u", lamp: .ready, read: .unread),
            .init(id: "o", name: "opened", aux: "o", lamp: .ready, read: .opened),
            .init(id: "w", name: "working", aux: "w", lamp: .working, read: .none),
        ] + (0..<11).map {
            .init(id: "x\($0)", name: "more", aux: "x", lamp: .working, read: .none)
        }
        setCollapsed(true)
        showIdle(rows: readMix)
        settleAnimations()
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
        let unreadInk = collapsedLampCentreInk(0)?.usingColorSpace(.sRGB)
        let openedInk = collapsedLampCentreInk(1)?.usingColorSpace(.sRGB)
        // Solid means painted AND painted the state's own colour: an alpha
        // test alone would pass on a lamp drawn in the wrong hue.
        let unreadIsSolidGreen = unreadInk.map {
            $0.alphaComponent > 0.9
                && $0.greenComponent > $0.redComponent
                && $0.greenComponent > $0.blueComponent
        } ?? false
        // Hollow means nothing in the middle. The ring itself is 1.5pt at the
        // rim, so the centre pixel is untouched ground.
        let openedIsHollow = (openedInk?.alphaComponent ?? 1) < 0.1
        // Fourteen rows in, the column shows its full cap and they still clear
        // the band the mark and the controls share.
        let wholeColumnShown = collapsedLampCount == CollapsedStrip.lampCapacity
        let lampsClearMark = collapsedLampsClearTheMark
        Permissions.log("collapse drill: lamps=\(collapsedLampCount)"
            + " unread=\(unreadInk.map { "\($0.alphaComponent)" } ?? "-")"
            + " opened=\(openedInk.map { "\($0.alphaComponent)" } ?? "-")"
            + " frame \(panel.map { NSStringFromRect($0.frame) } ?? "-")")

        // The mark keeps its band at every roster size, AND stays readable.
        //
        // Two rulings, a day apart, and the second is why the type size is
        // asserted at all. 17 Aug moved the mark into the controls' 80pt floor
        // so it would always be there; it was, at 5pt — "too small not
        // readable". Ink alone could not catch that: 449 pixels of 5pt type is
        // a perfectly inked mark that nobody can read. So the drill now
        // measures the POINT SIZE the draw actually chose against the floor
        // below which the mark stops being quiet and starts being absent.
        let markAtRest = collapsedFloorFace
        let inkAtRest = collapsedFloorInk
        // The top of the column wears the site mark now, not a bare ring
        // (ruled 18 Aug). Counted as ink rather than asserted as geometry: the
        // header is one `draw` call away from painting nothing at all, and a
        // rect that exists is not a mark that shows.
        let headerInkAtRest = collapsedHeaderInk
        collapsedSetHovering(true)
        let faceOnHover = collapsedFloorFace
        // On hover the slot becomes Expand, so the mark's own ink must drop —
        // the chevron is a fraction of the mark's mass. This is the property
        // that catches a header drawing BOTH at once.
        let headerInkOnHover = collapsedHeaderInk
        collapsedSetHovering(false)
        let markReturns = collapsedFloorFace
        let markIsAlwaysThere = markAtRest == .mark && markReturns == .mark
        let markHasInk = inkAtRest > 40
        let hoverTakesTheFloor = faceOnHover == .controls
        let controlsInsideTheMark = collapsedControlsSitInsideTheMark
        let markIsLegible = collapsedMarkTypeIsLegible
        let headerWearsTheMark = headerInkAtRest > 60
        let headerYieldsToExpand = headerInkOnHover < headerInkAtRest / 2
        // A picture of the column, every deploy — the panel's only visual
        // evidence, and the answer to "did anybody look at it".
        let shot = strip?.writeShot()
        Permissions.log("collapse drill: floor \(markAtRest.map { "\($0)" } ?? "-")"
            + " ink=\(inkAtRest) type=\(collapsedMarkTypeSize)pt"
            + " hover=\(faceOnHover.map { "\($0)" } ?? "-")"
            + " header=\(headerInkAtRest)/\(headerInkOnHover)"
            + " lamps=\(collapsedLampCount)"
            + " shot=\(shot?.path ?? "-")")

        // The mark, at the two sizes nobody looks at until they ship.
        //
        // Ruled 18 Aug: the identity is a lamp resting on a hairline, drawn
        // from the panel's own vocabulary. Three properties, and the second is
        // the one that has already caught a real defect — the 16px app icon
        // was geometrically perfect and visually a grey blob, because the ring
        // wall fell under a device pixel. Ink is counted on the rendered
        // bitmap; nothing else sees that.
        let markHollowInk = SiteMark.inkForTesting(size: 16, filled: false)
        let markFilledInk = SiteMark.inkForTesting(size: 16, filled: true)
        let markIsTemplate = SiteMark.templateImage().isTemplate
        // Solid says something wants you, hollow says nothing new — the same
        // rule the grid draws. If the two ever render the same, the menu bar
        // has quietly stopped saying anything.
        let markStatesDiffer = markFilledInk > markHollowInk + 12
        let markReadsAt16 = markHollowInk > 30
        // The app icon must show the MARK at the bottom of the ladder, not a
        // dark tile with a rumour on it.
        let iconInk16 = SiteMark.iconMarkInkForTesting(pixels: 16)
        let iconReadsAt16 = iconInk16 > 12
        Permissions.log("mark drill: hollow=\(markHollowInk) filled=\(markFilledInk)"
            + " template=\(markIsTemplate) icon16=\(iconInk16)")
        SelfTest.report("mark", [
            ("templateForTheMenuBar", markIsTemplate),
            ("readsAtSixteenPoints", markReadsAt16),
            ("solidAndHollowDiffer", markStatesDiffer),
            ("appIconShowsTheMarkAtSixteen", iconReadsAt16),
        ])

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
            ("thinAfterTheInvitation", thinAfterInvitation),
            ("unreadLampIsSolid", unreadIsSolidGreen),
            ("openedLampIsHollowCollapsedToo", openedIsHollow),
            ("wholeColumnShown", wholeColumnShown),
            ("lampsClearTheMark", lampsClearMark),
            ("markShowsOnAFullColumn", markIsAlwaysThere),
            ("markIsActuallyInked", markHasInk),
            ("hoverTakesTheFloor", hoverTakesTheFloor),
            ("controlsSitInsideTheMark", controlsInsideTheMark),
            ("markTypeClearsTheLegibilityFloor", markIsLegible),
            ("headerWearsTheSiteMark", headerWearsTheMark),
            ("headerYieldsToExpandOnHover", headerYieldsToExpand),
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
        // Last, deliberately: it repaints the grid and shows a receipt, and an
        // animated resize left in flight by an earlier drill is read by the
        // next one as a wrong frame. It measures geometry, so it goes where
        // nothing follows it.
        topBandDrill()

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

        // Whose failure is it (19 Aug)? A dispatch's read-back verification runs
        // for up to twelve seconds, and the announce queue does not wait for it.
        // At 16:38 the words went to `recall`, the panel advanced to the next
        // card, and the failure painted that card's title over this failure's
        // message — one session's name above the other session's sentence.
        // Robert could not place the alert, which is the right reaction to a
        // card that is half about each of two agents.
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("a card already on the stage"),
            sessionId: "on-stage", pid: 1, project: "promotions", cwd: "/tmp/promotions")
        showResult("Typed it into recall, but couldn't confirm it landed.",
                   about: (sessionId: "somebody-else", label: "recall"))
        let namesTheFailingAgent = titleLabel.stringValue == "recall"
        let notTheCardOnStage = titleLabel.stringValue != "promotions"
        // The other direction, which must not regress: a failure that IS about
        // the card on stage still wears its name.
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("a card already on the stage"),
            sessionId: "on-stage", pid: 1, project: "promotions", cwd: "/tmp/promotions")
        showResult("Its own failure.", about: (sessionId: "on-stage", label: "promotions"))
        let ownFailureKeepsItsName = titleLabel.stringValue == "promotions"
        SelfTest.report("result.subject", [
            ("namesTheFailingAgent", namesTheFailingAgent),
            ("notTheCardOnStage", notTheCardOnStage),
            ("ownFailureKeepsItsName", ownFailureKeepsItsName),
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
        // a session never summarized has no hub, and a door to nothing would
        // be on every card in the app. The label drills matter almost as
        // much: a door that says one thing and opens another is the lie this
        // ruling exists to prevent.
        let priorResolver = doorForSession
        doorForSession = { _ in nil }
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("Finished the poller. Go?"),
            sessionId: "drill", pid: 1, project: "promotions copy", cwd: "/tmp")
        let noHubNoDoor = openPageButton.isHidden
        doorForSession = { _ in .hub }
        render()
        let hubOpensADoor = !openPageButton.isHidden
            && openPageButton.attributedTitle.string.contains(StateLegend.openHubTitle)
        doorForSession = { _ in .report("/tmp/tb-drill-report.html") }
        render()
        let reportNamesItself = !openPageButton.isHidden
            && openPageButton.attributedTitle.string.contains(StateLegend.openReportTitle)
        doorForSession = priorResolver
        SelfTest.report("openHub", [
            ("noHubNoDoor", noHubNoDoor),
            ("hubOpensADoor", hubOpensADoor),
            ("reportNamesItself", reportNamesItself),
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
            id: "drill", name: "an agent arrives", aux: "drill", lamp: .ready)])
        let roomTakenBack = !face.gettingStarted && emptySince == nil
            && bodyLabel.alignment == .natural
        SelfTest.report("emptyRoom", [
            ("describesItselfFirst", describesItselfFirst),
            ("teachesAfterTheClock", teaches),
            ("spelledOutNotGlyphs", spelledOut),
            ("roomTakenBack", roomTakenBack),
        ])

        contrastDrill()
        copyDrill()
        titleDoorDrill()
        selectionDrill()
        hoverDrill()
        quietRowsDrill()
        litLampsOnlyDrill()
        restartedAgentDrill()
        closedRowsDrill()
        lampSwitchDrill()
        pickUpDrill()
        resumePromptDrill()
        readIntensityDrill()
        terminateDrill()
        pastAgentsDrill()
        launchSettingsDrill()
        dropTrayDrill()
        elasticGridDrill()
        goToSessionDrill()

        endCapture(because: "selftest cleanup")
        showIdle(rows: [])
    }

    /// The go-to-session drill (12 Aug, issue 14). The button's main-thread
    /// contract is immediacy: paint "Opening…", hand the walk to a background
    /// task, refuse re-entry — the beach ball was this action doing the walk
    /// in-line, 465 of 477 spindump samples deep in waitUntilExit while the
    /// event-tap watchdog took the hotkeys down with it. pid 1 never has a
    /// controlling terminal, so the background half must come home empty and
    /// drop the guard; that round trip reports three seconds later, on the
    /// mic drill's pattern. The label is NOT asserted at +3s — the ambient
    /// refresh may repaint it at any time, and the guard is the one piece of
    /// state this drill owns outright.
    private func goToSessionDrill() {
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("Go to session drill."),
            sessionId: "goto-drill", pid: 1, project: "promotions copy", cwd: "/tmp")
        let t0 = Date()
        goToSession()
        let returned = Date().timeIntervalSince(t0)
        let painted = bodyLabel.stringValue
        let guardUp = goToSessionInFlight
        goToSession()   // a second tap mid-flight is a no-op, not a queue
        let secondTapHeld = bodyLabel.stringValue == painted && goToSessionInFlight
        SelfTest.report("goToSession", [
            ("returnsImmediately", returned < 0.1),
            ("paintsOpening", painted.hasPrefix("Opening")),
            ("guardRaised", guardUp),
            ("secondTapHeld", secondTapHeld),
        ])
        Permissions.log("selftest goToSession: returned in \(Int(returned * 1000))ms")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            SelfTest.report("goToSession.roundTrip", [
                ("guardDropped", !self.goToSessionInFlight),
            ])
            // The background half painted "no terminal for pid 1" over
            // whatever the cleanup left up; a deploy's selftest must not
            // strand that on the live panel.
            if self.bodyLabel.stringValue.contains("Couldn't find a terminal") {
                self.showIdle(rows: [])
            }
        }
    }

    /// The row menu is on the grid, and only where there is something to act on.
    ///
    /// The panel has no unit tests (rule 7), so this is the whole evidence that
    /// the menu follows liveness — and it is asserted as a PARTITION rather than
    /// as "the live one has a menu", because the failure that matters is a menu
    /// appearing on a row whose process is already gone. That row's verb is
    /// REVIVE, and a kill offered next to it would be a control that can only
    /// lie. The unlit-but-unprovable row is the third case and the reason this
    /// asks `StateLegend.isLive` rather than reading the lamp: liveness we could
    /// not establish is not liveness.
    ///
    /// The ORDER is asserted too (18 Aug). Go to agent is the harmless item and
    /// it holds the top; End session sits last, behind a separator, so the one
    /// item that kills a process is never where a fast pointer lands. A silent
    /// reorder would be invisible in every screenshot and expensive exactly
    /// once.
    private func terminateDrill() {
        func row(_ id: String, _ lamp: StateLegend.Lamp,
                 revivable: Bool = false) -> StateLegend.SessionRow {
            StateLegend.SessionRow(id: id, name: "agent-\(id)", aux: id,
                                   lamp: lamp, revivable: revivable)
        }
        let rows = [
            // `busy` rather than `running` for the third live row: an IDLE
            // session is no longer drawn on the grid (18 Aug), and this drill
            // is about which LIVE rows carry the kill, not about membership.
            row("ready", .ready), row("working", .working), row("busy", .working),
            row("fault", .fault),
            row("exited", .unlit, revivable: true),   // REVIVE's row: no kill
            row("unproven", .unlit),                  // liveness unknown: no kill
        ]
        showIdle(rows: rows)
        let menus = Dictionary(uniqueKeysWithValues: gridRowsForTesting)
        let liveCarry = ["ready", "working", "busy", "fault"]
            .allSatisfy { menus[$0] == true }
        let deadDoNot = ["exited", "unproven"].allSatisfy { menus[$0] == false }
        let everyRowDrawn = rows.allSatisfy { menus[$0.id] != nil }
        let items = (waitingRows.arrangedSubviews.compactMap { $0 as? GridRowView }
            .first { $0.identifier?.rawValue == "ready" }?.menu?.items) ?? []
        // The menu names its target, because the name IS the confirmation.
        let titles = items.map(\.title)
        let named = titles.last ?? ""
        showIdle(rows: [])

        SelfTest.report("terminate", [
            ("everyRowDrawn", everyRowDrawn),
            ("liveRowsCarryIt", liveCarry),
            ("deadRowsDoNot", deadDoNot),
            ("goToAgentIsFirst", titles.first == "Go to agent"),
            ("destructiveIsLastAndSeparated",
             items.count == 3 && items[1].isSeparatorItem),
            ("theItemNamesItsTarget", named == "End session \u{201C}agent-ready\u{201D}"),
        ])
    }

    /// Quiet rows sink, and the active band keeps the order it arrived in.
    ///
    /// The ordering itself is a pure function on an array, so the interesting
    /// half is not "does idle go last" — it is that nothing ELSE moves. The
    /// bands feeding it are recency-ordered, and a partition that quietly
    /// reshuffled ties would spend that ordering without any visible symptom.
    /// So the drill checks positions, not just the tail.
    /// The panel breathes with live work, and with nothing else.
    ///
    /// Ruled 12 Aug: "it's your top eight or all the active sessions, whichever
    /// is larger", where active means green, blue or amber. The failure this
    /// guards is the panel growing for sessions that are merely alive, or for
    /// dead ones — which would make its height a measure of how long the
    /// machine has been on rather than of how much is happening.
    private func elasticGridDrill() {
        func row(_ id: String, _ lamp: StateLegend.Lamp) -> StateLegend.SessionRow {
            StateLegend.SessionRow(id: id, name: id, aux: id, lamp: lamp)
        }
        // A generous screen, so the ceiling rather than the arithmetic decides.
        let big = NSScreen.main
        let quiet = (0..<30).map { row("q\($0)", .running) }
        let dead = (0..<30).map { row("d\($0)", .unlit) }
        let busy = (0..<14).map { row("a\($0)", .working) } + quiet
        let swamped = (0..<40).map { row("a\($0)", .ready) }

        SelfTest.report("elasticGrid", [
            ("quietDoesNotGrowIt",
             Self.gridRowsShown(quiet, screen: big) == Self.gridRowFloor),
            ("deadDoesNotGrowIt",
             Self.gridRowsShown(dead, screen: big) == Self.gridRowFloor),
            ("emptyStaysAtTheFloor",
             Self.gridRowsShown([], screen: big) == Self.gridRowFloor),
            ("activeGrowsIt", Self.gridRowsShown(busy, screen: big) == 14),
            ("neverBelowTheFloor",
             Self.gridRowsShown([row("a", .ready)], screen: big) == Self.gridRowFloor),
            // The regression that shipped 18 Aug: folding the switch into the
            // height collapsed the floor. The height must not know about
            // filed rows; the SLICE must.
            ("filedRowsDoNotShortenTheFloor",
             Self.gridRowsShown([row("f", .running)].map { $0.switchedOffCopy() },
                                screen: big) == Self.gridRowFloor),
            ("clampedByTheScreen",
             Self.gridRowsShown(swamped, screen: big) <= Self.gridRowCapacity(screen: big)),
            ("capacityIsSane",
             (Self.gridRowFloor...Self.gridRowCeiling)
                .contains(Self.gridRowCapacity(screen: big))),
            // The panel must never be taller than the screen it sits on, which
            // is the whole point of computing capacity rather than picking one.
            ("capacityFitsTheScreen", {
                guard let big else { return true }
                let rows = CGFloat(Self.gridRowCapacity(screen: big))
                    * (GridRowView.height + 1)
                return rows + 153 <= big.visibleFrame.height - 32
            }()),
        ])
    }

    /// The list face: the one surface that scrolls, and the only one that may.
    ///
    /// Two properties carry it. The verb has to match the row — offering
    /// REVIVE on a session that is still running is how the app crashed twice
    /// — and the filter has to be a plain predictable substring, because a
    /// filter you cannot predict is one you stop trusting.
    /// How agents start is editable where settings live.
    ///
    /// The two failures worth guarding: rows that render but cannot be typed
    /// into (the panel is `.nonactivatingPanel`, so a field in a window that
    /// cannot become key has nowhere to put first responder — this cost a day
    /// on the list's filter), and a keyboard the pane forgets to give back.
    private func launchSettingsDrill() {
        showSettings(voices: [], roster: [], note: "drill")
        let shown = launchRow?.isHidden == false && directoryRow?.isHidden == false
        let tookKeyboard = panel?.acceptsKey == true
        // What the fields SHOW is the stored value, not the resolved one — a
        // directory that has gone missing must be visible as itself.
        let showsStored = launchRow?.input.stringValue == AgentDefaults.load()
            && directoryRow?.input.stringValue == AgentDefaults.directoryAsTyped()
        // The tabs, which is what this pane was supposed to have all along.
        let tabsShown = settingsTabs?.isHidden == false
        showSettingsTab(.voices)
        let voicesPane = voiceList?.isHidden == false
            && launchRow?.isHidden == true && directoryRow?.isHidden == true
        let keyboardHandedBack = panel?.acceptsKey == false
        showSettingsTab(.agents)
        let backOnAgents = launchRow?.isHidden == false

        // THE REGRESSION, pinned: RECENT then VOICES used to draw the title
        // "Recent audio" over an empty roster with the voices hint beneath it,
        // because only RECENT asked the host for anything.
        showSettingsTab(.recent)
        let recentTitle = face.title
        showSettingsTab(.voices)
        let voicesAfterRecent = face.title == "Voices" && face.audioEvents == nil
        showSettingsTab(.agents)
        let agentsAfterVoices = face.title == "Agents" && face.voices.isEmpty

        SelfTest.report("settingsPanes", [
            ("recentIsItsOwnPane", recentTitle == "Recent audio"),
            ("voicesAfterRecentIsClean", voicesAfterRecent),
            ("agentsAfterVoicesIsClean", agentsAfterVoices),
            // The face carries one pane's payload, never two.
            ("noPaneInheritsAnother",
             !(face.audioEvents != nil && !face.voices.isEmpty)),
        ])

        SelfTest.report("settingsTabs", [
            ("tabBarIsShown", tabsShown),
            ("everyTabHasAPane", SettingsTab.allCases.count == 3),
            ("switchingLeavesTheOtherPaneBehind", voicesPane),
            // The keyboard belongs to one tab, not to the pane.
            ("leavingAgentsHandsTheKeyboardBack", keyboardHandedBack),
            ("comingBackRestoresIt", backOnAgents),
            ("stillInSettings", { if case .settings = state { return true }; return false }()),
        ])

        showIdle(rows: [])
        let released = panel?.acceptsKey == false
        let hiddenOnGrid = launchRow?.isHidden == true && directoryRow?.isHidden == true

        SelfTest.report("launchSettings", [
            ("rowsAppearInSettings", shown),
            ("takesTheKeyboard", tookKeyboard),
            ("fieldsShowWhatIsStored", showsStored),
            ("givesTheKeyboardBack", released),
            ("goneFromEveryOtherFace", hiddenOnGrid),
            // The whole point of one setting: every launch path reads it.
            ("oneSettingDrivesEveryLaunch",
             SessionLauncher.defaultCommand == AgentDefaults.load()
                && SessionLauncher.defaultDirectory == AgentDefaults.directory()),
        ])
    }

    private func pastAgentsDrill() {
        func item(_ id: String, _ name: String, live: Bool, cwd: String)
            -> PastAgentsList.Item {
            PastAgentsList.Item(
                row: StateLegend.SessionRow(
                    id: id, name: name, aux: StateLegend.shortId(id),
                    lamp: live ? .running : .unlit, revivable: !live),
                revivable: !live,
                haystack: [name, id, cwd].joined(separator: " ").lowercased())
        }
        // The last one is the row that broke: a stopped session puts its REASON
        // in the right column instead of an id, and a reason is a sentence.
        let stallReason = "silent for 24h, nothing written since it started this"
        let stalled = PastAgentsList.Item(
            row: StateLegend.SessionRow(
                id: "9f0c2b71-4444", name: "Blankshirts Mailchimp audit",
                aux: stallReason, lamp: .unlit, revivable: true,
                detail: stallReason),
            revivable: true,
            haystack: "blankshirts mailchimp audit")
        // And the row that broke NEXT: a title long enough to want the whole
        // width. Before the column was fixed it took it, and the time — the
        // one thing this face exists to say — rendered at zero points.
        let longTitled = PastAgentsList.Item(
            row: StateLegend.SessionRow(
                id: "6d1a77e0-5555",
                name: "Back to School 2026 Mailchimp email campaign for Blankshirts",
                aux: StateLegend.shortId("6d1a77e0-5555"), lamp: .unlit, revivable: true),
            revivable: true, haystack: "back to school",
            aux: "88m ago")
        let items = [
            item("a285f0a9-1111", "Plan Mirai campaign", live: false, cwd: "/tmp/kopi"),
            item("c53ce6f5-2222", "Review PR", live: true, cwd: "/tmp/kopi"),
            item("381c643c-3333", "Compare apartments", live: false, cwd: "/tmp/home"),
            stalled,
            longTitled,
        ]
        showPastAgents(items: items)
        let entered = state == .pastAgents
        let scrolls = pastList.subviews.contains { $0 is NSScrollView }
        // The right column says WHICH session or WHY it stopped, and nothing
        // else. The id half is the original claim — the row and the log name
        // the same session two different ways — and the reason half is the
        // 16 Aug exception, which this drill did not know about until a stalled
        // row was added to its sample and turned it red (19 Aug).
        let idsMatch = items.allSatisfy {
            $0.row.aux == StateLegend.shortId($0.row.id) || $0.row.aux == $0.row.detail
        }
        let tookKeyboard = panel?.acceptsKey == true
        // The name holds its column against a sentence in the right one.
        //
        // Asserted as a WIDTH, because the name was set correctly the whole
        // time — `displayName` had already resolved "Blankshirts Mailchimp
        // audit" — and Auto Layout then rendered it at zero points, so every
        // assertion about the string would have passed while the row on screen
        // named no agent at all (screenshot, 19 Aug). Half the row is the
        // claim: the reason is capped at `auxFraction` (0.38), so the name can
        // never be the thing that loses.
        panel?.contentView?.layoutSubtreeIfNeeded()
        let nameWidths = pastList.nameWidthsForTesting
        let stalledName = nameWidths.first { $0.id == "9f0c2b71-4444" }?.width ?? 0
        let listWidth = pastList.frame.width
        let stalledRowStillNamesItsAgent = stalledName > listWidth / 2
        // The mirror claim, and the one Robert reported: the time is a FIXED
        // column, so a title long enough to want the whole row cannot take it.
        // Asserted as a width for the same reason — "88m ago" was set on the
        // label the whole time and drawn at zero points.
        let auxWidths = pastList.auxWidthsForTesting
        let longTitleAux = auxWidths.first { $0.id == "6d1a77e0-5555" }?.width ?? 0
        let theTimeSurvivesALongTitle = longTitleAux >= PastRowView.auxColumn
        let everyRowKeepsItsColumn = auxWidths.allSatisfy { $0.width >= PastRowView.auxColumn }
        // And the title yields instead, rather than being drawn over the verb.
        let longTitleName = nameWidths.first { $0.id == "6d1a77e0-5555" }?.width ?? 0
        let theTitleTruncatesInstead =
            longTitleName > 0 && longTitleName <= listWidth - PastRowView.auxColumn
        // And nothing is lost: the tooltip carries the name AND the full
        // sentence, uncut, which is where the truncated half goes.
        let stalledTip = StateLegend.hoverText(for: stalled.row) ?? ""
        let theFullReasonIsReachable = stalledTip.contains(stallReason)
            && stalledTip.contains("Blankshirts Mailchimp audit")
        // Read WHILE the face is up. Everything below `goHomeFromPastAgents`
        // is a fact about the grid, which is what the first version of these
        // two accidentally asserted.
        let backInPlacardRow = pastBackButton?.isHidden == false
        let noSecondBack = backButton.isHidden
        let caretColour = pastList.caretColourForTesting
        // A sample bigger than any screen can draw, so the split is real.
        let sample = (0..<40).map {
            StateLegend.SessionRow(id: "s\($0)", name: "s\($0)", aux: "s\($0)",
                                   lamp: $0 < 3 ? .ready : ($0 < 30 ? .running : .unlit))
        }
        let drawn = Self.gridRows(sample)
        let rest = Array(Self.pastAgents(sample))
        let disjoint = Set(drawn.map(\.id)).isDisjoint(with: Set(rest.map(\.id)))
        let partitioned = drawn.count + rest.count
        // The verb follows liveness, never the other way round.
        let verbs = items.allSatisfy { $0.revivable == ($0.row.lamp == .unlit) }
        // The placard's text starts clear of the chevron sharing its row —
        // measured in window space, because the two live in different parents
        // and comparing raw minX across parents compares nothing (the original
        // overlap shipped precisely because nothing measured this).
        panel?.contentView?.layoutSubtreeIfNeeded()
        let indent = (stateLabel.attributedStringValue.length > 0
            ? stateLabel.attributedStringValue.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            : nil)?.firstLineHeadIndent ?? 0
        let chevronMaxX = pastBackButton.convert(pastBackButton.bounds, to: nil).maxX
        let placardTextMinX = stateLabel.convert(stateLabel.bounds, to: nil).minX + indent
        let placardClearsChevron = placardTextMinX >= chevronMaxX - 1
        // Terminate rides the right-click, on exactly the rows that have a
        // process to end: live rows carry the menu, dead rows carry none.
        let menuByRow = Dictionary(uniqueKeysWithValues: pastList.rowsForTesting)
        let terminateFollowsLiveness = items.allSatisfy {
            menuByRow[$0.row.id] == !$0.revivable
        }
        goHomeFromPastAgents()

        SelfTest.report("pastAgents", [
            ("entersItsOwnState", entered),
            // The filter is a text field in a panel that is normally unable to
            // become key. Without this it renders, ignores the click, and looks
            // broken for a reason nothing on screen explains.
            ("takesTheKeyboardForFiltering", tookKeyboard),
            ("givesTheKeyboardBack", panel?.acceptsKey == false),
            // The caret is the one AppKit-coloured thing on this face, and the
            // colour it reaches for by default is the WORKING lamp's blue —
            // blinking, on a panel where blue means an agent has work in hand.
            ("caretIsNotTheWorkingLamp", caretColour != StateLegend.Palette.working),
            ("caretComesFromThePalette", caretColour == StateLegend.Palette.ink),
            ("itIsTheFaceThatScrolls", scrolls),
            // A stack view in a scroll view lays out from the BOTTOM unless it
            // is flipped, so the list opened on its oldest session — which
            // reads as a broken sort rather than as a coordinate system.
            ("opensAtTheTop", pastList.isAtTopForTesting),
            // The two surfaces partition one list: nothing is in both, nothing
            // is in neither. Asserted as a split rather than as two filters,
            // because a filter can be wrong in both directions at once.
            ("gridAndListAreDisjoint", disjoint),
            ("nothingIsLost", partitioned == sample.count),
            // Its header is one row, like the grid's.
            ("backSitsInThePlacardRow", backInPlacardRow),
            ("noSecondBackButton", noSecondBack),
            ("idMatchesTheLogs", idsMatch),
            ("stalledRowStillNamesItsAgent", stalledRowStillNamesItsAgent),
            ("theTimeSurvivesALongTitle", theTimeSurvivesALongTitle),
            ("everyRowKeepsItsColumn", everyRowKeepsItsColumn),
            ("theTitleTruncatesInstead", theTitleTruncatesInstead),
            ("theFullReasonIsReachable", theFullReasonIsReachable),
            ("verbFollowsLiveness", verbs),
            ("placardClearsChevron", placardClearsChevron),
            ("terminateFollowsLiveness", terminateFollowsLiveness),
            ("leavesCleanly", { if case .idle = state { return true }; return false }()),
        ])
    }

    private func goHomeFromPastAgents() {
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

    /// The drop tray, on a real panel.
    ///
    /// Everything here is invisible to `swift test` by construction: whether
    /// a drag is refused, whether the chips on screen belong to the session
    /// the panel is addressing, and whether a drag resizes the window are
    /// facts about views. The tray's LOGIC is unit-tested in Core
    /// (AttachmentTrayTests); this asserts the half that draws.
    private func dropTrayDrill() {
        let priorTarget = replyTargetForDrop
        let priorStaged = stagedFiles
        let priorUnstage = onUnstage
        defer {
            replyTargetForDrop = priorTarget
            stagedFiles = priorStaged
            onUnstage = priorUnstage
        }

        // A tray with two files for A, one for B — so a face addressing A can
        // be caught showing B's.
        var tray = ["A": ["/tmp/one.png", "/tmp/two.pdf"], "B": ["/tmp/other.png"]]
        var unstaged: (session: String, path: String)?
        stagedFiles = { tray[$0] ?? [] }
        onUnstage = { session, path in unstaged = (session, path) }

        // Addressing A, on a card.
        replyTargetForDrop = { (sessionId: "A", label: "promotions copy") }
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("A card with files attached."),
            sessionId: "A", pid: 1, project: "promotions copy", cwd: "/tmp")
        let chipsShowOnTheCard = !trayRow.isHidden
        let chipsAreTheStagedFiles =
            trayRow.displayedNamesForTesting == ["one.png", "two.pdf"]

        // The SEV 1, on the surface this time: the panel is addressing A, so
        // B's file must be nowhere on it. Core makes the wrong-session RIDE
        // impossible; this asserts the panel cannot even SHOW it, because the
        // chips are what licenses the attachment.
        let noOtherSessionsChips =
            !trayRow.displayedNamesForTesting.contains("other.png")

        // The invitation names its destination, and appears only while a drag
        // is actually over the panel.
        let overlayHiddenAtRest = dropOverlay.isHidden
        let heightBefore = panel?.frame.height ?? 0
        dropSurface?.onDragTargetChanged?("promotions copy")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let overlayShows = !dropOverlay.isHidden
        let overlaySaysOneThing =
            dropOverlay.messageForTesting == "Drop file for agent here"
        // The sentence stays INSIDE the panel. Asserted as geometry rather
        // than as a length limit on the string: the first version printed the
        // destination's name and ran off the right edge, and a rule that says
        // "keep the text short" is a rule the next edit forgets. Measured
        // against a deliberately absurd string, so the constraint is what
        // holds the line and not the wording.
        dropOverlay.showForTesting(String(repeating: "wide ", count: 40))
        panel?.contentView?.layoutSubtreeIfNeeded()
        let sentenceFits = dropOverlay.textFitsForTesting
        dropSurface?.onDragTargetChanged?("promotions copy")
        panel?.contentView?.layoutSubtreeIfNeeded()
        // A drag must not resize the window under the pointer: the overlay is
        // parented outside the content stack precisely so the panel holds
        // still while you are aiming at it.
        let panelHeldStill = abs((panel?.frame.height ?? 0) - heightBefore) < 1
        dropSurface?.onDragTargetChanged?(nil)
        let overlayLeaves = dropOverlay.isHidden

        // No target, no invitation. A "drop here" the app cannot honour is
        // worse than a cursor that never invited you.
        replyTargetForDrop = { nil }
        let refusesWithNoTarget = dropSurface?.canAccept?() == nil
        render()
        let noChipsWithNoTarget = trayRow.isHidden

        // Back to A, then the chip's ✕: per path, and it names the session it
        // came from — a cross that cleared the other file would be the same
        // surprise the whole feature exists to avoid.
        replyTargetForDrop = { (sessionId: "A", label: "promotions copy") }
        render()
        trayRow.removeButtonsForTesting.first.map {
            _ = $0.target?.perform($0.action, with: $0)
        }
        let crossUnstagesOnePath = unstaged?.path == "/tmp/one.png"
        let crossNamesItsSession = unstaged?.session == "A"

        // The faces that address nobody: a list and a settings pane are not
        // conversations, and a chip there would name a session the face does
        // not show.
        tray["A"] = ["/tmp/one.png"]
        showPastAgents(items: [])
        let noChipsOnTheList = trayRow.isHidden
        goHomeFromPastAgents()
        render()

        SelfTest.report("dropTray", [
            ("chipsShowOnTheCard", chipsShowOnTheCard),
            ("chipsAreTheStagedFiles", chipsAreTheStagedFiles),
            ("noOtherSessionsChips", noOtherSessionsChips),
            ("overlayHiddenAtRest", overlayHiddenAtRest),
            ("overlayShowsOnDrag", overlayShows),
            ("overlaySaysOneThing", overlaySaysOneThing),
            ("sentenceStaysInsideThePanel", sentenceFits),
            ("panelHeldStillUnderTheDrag", panelHeldStill),
            ("overlayLeavesWithTheDrag", overlayLeaves),
            ("refusesWithNoTarget", refusesWithNoTarget),
            ("noChipsWithNoTarget", noChipsWithNoTarget),
            ("crossUnstagesOnePath", crossUnstagesOnePath),
            ("crossNamesItsSession", crossNamesItsSession),
            ("noChipsOnTheList", noChipsOnTheList),
        ])
    }

    private func quietRowsDrill() {
        func row(_ id: String, _ lamp: StateLegend.Lamp) -> StateLegend.SessionRow {
            StateLegend.SessionRow(id: id, name: id, aux: id, lamp: lamp)
        }
        // Deliberately interleaved, and with two of each active lamp, so a
        // comparator that grouped by lamp rather than partitioning would fail.
        // The closed rows are seeded in the MIDDLE for the same reason: they
        // have to sink past the quiet band, not merely past the active one.
        let mixed = [row("w1", .working), row("i1", .running), row("d1", .unlit),
                     row("r1", .ready), row("i2", .running), row("d2", .unlit),
                     row("f1", .fault), row("w2", .working)]
        let sorted = StateLegend.quietRowsLast(mixed).map(\.id)

        SelfTest.report("quietRows", [
            ("closedLast", sorted.suffix(2) == ["d1", "d2"]),
            ("quietAboveClosed", Array(sorted[4...5]) == ["i1", "i2"]),
            ("activeKeepsArrivalOrder", Array(sorted.prefix(4)) == ["w1", "r1", "f1", "w2"]),
            ("nothingLost", sorted.count == mixed.count),
            ("allQuietIsStillAllQuiet",
             StateLegend.quietRowsLast([row("i1", .running), row("i2", .running)])
                .map(\.id) == ["i1", "i2"]),
        ])
    }

    /// The grid draws lit lamps, and nothing else.
    ///
    /// This drill was `liveRowsHoldTheirPlace` and asserted the opposite half
    /// of the same question — that a live session keeps its row however dim.
    /// Robert overruled that on 18 Aug, pointing at an idle socket drawn on the
    /// grid: "the grid is for lit fucking lamps." The earlier drill's real case
    /// survives and is kept below: the sessions it was written to protect were
    /// working or blocked, both LIT, and they still hold their rows. What
    /// changed is that alive-and-quiet is no longer an entitlement.
    private func litLampsOnlyDrill() {
        func row(_ id: String, _ lamp: StateLegend.Lamp) -> StateLegend.SessionRow {
            StateLegend.SessionRow(id: id, name: id, aux: id, lamp: lamp)
        }
        let capacity = Self.gridRowCapacity()
        // The 18 Aug panel: nine lit, ten quiet — and now the quiet ten are
        // the list's, not the grid's.
        let asItWas = StateLegend.quietRowsLast(
            (0..<9).map { row("lit\($0)", .ready) }
            + (0..<10).map { row("quiet\($0)", .running) })
        let drawn = Self.gridRows(asItWas)
        let listed = Array(Self.pastAgents(asItWas))

        // The case the superseded rule was written for, restated: a session
        // that is WORKING or BLOCKED is lit, and keeps its row.
        let busy = StateLegend.quietRowsLast(
            (0..<9).map { row("work\($0)", .working) }
            + [row("stuck", .fault)] + (0..<10).map { row("quiet\($0)", .running) })
        let busyDrawn = Self.gridRows(busy)

        // One lit session per slot, and one more than there is room for.
        let overflowing = (0..<(capacity + 1)).map { row("lit\($0)", .ready) }
        // Everything the grid does not draw, whatever the reason.
        let everything = StateLegend.quietRowsLast(
            [row("lit", .ready), row("quiet", .running), row("dead", .unlit),
             StateLegend.SessionRow(id: "filed", name: "filed", aux: "filed",
                                    lamp: .running, switchedOff: true)])

        SelfTest.report("litLampsOnly", [
            ("noIdleRowIsDrawn", !drawn.contains { $0.lamp == .running }),
            ("everyLitRowIsDrawn", drawn.count == 9),
            ("quietGoesToTheList", listed.count == 10),
            // The superseded drill's real case, kept.
            ("workingAndBlockedKeepTheirRows",
             busyDrawn.count == 10 && busyDrawn.allSatisfy { $0.lamp.isLit }),
            // The one demotion that is not about the lamp: the edge of the glass.
            ("theScreenIsStillTheLimit", Self.gridRows(overflowing).count == capacity),
            ("overflowGoesToTheList",
             Self.pastAgents(overflowing).count == overflowing.count - capacity),
            // Quiet, dead and switched-off all land in the same place, which is
            // the coherence Robert asked for: a lamp that is out is a lamp that
            // is out, however it got that way.
            // Idle by itself and idle by the switch land in the same place —
            // the coherence the ruling is really about. `dead` stays eligible
            // for a floor slot; that is the 11 Aug ruling, untouched here.
            ("outIsOutHoweverItGotThatWay",
             Set(Self.pastAgents(everything).map(\.id)).isSuperset(of: ["quiet", "filed"])
                && !Self.gridRows(everything).contains { $0.id == "filed" }),
            ("nothingIsLost",
             Self.gridRows(everything).count + Self.pastAgents(everything).count
                == everything.count),
            // The panel's HEIGHT keeps its floor — that number is geometry and
            // was never the membership rule. Folding the two together shipped a
            // regression on 18 Aug; see `gridRows`.
            ("theFloorIsStillGeometry",
             Self.gridRowsShown([row("q", .running)]) == Self.gridRowFloor),
        ])
    }

    /// A restarted agent is on the grid, not in Past Agents.
    ///
    /// Ruled 19 Aug, on `04d50469`: killed between a tool call and its result,
    /// resumed seven minutes later, and filed away by the panel while its owner
    /// sat looking at it. Robert: *"when you restart an agent, the lamp should
    /// immediately be on … it should be on the grid, not in past agents."*
    /// Re-ruled the same evening, wider: *"anytime I click on an agent to
    /// resurrect it, it is no longer idle."* So resumption is the membership
    /// fact and it does not care what the old turn was doing — including a
    /// conversation that had finished cleanly, which the first cut left quiet.
    ///
    /// Drilled as the whole path rather than as the rule alone, because the
    /// rule was never the doubtful part: `AgentRestart` is unit-tested and was
    /// green while the row was still in the wrong place. What this asserts is
    /// that the verdict reaches the LAMP and the lamp reaches the GRID — the
    /// two joins that the 18 Aug downgrade sat between.
    private func restartedAgentDrill() {
        func row(_ id: String, _ lamp: StateLegend.Lamp) -> StateLegend.SessionRow {
            StateLegend.SessionRow(id: id, name: id, aux: id, lamp: lamp)
        }
        // The real clocks off this machine at 22:32: the conversation's last
        // word at 22:25:22, the process up at 22:32:22.
        let lastWord = Date(timeIntervalSince1970: 1_787_178_322)
        let restart = Date(timeIntervalSince1970: 1_787_178_742.354)
        // The lamp half of `lampAndReason`, for a process reporting `idle` —
        // which is where every one of these rows used to land as quiet.
        func lamp(_ activity: SessionActivity, startedAt: Date?)
            -> (lamp: StateLegend.Lamp, aux: String) {
            guard AgentRestart.resumed(startedAt: startedAt, lastWord: lastWord),
                  let said = AgentRestart.reason(for: activity)
            else { return (.running, "quiet") }
            return (.fault, said.short)
        }
        let interrupted = lamp(.working, startedAt: restart)
        let reopened = lamp(.idle, startedAt: restart)
        let stalled = lamp(.stalled(reason: "silent for 2h"), startedAt: restart)
        // The same file, read against a process that has been up all along.
        let untouched = lamp(.working, startedAt: lastWord.addingTimeInterval(-600))
        let rows = StateLegend.quietRowsLast([
            row("interrupted", interrupted.lamp), row("reopened", reopened.lamp),
            row("neverRestarted", untouched.lamp)])
        let drawn = Set(Self.gridRows(rows).map(\.id))
        let listed = Set(Self.pastAgents(rows).map(\.id))

        SelfTest.report("restartedAgent", [
            ("aRestartLightsTheLamp", interrupted.lamp == .fault),
            ("aRestartedStallLightsToo", stalled.lamp == .fault),
            // The 19 Aug widening: a clean finish is still a restart.
            ("aReopenedConversationLightsToo", reopened.lamp == .fault),
            ("theRowSaysWhichKindItIs", interrupted.aux != reopened.aux),
            ("bothAreDrawnOnTheGrid",
             drawn.isSuperset(of: ["interrupted", "reopened"])),
            ("neitherIsFiledAway",
             listed.isDisjoint(with: ["interrupted", "reopened"])),
            // The narrowness that survives: this must not light every live row.
            ("anUnrestartedSessionIsUntouched",
             untouched.lamp == .running && listed.contains("neverRestarted")),
            // And it retires itself the moment the session is spoken to.
            ("typingEndsIt",
             !AgentRestart.resumed(startedAt: restart,
                                   lastWord: restart.addingTimeInterval(30))),
        ])
    }

    /// A session that is not awake is still a row, and tapping it is a
    /// different verb — or, when nothing was proven, no verb at all.
    ///
    /// Ruled 11 Aug: "They are equally valid agents whether or not they are
    /// awake." The dangerous half is the third case. `claude --resume` against
    /// a session that is actually still running leaves the original process
    /// alive and adds a second live entry under the same id, which crashed the
    /// app twice (06 Aug 14:35, 07 Aug 17:39). An unlit row whose liveness
    /// could not be proven must therefore do NOTHING on tap rather than fall
    /// through to the announce path it used to share.
    private func closedRowsDrill() {
        func row(_ id: String, _ lamp: StateLegend.Lamp,
                 revivable: Bool = false) -> StateLegend.SessionRow {
            StateLegend.SessionRow(id: id, name: id, aux: id,
                                   lamp: lamp, revivable: revivable)
        }
        let unlit = StateLegend.Lamp.unlit

        // The row is drawn by presence, not by a fifth colour: nothing in the
        // socket, a fainter ring than the seated lamp, and stepped-back ink.
        let noFill = unlit.fill.alphaComponent == 0
        let fainterRing = (unlit.ring?.alphaComponent ?? 1)
            < (StateLegend.Lamp.running.ring?.alphaComponent ?? 0)

        // Every drill row goes through showIdle so the grid actually builds
        // one — a row that sorts correctly and then fails to render is the
        // failure this layer exists to catch.
        showIdle(rows: [row("live", .ready), row("dead", unlit, revivable: true),
                        row("unproven", unlit)])
        let built = waitingRows.arrangedSubviews.compactMap { $0 as? GridRowView }

        SelfTest.report("closedRows", [
            ("unlitHasNoFill", noFill),
            ("unlitRingIsFainterThanQuiet", fainterRing),
            ("unlitDimsTheRow", unlit.rowAlpha < 1 && StateLegend.Lamp.running.rowAlpha == 1),
            ("liveRowAnnounces", StateLegend.action(for: row("live", .ready)) == .announce),
            // Amber does not speak, it points (18 Aug). A blocked session is
            // not in the waiting set, so the announcement it used to trigger
            // had nothing to say and left the panel sitting on Preparing.
            ("amberRowGoesToAgent",
             StateLegend.action(for: row("amber", .fault)) == .goToAgent),
            // ...and is still a live row, so it keeps its menu. The two
            // questions are asked through one function precisely so this
            // cannot come apart.
            ("amberRowIsStillLive", StateLegend.isLive(row("amber", .fault))),
            ("revivableRowRevives",
             StateLegend.action(for: row("dead", unlit, revivable: true)) == .revive),
            ("unprovenRowDoesNothing",
             StateLegend.action(for: row("unproven", unlit)) == StateLegend.RowAction.none),
            ("closedRowsStillRender", built.count == 3),
        ])
        showIdle(rows: [])
    }

    /// The lamp is the grid's membership control, and its verb depends on the
    /// face it was clicked on.
    ///
    /// A drill rather than a unit test for the half that cannot be reached
    /// otherwise. The mapping is a pure function and could be tested anywhere,
    /// but "a filed row is never drawn on the grid" is a fact about a slice of
    /// an array a view builder produces, and it is the half that carries the
    /// user's click: if a filed row reaches the grid, its lamp offers `turnOff`
    /// on a session that is already off and the switch has no way back.
    private func lampSwitchDrill() {
        func row(_ id: String, _ lamp: StateLegend.Lamp,
                 revivable: Bool = false, off: Bool = false) -> StateLegend.SessionRow {
            StateLegend.SessionRow(id: id, name: id, aux: id, lamp: lamp,
                                   revivable: revivable, switchedOff: off)
        }
        let unlit = StateLegend.Lamp.unlit

        // One session in each state, one of them filed, through the real
        // banding and the real partition.
        let rows = StateLegend.quietRowsLast([
            row("asking", .ready), row("busy", .working), row("stuck", .fault),
            row("quiet", .running), row("filed", .running, off: true),
            row("dead", unlit, revivable: true),
        ])
        let drawn = Self.gridRows(rows)
        let listed = Array(Self.pastAgents(rows))
        let filedIsNeverOnTheGrid = !drawn.contains { $0.switchedOff }
        let filedIsInTheList = listed.contains { $0.id == "filed" }
        let nothingIsLost = drawn.count + listed.count == rows.count

        // And the list actually hands every row a lamp target — including the
        // live ones, which is the case that used to navigate to a Terminal tab.
        let items = rows.map {
            PastAgentsList.Item(row: $0, revivable: $0.revivable, haystack: $0.name)
        }
        showPastAgents(items: items)
        let everyRowHasASwitch = pastList.lampTargetsForTesting.count == items.count
        goHomeFromPastAgents()

        SelfTest.report("lampSwitch", [
            // The sentence: on the grid it files away, in the list it brings back.
            ("gridFilesEveryLitRow",
             [row("a", .ready), row("b", .working), row("c", .fault), row("d", .running)]
                .allSatisfy { StateLegend.lampAction(for: $0, on: .grid) == .turnOff }),
            ("listRestoresEveryLiveRow",
             [row("a", .ready), row("b", .working), row("c", .fault), row("d", .running)]
                .allSatisfy { StateLegend.lampAction(for: $0, on: .list) == .turnOn }),
            // The one exception, and it is the same on both faces: you cannot
            // flip a terminated process on, you have to resurrect it.
            ("deadRevivesOnEitherFace",
             StateLegend.lampAction(for: row("x", unlit, revivable: true), on: .grid) == .revive
                && StateLegend.lampAction(for: row("x", unlit), on: .list) == .revive),
            // Off is not a kill: nothing in the lamp's vocabulary terminates.
            ("noLampVerbEndsAProcess",
             Set([StateLegend.LampAction.turnOff, .turnOn, .revive]).count == 3),
            // Membership, through the real partition rather than by assertion.
            ("filedIsNeverOnTheGrid", filedIsNeverOnTheGrid),
            ("filedIsInTheList", filedIsInTheList),
            ("nothingIsLost", nothingIsLost),
            // An unfiled IDLE session leaves the grid too — same state, and
            // the switch would look broken if only its own output did.
            ("idleLeavesTheGridWhetherFiledOrNot",
             !drawn.contains { $0.id == "quiet" } && !drawn.contains { $0.id == "filed" }),
            ("pastAgentsRowsCarryTheSwitch", everyRowHasASwitch),
            ("switchIsTheSameSizeOnBothFaces",
             GridRowView.lampHitWidth == GridRowView.lampColumn),
        ])
    }

    /// Picking a session up: what a left-click on a LIVE row in Past Agents
    /// does, and what it no longer does.
    ///
    /// Ruled 19 Aug, after a click sent him to a Terminal window he had not
    /// asked for: *"when I click on an idle agent … it should turn the lamp on,
    /// open the agent card. Because it's alive, clicking on it obviously means
    /// I want it to be alive. Now it's in the grid."* GO TO AGENT keeps its
    /// place on the right-click, next to END SESSION.
    ///
    /// The wiring is the whole risk here, so the drill calls the row's real tap
    /// closure and watches which of the panel's doors open. The handlers are
    /// swapped for recorders and put back — announcing for real inside a drill
    /// would speak out loud on every launch.
    private func pickUpDrill() {
        let live = StateLegend.SessionRow(id: "alive", name: "alive", aux: "alive",
                                          lamp: .running)
        let dead = StateLegend.SessionRow(id: "gone", name: "gone", aux: "gone",
                                          lamp: .unlit, revivable: true)
        showPastAgents(items: [
            PastAgentsList.Item(row: live, revivable: false, haystack: live.name),
            PastAgentsList.Item(row: dead, revivable: true, haystack: dead.name),
        ])
        // The row says which verb it has.
        let verbs = pastList.verbsForTesting
        let liveSaysOpen = verbs["alive"] == "OPEN \u{203A}"
        let deadStillRevives = verbs["gone"] == "REVIVE \u{203A}"
        // Go to agent lives on the right-click now, on the live row only.
        let menus = pastList.menuTitlesForTesting
        let goToIsInTheMenu = menus["alive"]?.contains { $0.hasPrefix("Go to ") } == true
        let terminateIsStillThere = menus["alive"]?.contains { $0.hasPrefix("Terminate ") } == true
        let deadHasNoMenu = menus["gone"] == nil

        // The tap itself, through the real closure.
        let realRestore = onRestoreLamp, realPick = onPickWaiting
        let realGoTo = onGoToSession, realHome = onBreadcrumbHome
        var switchedOn: String?, cardOpened: String?, wentToTerminal: String?
        onRestoreLamp = { switchedOn = $0 }
        onPickWaiting = { cardOpened = $0 }
        onGoToSession = { wentToTerminal = $0 }
        onBreadcrumbHome = {}
        pastList.onPick?("alive", false)
        let tapStayedOnThePanel = wentToTerminal == nil
        // …and the menu's verb, which must still reach the terminal.
        pastList.onGoTo?("alive")
        let menuWentToTerminal = wentToTerminal == "alive"
        onRestoreLamp = realRestore; onPickWaiting = realPick
        onGoToSession = realGoTo; onBreadcrumbHome = realHome
        goHomeFromPastAgents()

        SelfTest.report("pickUp", [
            ("theTapTurnsTheLampOn", switchedOn == "alive"),
            ("theTapOpensTheCard", cardOpened == "alive"),
            // The regression this exists to prevent, stated as its own line.
            ("theTapDoesNotJumpToTheTerminal", tapStayedOnThePanel),
            ("theMenuStillDoes", menuWentToTerminal),
            ("goToAgentIsOnTheRightClick", goToIsInTheMenu),
            ("endSessionKeptItsPlace", terminateIsStillThere),
            ("aDeadRowHasNeitherVerb", deadHasNoMenu),
            ("theRowNamesItsVerb", liveSaysOpen && deadStillRevives),
            // And what the switch it flips is worth: an idle session the user
            // picked up is lit, so the grid draws it.
            ("aPickedUpSessionIsDrawnOnTheGrid",
             Self.gridRows([StateLegend.SessionRow(id: "alive", name: "alive",
                                                   aux: "standing by", lamp: .fault)])
                .contains { $0.id == "alive" }),
        ])
    }

    /// The state that is permanently on this machine and had no name until
    /// 19 Aug: a session locked at the resume prompt.
    ///
    /// Robert: *"it happens every single time, and it's locked. But not
    /// detectable. You can see it's treated as green, like a ready state."* The
    /// row had a stored waiting turn, so the waiting band drew it green from the
    /// store without ever asking the process — which was saying `status: waiting
    /// · waitingFor: dialog open` the whole time.
    ///
    /// Drilled at the join rather than at the rule (`WaitingAtTests` has the
    /// rule): the words have to reach the row, the row has to reach the grid,
    /// the tap has to reach the terminal — and the SEND path has to refuse the
    /// same session the lamp is describing. A panel that shows "answer this in
    /// the terminal" while quietly typing into the dialog would be worse than
    /// the green row it replaced.
    private func resumePromptDrill() {
        let at = WaitingAt.resumePrompt
        let locked = StateLegend.SessionRow(
            id: "locked", name: "PRs in the Hub", aux: at.short,
            lamp: .fault, detail: at.full)
        showIdle(rows: [locked])
        panel?.contentView?.layoutSubtreeIfNeeded()
        let drawn = Self.gridRows([locked]).contains { $0.id == "locked" }
        let tip = waitingRows.arrangedSubviews
            .compactMap { $0 as? GridRowView }
            .first { $0.identifier?.rawValue == "locked" }?.toolTip

        SelfTest.report("resumePrompt", [
            // Not green. That is the whole complaint.
            ("aLockedSessionIsNotReady", locked.lamp != .ready),
            ("itIsDrawnOnTheGrid", drawn),
            // Amber's tap is the one move that helps: it puts you in the tab
            // where the dialog is.
            ("theTapGoesToTheTerminal",
             StateLegend.action(for: locked) == .goToAgent),
            ("theRowNamesTheDialog", locked.aux == "waiting at the resume prompt"),
            // The hover is "name, newline, reason" (see StateLegend.hoverText),
            // so the assertion is that the sentence is IN it. The first version
            // of this line compared the tooltip to the reason alone and failed
            // on a build where nothing was wrong but the drill.
            ("theWholeSentenceIsReachable", tip?.contains(at.full) == true),
            // The pair that must never disagree: the lamp says answer it there,
            // and the send path refuses to type into it.
            ("thePanelWillNotTypeIntoIt",
             !Readiness.waiting(Readiness.dialogOpen).canDispatch
                && !at.acceptsTypedReply),
            // And the daily loop is untouched — a question still takes a reply.
            ("aQuestionStillTakesAReply",
             Readiness.waiting("input needed").canDispatch
                && WaitingAt.question.acceptsTypedReply),
        ])
    }

    /// The weight IS the read state (ruled 13 Aug): an unread ready row is
    /// semibold, an opened one drops to medium, the lamp identical in both —
    /// read is not answered. A drill because the mapping lives in a view
    /// initializer no unit test can reach, and a weight that quietly stopped
    /// varying would put the grid back to two states it cannot tell apart.
    private func readIntensityDrill() {
        let items = [
            StateLegend.SessionRow(id: "unread", name: "unread", aux: "u",
                                   lamp: .ready, read: .unread),
            StateLegend.SessionRow(id: "opened", name: "opened", aux: "o",
                                   lamp: .ready, read: .opened),
            StateLegend.SessionRow(id: "w-unread", name: "working unread", aux: "wu",
                                   lamp: .working, read: .unread),
            StateLegend.SessionRow(id: "w-opened", name: "working opened", aux: "wo",
                                   lamp: .working, read: .opened),
            StateLegend.SessionRow(id: "idle", name: "idle, nothing waiting", aux: "i",
                                   lamp: .running, read: .none),
        ]
        // Built directly rather than through `showIdle`, because the idle row
        // is no longer drawn on the grid (18 Aug) and this drill's subject was
        // never membership — it is the mapping from read state to ink and lamp,
        // which lives in a view initializer no unit test can reach. Where each
        // row LANDS is asserted at the bottom, through the real partition.
        let built = items.map {
            GridRowView(item: $0, auxWidth: 40, target: self,
                        action: #selector(sessionRowTapped(_:)))
        }
        let label = { (id: String) in
            built.first { $0.identifier?.rawValue == id }?.nameLabel
        }
        let lampFill = { (id: String) -> CGColor? in
            built.first { $0.identifier?.rawValue == id }?.lampLayer?.backgroundColor
        }
        // Hollow == no fill. Read off the layer the row actually built, not
        // recomputed from the item, or the drill would be asserting its own
        // arithmetic rather than the panel's.
        func hollow(_ id: String) -> Bool { (lampFill(id)?.alpha ?? 1) == 0 }
        func solid(_ id: String) -> Bool { (lampFill(id)?.alpha ?? 0) > 0 }
        // The ink channel is asserted by LUMINANCE, not by identity with a
        // palette constant: the claim this drill has to defend is "you can
        // see which rows you have opened", and only a measured gap says that.
        // The weight-only version passed its own assertion and failed the
        // user on sight (13 Aug), so the assertion moved to the quantity the
        // eye actually uses.
        let unreadL = label("unread")?.textColor.map(StateLegend.Measure.relativeLuminance) ?? 0
        let openedL = label("opened")?.textColor.map(StateLegend.Measure.relativeLuminance) ?? 0
        let workingUnreadL = label("w-unread")?.textColor
            .map(StateLegend.Measure.relativeLuminance) ?? 0
        let workingOpenedL = label("w-opened")?.textColor
            .map(StateLegend.Measure.relativeLuminance) ?? 0
        let idleL = label("idle")?.textColor
            .map(StateLegend.Measure.relativeLuminance) ?? 0
        SelfTest.report("readIntensity", [
            // The AmberConsole law, asserted so it cannot rot back: NO row
            // is bold. The panel broke this quietly for the grid's whole
            // life and nobody noticed until it was asked to carry meaning.
            ("nothingIsBold", built.allSatisfy {
                $0.nameLabel.font == ChromeType.mono(ofSize: 13, weight: .medium) }),
            ("unreadIsBrightest", unreadL > openedL && unreadL > idleL),
            // Idle and opened rest at ONE level — "the idle sessions should
            // not be brighter than read active sessions" (16 Aug). Equality
            // is the claim, so equality is what is measured.
            ("idleRestsWithOpened", abs(idleL - openedL) < 0.0001),
            ("dimmingIsVisible", unreadL > 0 && (unreadL - openedL) / unreadL > 0.15),
            ("openedIsNotDead", unreadL > 0 && (unreadL - openedL) / unreadL < 0.40),
            ("unreadLampIsSolid", solid("unread") && solid("w-unread")),
            ("openedLampIsHollow", hollow("opened")),
            // Advisory blue carries NO read state: never hollow, never at
            // attention ink, whichever side of read it is on. The legend
            // calls it "news, nothing for you to do"; the panel has to agree.
            ("advisoryIsNeverHollow", solid("w-unread") && solid("w-opened")),
            ("advisoryAlwaysRests",
             abs(workingUnreadL - openedL) < 0.0001 && abs(workingOpenedL - openedL) < 0.0001),
            // An idle row keeps its own lamp: hollowing it would claim it had
            // been read, which is a thing that never happened to it.
            ("idleLampIsUntouched", solid("idle")),
            ("allRendered", built.count == 5),
            // ...and they still reach a face between them: the lit four on the
            // grid, the idle one in the list.
            ("theIdleRowLandsInTheList",
             !Self.gridRows(items).contains { $0.id == "idle" }
                && Self.pastAgents(items).contains { $0.id == "idle" }),
            ("theLitRowsLandOnTheGrid", Self.gridRows(items).count == 4),
        ])
        showIdle(rows: [])
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

    /// A card's prose is selectable, and selects itself never.
    ///
    /// The 16 Aug screenshot: a card came back from a turn with its whole body
    /// highlighted, in a light-grey band that put `ink` at 1.23:1 — text and
    /// selection both, unreadable, and untouched by any hand. Two independent
    /// faults, so two independent halves here.
    ///
    /// The panel cannot be photographed by a drill, so the second half is
    /// asserted where it is caused: the panel's declared appearance. `.aqua` on
    /// a dark console is what dressed the selection band for a light ground.
    private func selectionDrill() {
        var checks: [(String, Bool)] = []
        currentTarget = ("drill", 1, "promotions")
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("The poller is fixed. Go?"),
            sessionId: "drill", pid: 1, project: "promotions", cwd: "/tmp")

        // Nothing selects itself. Both halves: no field editor is installed, and
        // asking for one the way the window does on becoming key is refused.
        checks.append(("aCardArrivesUnselected", bodyLabel.currentEditor() == nil))
        checks.append(("noSelection", !bodyLabel.hasSelection))
        if let panel {
            _ = panel.makeFirstResponder(bodyLabel)
            checks.append(("theWindowCannotHandItTheKeyboard",
                           bodyLabel.currentEditor() == nil))

            let inside = bodyLabel.convert(
                NSPoint(x: bodyLabel.bounds.midX, y: bodyLabel.bounds.midY), to: nil)
            func press(at point: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let tab = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\t",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
            // The gate, in all four directions. The third and fourth are the
            // ones that were failing: the window picks a first responder on
            // becoming key with no mouse event at all, and Tab walks the key
            // view loop into any selectable field.
            checks.append(("aPressOnTheWordsSelects", bodyLabel.acceptsPress(press(at: inside))))
            checks.append(("aPressElsewhereDoesNot",
                           !bodyLabel.acceptsPress(press(at: NSPoint(x: -80, y: -80)))))
            checks.append(("noEventDoesNot", !bodyLabel.acceptsPress(nil)))
            checks.append(("theKeyboardDoesNot", !bodyLabel.acceptsPress(tab)))
        }

        // A hand-made selection survives a repaint that changed only the ink —
        // the karaoke cursor rewrites this label once per spoken word — and is
        // dropped the moment the WORDS change, because it is then a selection
        // of text that is no longer there.
        bodyLabel.selectText(nil)
        let madeByHand = bodyLabel.hasSelection
        paintInkForTesting(displayCursor: 4)
        checks.append(("aRepaintKeepsIt", madeByHand && bodyLabel.hasSelection))
        bodyLabel.stringValue = "A different turn, with different words in it."
        checks.append(("newWordsDropIt", !bodyLabel.hasSelection))
        checks.append(("andGiveTheKeyboardBack", bodyLabel.currentEditor() == nil))

        // The cause of the unreadable band. `.aqua` was pinned when the console
        // was light putty and did not follow it into the dark (09 Aug).
        checks.append(("panelIsDressedForItsOwnSurface",
                       panel?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))

        SelfTest.report("selection", checks)
        showIdle(rows: [])
    }

    /// Every control answers the pointer, and answers it the same way.
    ///
    /// The standard is docs/ruling-the-panel-answers-the-pointer.md, written
    /// after the panel was measured against its own inventory: two cursor rects
    /// in the
    /// whole app, and sixteen buttons that looked exactly like the prose beside
    /// them until you clicked one.
    ///
    /// The drill asserts the STANDARD, not the call sites: that every control
    /// is a `ConsoleButton` (which is where the cursor rect lives, so being one
    /// IS rule 1), that its hover ink is a real step away from its resting ink
    /// and clears the text floor, and that nothing rests at `ink` — rule 4,
    /// which is the rule a new button is most likely to break, because `ink` is
    /// the obvious colour to reach for and it is the one colour with no answer
    /// to the pointer.
    private func hoverDrill() {
        var checks: [(String, Bool)] = []
        let controls: [(String, ConsoleButton?)] = [
            ("go", goButton), ("openPage", openPageButton), ("gear", gearButton),
            ("collapse", collapseButton), ("back", backButton),
            ("pastBack", pastBackButton), ("dontSend", dontSendButton),
            ("micSettings", micSettingsButton), ("newSession", newSessionButton),
            ("cancelTranscription", cancelTranscriptionButton),
            ("retryTranscription", retryTranscriptionButton),
        ]
        for (name, control) in controls {
            guard let control, let resting = control.restingInk else {
                checks.append(("\(name)Exists", control != nil))
                continue
            }
            guard let hover = control.hoverInkForTesting else { continue }
            // Rule 4 first: at `ink` the ramp has no step, and `hovered`
            // answers with the resting colour to say so.
            checks.append(("\(name)RestsBelowInk", resting != StateLegend.Palette.ink))
            checks.append(("\(name)StepsOnHover", hover != resting))
            // Not a fixed floor — a hover owes what its rest owes (see
            // `contrastFloors`). What it must never do is make a control
            // HARDER to read at the moment somebody is pointing at it, and
            // that is the invariant worth pinning.
            checks.append(("\(name)HoverIsMoreLegibleThanRest",
                           StateLegend.Measure.contrast(hover, StateLegend.Palette.surface)
                           > StateLegend.Measure.contrast(resting, StateLegend.Palette.surface)))
            control.setHoveringForTesting(true)
            let lit = control.currentInkForTesting
            control.setHoveringForTesting(false)
            let unlit = control.currentInkForTesting
            checks.append(("\(name)WearsIt", lit == hover && unlit == resting))
        }

        // The step function itself, over every ink anything actually rests at
        // — including the three the old ramp could not answer (the pill's
        // amber, the go-green, and `ink`, which is the card's title).
        //
        // Two properties, and the second is the one a fraction-based step
        // silently loses: every lift is the SAME perceptual distance, and it is
        // far enough to see. The lamps' own floor is ΔL* 6.0, from 4.2
        // measuring invisible at 9px; text is bigger, so the step is 8 and the
        // drill accepts a point of slack either side of it.
        for (name, resting) in [
            ("faint", StateLegend.Palette.faint), ("hint", StateLegend.Palette.hint),
            ("muted", StateLegend.Palette.muted), ("secondary", StateLegend.Palette.secondary),
            ("ink", StateLegend.Palette.ink), ("accent", StateLegend.Palette.accent),
            ("fault", StateLegend.Palette.fault), ("ready", StateLegend.Palette.ready),
        ] {
            let step = StateLegend.Measure.lightnessGap(
                resting, StateLegend.hovered(resting))
            checks.append(("\(name)LiftsOneStep",
                           abs(step - StateLegend.hoverStep) <= 1))
        }
        // Saturation survives the lift, which is what keeps a caution a caution
        // and a go-lamp green. Blending toward `ink` was what broke this.
        func saturation(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            let high = max(c.redComponent, c.greenComponent, c.blueComponent)
            let low = min(c.redComponent, c.greenComponent, c.blueComponent)
            return high == 0 ? 0 : (high - low) / high
        }
        for (name, resting) in [("fault", StateLegend.Palette.fault),
                                ("ready", StateLegend.Palette.ready)] {
            checks.append(("\(name)KeepsItsHue",
                           abs(saturation(resting)
                               - saturation(StateLegend.hovered(resting))) < 0.02))
        }

        SelfTest.report("hover", checks)
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
    /// Nothing a human reads carries an em dash, and every row can be read in
    /// full.
    ///
    /// Ruled 18 Aug, twice in one sentence: "there's no way to see the full
    /// message, the full error, or whatever message is silent for 2h. Get rid
    /// of the fucking em dash. Moreover, if I hover, show me the full message
    /// in a tooltip."
    ///
    /// A sweep of the RENDERED labels rather than a grep of the source, because
    /// the string that reaches the screen is usually assembled from two or three
    /// that do not contain the character on their own — which is also why a
    /// one-off fix to one constant would not have held. Log lines are
    /// deliberately out of scope: they are diagnostics, not copy, and the app's
    /// own log is the one place the dash still earns its keep.
    private func copyDrill() {
        func words(in view: NSView) -> [String] {
            var found: [String] = []
            if let field = view as? NSTextField {
                let text = field.attributedStringValue.string
                if !text.isEmpty { found.append(text) }
            }
            view.subviews.forEach { found += words(in: $0) }
            return found
        }
        // A row whose message is longer than the column, which is the case the
        // hover exists for.
        let message = "silent for 2h, nothing written since it started this"
        let stalled = StateLegend.SessionRow(
            id: "stall", name: "a session name long enough to truncate against the callsign",
            aux: message, lamp: .fault, detail: message)
        showIdle(rows: [stalled, StateLegend.SessionRow(
            id: "ok", name: "quiet one", aux: "ok", lamp: .ready)])
        panel?.contentView?.layoutSubtreeIfNeeded()
        var seen = panel?.contentView.map { words(in: $0) } ?? []
        let gridRow = waitingRows.arrangedSubviews
            .compactMap { $0 as? GridRowView }
            .first { $0.identifier?.rawValue == "stall" }
        let gridTip = gridRow?.toolTip

        // The same row on the other face.
        showPastAgents(items: [PastAgentsList.Item(
            row: stalled, revivable: false, haystack: stalled.name)])
        panel?.contentView?.layoutSubtreeIfNeeded()
        seen += panel?.contentView.map { words(in: $0) } ?? []
        let listTip = pastList.toolTipsForTesting.first
        goHomeFromPastAgents()

        // And the copy that only appears when something goes wrong, which is
        // exactly the copy nobody re-reads.
        seen += [StateLegend.noWordsNotice, StateLegend.slowTranscriptionNote]
        let offenders = seen.filter { $0.contains("\u{2014}") }

        SelfTest.report("copy", [
            ("noEmDashOnScreen", offenders.isEmpty),
            // Named, so a failure says WHICH string rather than sending the
            // next reader back through every face by hand.
            ("offenders", offenders.isEmpty),
            ("theGridRowCarriesItsWholeMessage",
             gridTip?.contains(message) == true),
            ("theListRowCarriesItTheSameWay", listTip?.contains(message) == true),
            ("bothFacesSayTheSameThing", gridTip == listTip),
            // The name is in the hover too: it truncates against the callsign
            // column and was the other half of what could not be read.
            ("theHoverCarriesTheWholeName",
             gridTip?.contains("truncate against the callsign") == true),
        ])
        if !offenders.isEmpty {
            Permissions.log("selftest copy: em dashes in \(offenders.count) string(s): "
                + offenders.prefix(5).joined(separator: " | "))
        }
        showIdle(rows: [])
    }

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
            //
            // The ids are REAL SHAPES, not placeholders. The sections are split on
            // `com.apple.` — the same test the routing uses — so a fixture with
            // "sys1" in it would draw every voice under the ElevenLabs legend and
            // still look fine. That is the pose-that-cannot-fail this comment
            // already warns about, one layer down: the fault moved from the
            // right-hand column to the id.
            showSettings(
                voices: [Voice(id: "XrExE9yKIg1WjnnlVkGX", name: "Archer",
                               category: "professional"),
                         Voice(id: "com.apple.voice.premium.en-US.Ava",
                               name: "Ava (Premium)", category: "479 MB"),
                         Voice(id: "com.apple.speech.synthesis.voice.Alex",
                               name: "Alex", category: "885 MB"),
                         Voice(id: "EGxJIQ5TF187oclOp8aT", name: "My Clone",
                               category: "cloned"),
                         Voice(id: "com.apple.voice.enhanced.en-US.Allison",
                               name: "Allison (Enhanced)", category: "99 MB"),
                         Voice(id: SystemVoiceCatalog.downloadPrefix + "Susan",
                               name: "Susan", category: "132 MB")],
                roster: ["XrExE9yKIg1WjnnlVkGX", "com.apple.voice.premium.en-US.Ava"],
                note: "Every agent gets a voice from each list. ElevenLabs speaks; "
                    + "the system voice is its fallback.",
                tab: .voices)

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
            // `sticky` is in the matrix precisely BECAUSE it is hover-driven:
            // the drill's job is to prove that leaving the grid closes it, and
            // a widget the matrix never names is a residue class nobody can
            // diff for.
            ("footer", gridFooter), ("sticky", controlsSticky),
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

    /// The console panel.
    ///
    /// `.nonactivatingPanel` + `.borderless` means it never becomes key, which
    /// is the entire point everywhere except one place: it must never steal a
    /// keystroke while you are typing in another app. That is also why the
    /// filter field on the list face could not be clicked into — a text field
    /// in a window that cannot become key has nowhere to put first responder,
    /// so the click landed on nothing and the caret never appeared.
    ///
    /// So key status is a state, not a property: the panel accepts it only
    /// while a face has actually asked for typing. Everything else stays
    /// exactly as unstealable as it was.
    final class ConsolePanel: NSPanel {
        var acceptsKey = false
        override var canBecomeKey: Bool { acceptsKey }
        override var canBecomeMain: Bool { false }
    }

    private func build() -> ConsolePanel {
        let panel = ConsolePanel(
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
        // The panel declares the appearance it actually DRAWS, so AppKit's own
        // chrome — bezels, scrollers, menus, and the text-selection band — is
        // drawn for this surface rather than for the system's.
        //
        // This was pinned to `.aqua` when the console was light putty, with a
        // comment whose logic now argues the other way: "a dark-mode bezel on
        // light putty looks like a hole". The console went dark on 09 Aug
        // (docs/ruling-the-console-goes-dark.md) and the pin did not follow, so
        // every AppKit-drawn thing on the panel has been dressed for a light
        // ground on a dark one ever since. Measured 18 Aug on the one that
        // shows: an inactive text selection painted #DCDCDC under `ink`, which
        // is 1.23:1 — the least readable thing the panel has ever drawn, and
        // below every floor in the palette. Under `.darkAqua` the same band is
        // #464646 under white at 9.44:1.
        panel.appearance = NSAppearance(named: .darkAqua)

        // Opaque light console surface, panel-wide (ruled — the blur is dead: an
        // instrument guarantees its own contrast, a blur borrowed the desktop's).
        // Same corner radius, shadow, and non-activating behavior as before.
        // A drag destination rather than a plain view: the whole surface takes
        // files (ruled 15 Aug). Dragging needs no key status, so the panel is
        // exactly as non-activating as it ever was.
        let background = DropSurfaceView(frame: panel.contentView!.bounds)
        background.registerForDraggedTypes(DropSurfaceView.acceptedTypes)
        background.canAccept = { [weak self] in self?.replyTargetForDrop?()?.label }
        background.onDragTargetChanged = { [weak self] target in
            guard let self else { return }
            if let target { dropOverlay.show(target: target) }
            else { dropOverlay.isHidden = true }
        }
        background.onDrop = { [weak self] items in
            guard let self, let accepted = onFilesDropped?(items) else { return false }
            // Repaint on the way out: the chips the drop just created are a
            // render-time read of Core's tray, so the surface only has to say
            // "something changed".
            if accepted { render() }
            return accepted
        }
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
        dropSurface = background

        // Widgets carry no initial visibility: build() is only reached from
        // render(), which writes every widget's visibility before the panel is
        // ever ordered front.
        stateLabel = DoorLabel(labelWithString: "")
        stateLabel.font = ChromeType.mono(ofSize: 10, weight: .medium)
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
        titleLabel.font = ChromeType.mono(ofSize: 13, weight: .semibold)
        titleLabel.textColor = StateLegend.Lens.content.color
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        // The second door to the session. GO TO AGENT stays — it is the
        // discoverable one, and you said you use it. This is the shortcut for
        // when your eye is already on the name, which is where it already goes.
        titleLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(goToSession)))

        bodyLabel = CardBodyLabel(wrappingLabelWithString: "")
        bodyLabel.font = StateLegend.Face.message(12)
        bodyLabel.textColor = StateLegend.Lens.content.color
        bodyLabel.maximumNumberOfLines = 0
        // Selectable so a line can be quoted out of a card by hand; see
        // `CardBodyLabel` for what stops it selecting itself.
        bodyLabel.isSelectable = true

        // Every surviving action is a QUIET text action (ruled): borderless,
        // palette ink, no lozenge. The button rows are dead — chords are the
        // interface; these are the few context actions a face still owns.
        func quietAction(_ title: String, _ action: Selector) -> ConsoleButton {
            let button = ConsoleButton(title: title, target: self, action: action)
            button.isBordered = false
            button.controlSize = .small
            button.font = StateLegend.Face.chrome(11, .medium)
            // Chrome, not `ink` — the hover standard's fourth rule:
            // the brightest ink belongs to the prose, and a control resting
            // there is both louder than the message and out of ramp, with no
            // step left to answer the pointer with. `secondary` is 6.69:1,
            // legible with room to spare, and it steps up to `ink` on hover.
            button.restingInk = StateLegend.Lens.chrome.color
            return button
        }
        // "Go to agent" (ui-pass-7, rulings 1 + 3): the one navigation the
        // panel owns gets presence — go-green palette ink, letterspaced caps
        // like the grid placards, and the action row's right edge to itself.
        // Still flat, no lozenge: promotion by ink and placement, not chrome.
        goButton = ConsoleButton(title: "Go to agent", target: self,
                                 action: #selector(goToSession))
        goButton.isBordered = false
        goButton.restingInk = StateLegend.Palette.accent
        goButton.wordmark = "\(StateLegend.goToAgentTitle) \(StateLegend.Glyph.forward)"
        // The second door shares "Go to agent"'s treatment — same kind of
        // move, leave this panel and go to the thing — and differs only in
        // destination: one is a terminal tab, the other a browser. It sits at
        // the row's LEADING edge rather than beside it: the two doors bracket
        // the card, so neither reads as the primary and a mis-click lands on
        // nothing. The title here is a placeholder; render() sets the real
        // label per card — OPEN REPORT when this turn wrote a page, OPEN HUB
        // otherwise — because the label follows the destination (ruled 15 Aug).
        openPageButton = ConsoleButton(title: "Open hub", target: self,
                                       action: #selector(openHubTapped))
        openPageButton.isBordered = false
        openPageButton.restingInk = StateLegend.Palette.accent
        openPageButton.wordmark = "\(StateLegend.openHubTitle) \(StateLegend.Glyph.forward)"
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
        gearButton = ConsoleButton(image: NSImage(systemSymbolName: "gearshape",
                                                  accessibilityDescription: "Settings")!
                                     .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))!,
                                  target: self, action: #selector(gearTapped))
        gearButton.isBordered = false
        gearButton.restingInk = StateLegend.Lens.chrome.color
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        gearButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        gearButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        // A breadcrumb, not a button in a row of actions: it says where you are and
        // the only way out is back the way you came.
        backButton = ConsoleButton(title: StateLegend.backTitle, target: self,
                                   action: #selector(backTapped))
        backButton.isBordered = false
        backButton.controlSize = .small
        backButton.font = StateLegend.Face.chrome(11, .medium)
        // The ‹ is a mark beside a word, so it goes through the same composer
        // as every other one rather than sitting on the baseline where the
        // font left it. `reink` because a ConsoleButton repaints by rebuilding
        // its title, and this title is attributed.
        backButton.reink = { [weak backButton] color in
            backButton?.attributedTitle = ChromeType.line(
                StateLegend.backTitle, font: StateLegend.Face.chrome(11, .medium),
                color: color)
        }
        backButton.restingInk = StateLegend.Lens.chrome.color

        // Surfaced only once a transcription has run long enough to deserve them
        // (sanctioned change: open issue #4). Quiet text, like their row-mates.
        cancelTranscriptionButton = quietAction(StateLegend.cancelTranscriptionTitle,
                                                #selector(cancelTranscriptionTapped))
        retryTranscriptionButton = quietAction(StateLegend.retryTranscriptionTitle,
                                               #selector(retryTranscriptionTapped))

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = StateLegend.Face.chrome(10)
        hintLabel.textColor = StateLegend.Lens.guidance.color

        // Quiet context actions keep the left edge; GO TO AGENT holds the
        // right edge alone (ui-pass-7, ruling 3). The row spans the content
        // column below, so the trailing gravity is a real edge.
        let buttons = NSStackView()
        actionRow = buttons
        buttons.orientation = .horizontal
        buttons.spacing = 12
        // Air above the bottom line (ruled 18 Aug: "the controls seems a little
        // too cramped relative to the text above"). The stack's own 6pt row gap
        // is right between rows of the same kind — two labels, a rule and a
        // label — and too tight under the last line of a card, where what
        // follows is not more of the message but the things you can DO about
        // it. Doubling it to 12 gives that row the same air the panel gives its
        // own edges. Carried by the row rather than by custom spacing after the
        // body, because the view above it differs by face and a hidden one
        // takes its spacing with it.
        buttons.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        buttons.addView(openPageButton, in: .leading)
        buttons.addView(dontSendButton, in: .leading)
        buttons.addView(micSettingsButton, in: .leading)
        buttons.addView(newSessionButton, in: .leading)
        buttons.addView(cancelTranscriptionButton, in: .leading)
        buttons.addView(retryTranscriptionButton, in: .leading)
        buttons.addView(goButton, in: .trailing)
        // The middle, which is the only space a card's bottom line has left and
        // the same place the grid puts it.
        cardControls = ControlsWordView()
        buttons.addView(cardControls, in: .center)
        // And the row is exactly as tall as its contents: BOTH directions.
        //
        // Hugging alone was not enough and the difference is the whole bug.
        // Hugging resists growing, so it stopped the row ballooning around a
        // correctly-sized word — measured, that took the flip from 3-in-6 to
        // 2-in-12 and no further. What remained was the row being SQUEEZED:
        // compression resistance is what defends the 6pt top inset, and without
        // it the stack could take that inset back whenever it wanted the space,
        // landing the row at 25pt instead of 32 and the air at 8.5 instead of
        // the ruled 12. A quantity you can only have when nothing else wants it
        // is not a guarantee.
        buttons.setContentHuggingPriority(.defaultHigh, for: .vertical)
        buttons.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        // And the air itself is PINNED, not inferred.
        //
        // The two priorities above took the flip from 3-in-6 to 1-in-12 and
        // stopped there, which is the tell: priorities move the odds, they do
        // not remove the freedom. The stack centres a `.center` view in
        // whatever height it ends up with, so the word's distance from the row
        // top was always a consequence of other things rather than a fact.
        //
        // Now it is the fact: 6pt below the row's top edge, which is the row's
        // own inset, on top of the stack's 6pt spacing above the row. 12,
        // always, by construction — the number the 18 Aug ruling asked for
        // ("doubling it to 12 gives that row the same air the panel gives its
        // own edges") and never reliably got.
        cardControls.topAnchor.constraint(
            equalTo: buttons.topAnchor, constant: 6).isActive = true

        hintLabel.maximumNumberOfLines = 0
        hintLabel.lineBreakMode = .byTruncatingMiddle

        // The strip's own furniture. The rule is what makes the capture read as
        // an extension of the panel rather than another paragraph of the card —
        // and it is hidden with the label, so a face with no capture has no
        // orphan line across it.
        stripLabel = NSTextField(labelWithString: "")
        // Chrome: the strip is the machine reporting on itself — the mic, the
        // transcription, the send. The readback rides it too, and mono is right
        // for that as well: those words are about to be TYPED into a terminal,
        // and this is the last look at them.
        stripLabel.font = StateLegend.Face.chrome(11)
        stripLabel.textColor = StateLegend.Palette.hint
        stripLabel.maximumNumberOfLines = 2
        stripLabel.lineBreakMode = .byTruncatingHead
        stripRule = NSView()
        stripRule.wantsLayer = true
        stripRule.layer?.backgroundColor = StateLegend.Palette.hairline.cgColor
        stripRule.translatesAutoresizingMaskIntoConstraints = false
        stripRule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        trayRow = TrayRowView()
        trayRow.onRemove = { [weak self] path in
            guard let self, let session = currentTarget?.sessionId else { return }
            onUnstage?(session, path)
            Permissions.log("tray: unstaged \((path as NSString).lastPathComponent)")
            render()
        }

        gridFooter = GridFooterView(width: Self.gridWidth)
        controlsSticky = ControlsNoteView()
        controlsSticky.isHidden = true
        gridFooter.onControlsHover = { [weak self] hovering in
            guard let self else { return }
            setControlsNote(open: hovering, above: gridFooter)
        }
        gridFooter.onWordmark = { [weak self] in self?.onOpenRepository?() }
        cardControls.onHover = { [weak self] hovering in
            guard let self else { return }
            setControlsNote(open: hovering, above: actionRow)
        }

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

        // How agents start, in the pane where settings live (ruled 15 Aug).
        // One pair of values for the whole machine — "a global setting for now
        // and see if we need more granular later" — read by every path that
        // starts an agent: the menu item, the grid's + row, and revival.
        settingsTabs = SettingsTabBar(width: Self.gridWidth)
        settingsTabs.isHidden = true
        settingsTabs.onSelect = { [weak self] tab in self?.showSettingsTab(tab) }

        launchRow = SettingRowView(width: Self.gridWidth, label: "LAUNCH",
                                   placeholder: AgentDefaults.fallback)
        launchRow.onCommit = { AgentDefaults.save($0) }
        directoryRow = SettingRowView(width: Self.gridWidth, label: "DIRECTORY",
                                      placeholder: AgentDefaults.fallbackDirectory,
                                      browsable: true)
        directoryRow.onCommit = { AgentDefaults.save(directory: $0) }
        directoryRow.onBrowse = { [weak self] in self?.pickAgentDirectory() }
        launchRow.isHidden = true; directoryRow.isHidden = true

        pastList = PastAgentsList(width: Self.gridWidth, height: 420)
        pastList.isHidden = true
        // One tap, the row's own verb. Dead comes back; live is picked up.
        //
        // Ruled 19 Aug, on a click that jumped him to a terminal he had not
        // asked for: *"when I click on an idle agent … it should turn the lamp
        // on, open the agent card. Because it's alive, clicking on it obviously
        // means I want it to be alive. It doesn't need to go to it — maybe
        // that's a right-click behaviour."* So GO TO AGENT moved to the menu,
        // where END SESSION already lives, and the tap now does the two things
        // picking a session up means: it lights the lamp, which is what puts
        // the row back on the grid, and it opens the agent's card.
        //
        // Order matters. The switch is written BEFORE the card is asked for,
        // so the repaint the card triggers already knows this row is on.
        pastList.onPick = { [weak self] id, revivable in
            guard let self else { return }
            let name = pastListName(id)
            onBreadcrumbHome?()
            guard !revivable else { onRevive?(id, name); return }
            onRestoreLamp?(id)
            onPickWaiting?(id)
        }
        // The lamp, on this face too, and through the same function — so the
        // dot means one thing wherever you meet it (ruled 18 Aug).
        pastList.onLamp = { [weak self] row in
            guard let self else { return }
            // Home first in both cases, and for the same reason: the click's
            // whole point is that the row leaves this face. Staying on a list
            // to watch a row disappear from it is the panel showing you the
            // bookkeeping instead of the result.
            onBreadcrumbHome?()
            switch StateLegend.lampAction(for: row, on: .list) {
            case .turnOn: onRestoreLamp?(row.id)
            case .revive: onRevive?(row.id, row.name)
            case .turnOff:
                Permissions.log("list: row \(row.id.prefix(8)) asked for turnOff "
                    + "in the list — the face and the verb have come apart")
            }
        }
        pastList.onGoTo = { [weak self] id in
            guard let self else { return }
            onBreadcrumbHome?()
            onGoToSession?(id)
        }
        pastList.onTerminate = { [weak self] id, name in
            self?.onTerminateSession?(id, name)
        }
        pastList.onFilterChanged = { [weak self] in
            guard let self, case .pastAgents = state else { return }
            hintLabel.stringValue = pastList.summary
        }
        waitingRows = NSStackView()
        waitingRows.orientation = .vertical
        waitingRows.alignment = .leading
        waitingRows.spacing = 2

        // The strip's furniture sits BELOW the body and above the meter, so a
        // capture extends the panel downward and the card above it does not
        // move (ruled 10 Aug: "extend below, not move everything down by
        // inserting above"). The panel already grows this way — `position`
        // anchors the top edge — so the strip costs no geometry work.
        // The tray sits UNDER the capture strip and above the countdown: the
        // strip is what the microphone is doing, the chips are what will go
        // with it, and the readback that names them both renders in the strip
        // directly above. Same downward-growth as the strip — a drop extends
        // the panel, it never moves the card.
        let stack = NSStackView(views: [backButton, stateLabel, titleLabel,
                                        waitingRows, pastList, bodyLabel,
                                        stripRule, stripLabel, trayRow, gridFooter,
                                        countdownBar, meter,
                                        settingsTabs, launchRow, directoryRow,
                                        voiceList, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        assert(stack.edgeInsets.left == StatusHUD.contentColumn)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        background.addSubview(gearButton)
        // Above everything: the sticky overlays the last grid rows on purpose.
        // It has no constraint to the background's own edges, so it contributes
        // nothing to the fitting size resizeToFit() measures — the panel is
        // exactly as tall with the note open as with it shut.
        background.addSubview(controlsSticky, positioned: .above, relativeTo: nil)
        // No placement here: `setControlsNote(open:above:)` hangs it over
        // whichever row owns the word at the moment it is asked for.

        // Above everything, pinned to the panel's own edges rather than to the
        // stack: it covers whatever face is up, and — like the sticky — it is
        // outside the stack, so it contributes nothing to the fitting size
        // resizeToFit measures. The panel does not change size when a drag
        // arrives, which is the whole point of an overlay over a row.
        dropOverlay = DropOverlayView()
        background.addSubview(dropOverlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            dropOverlay.topAnchor.constraint(equalTo: background.topAnchor),
            dropOverlay.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        // Collapse lives on the panel, left of the gear. It was in the menu bar
        // first, which was wrong twice over: clicking the status item already
        // opens the panel, so "Show panel" was a second door to one room, and a
        // control for shrinking the panel belongs on the panel rather than two
        // clicks away in a menu you have to know is there.
        collapseButton = ConsoleButton(
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
        collapseButton.restingInk = StateLegend.Lens.chrome.color
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        collapseButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        background.addSubview(collapseButton)
        // The list face's way back, in the SAME lane as the collapse chevron so
        // its header is one row like the grid's: a chevron, the placard, the
        // gear. Ruled 12 Aug — the separate "‹ Back" button above the placard
        // made the list two rows deep where the grid is one, and the two faces
        // stopped rhyming.
        pastBackButton = ConsoleButton(
            image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))!,
            target: self, action: #selector(backTapped))
        pastBackButton.isBordered = false
        pastBackButton.restingInk = StateLegend.Lens.chrome.color
        pastBackButton.translatesAutoresizingMaskIntoConstraints = false
        pastBackButton.isHidden = true
        background.addSubview(pastBackButton)
        NSLayoutConstraint.activate([
            pastBackButton.widthAnchor.constraint(equalToConstant: 26),
            pastBackButton.heightAnchor.constraint(equalToConstant: 26),
            pastBackButton.centerYAnchor.constraint(equalTo: gearButton.centerYAnchor),
            pastBackButton.leadingAnchor.constraint(
                equalTo: background.leadingAnchor,
                constant: StatusHUD.contentColumn - pastBackButton.inkOverhang.leading),
        ])
        NSLayoutConstraint.activate([
            collapseButton.centerYAnchor.constraint(equalTo: gearButton.centerYAnchor),
            // FAR LEFT, not beside the gear. The top-right of the panel is the
            // receipt's — "→ SENDING", "▶ SENT" — and a second control parked
            // there is a collision waiting for the next send, which is exactly
            // what it looked like. The two corners now own one thing each.
            // The MARK on the content column, not the box on some other
            // number. The rules and the rows below establish the column at 14
            // and paint to it exactly; the chevron's box was pinned at 10 and
            // its 9pt glyph landed at 21, so the header read 7pt narrower than
            // every row under it — visibly, because the hairline directly below
            // spans the full width and acts as a ruler (measured 19 Aug,
            // reported 20 Aug: "the rows of agents' widths expand beyond the
            // top bar a little bit").
            collapseButton.leadingAnchor.constraint(
                equalTo: background.leadingAnchor,
                constant: StatusHUD.contentColumn - collapseButton.inkOverhang.leading),
        ])
        // Held, so collapsing can DEACTIVATE them. The stack pins the panel to
        // 380pt through these; leaving them active while narrowing the window is
        // what snapped the frame back to 380 and threw it off the display.
        // The bottom pin yields; the top pin never does. While the grow
        // animation is in flight the content is briefly taller than the panel,
        // and with four REQUIRED pins autolayout must break one — in practice
        // the top, which shoved the card off the top edge and floated it back
        // down as the panel caught up (12 Aug, the readback tray landing).
        // At 500 the bottom pin is the designated loser: the card stays nailed
        // to the top edge and the new strip content waits below the bottom
        // edge for the panel to grow over it — the tray slides out from under
        // the panel instead of displacing the card. 500 still beats the
        // stack's vertical hugging (250), so a panel taller than its content
        // stretches the stack to the bottom edge exactly as before.
        let stackBottom = stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        stackBottom.priority = NSLayoutConstraint.Priority(500)
        stackEdges = [
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stackBottom,
        ]
        NSLayoutConstraint.activate(stackEdges + [
            bodyLabel.widthAnchor.constraint(equalToConstant: 348),
            hintLabel.widthAnchor.constraint(equalToConstant: 348),
            stripLabel.widthAnchor.constraint(equalToConstant: 348),
            stripRule.widthAnchor.constraint(equalToConstant: 348),
            titleLabel.widthAnchor.constraint(equalToConstant: 348),
            stateLabel.widthAnchor.constraint(equalToConstant: 348),
            // Same margin as every text row, so the eye reads one column.
            gearButton.trailingAnchor.constraint(
                equalTo: background.trailingAnchor,
                constant: -(StatusHUD.contentColumn - gearButton.inkOverhang.trailing)),
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

    /// True while a "go to session" jump is in flight. Re-clicks on a stalled
    /// jump were how one slow osascript became eleven hang reports (issue 14):
    /// each click queued another synchronous walk behind the first.
    private var goToSessionInFlight = false

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
    @objc nonisolated private func goToSession() {
        MainActor.assumeIsolated {
            guard !goToSessionInFlight else { return }
            guard let pid = currentTarget?.pid else {
                bodyLabel.stringValue = "That agent is no longer running, so there's no tab to open."
                return
            }
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

    /// One tap, two verbs, and the row decides which.
    ///
    /// A live row is answered; a row whose session has exited is brought back.
    /// The branch is on the ROW rather than on the lamp alone, because
    /// `revivable` carries the guard that matters: an unlit row whose liveness
    /// was merely unprovable offers nothing, and tapping it must do nothing
    /// rather than announce a session that is not there.
    @objc nonisolated private func sessionRowTapped(_ sender: NSControl) {
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
/// A placard: the state's mark and its word, on one line.
///
/// Every mark is centred on the cap line by measurement (`ChromeType`), not by
/// a per-glyph nudge. The old version carried `baselineOffset: 0.8` for `◀`
/// alone — 0.67pt low, measured — and nothing at all for `⚠`, `→` or the
/// chevrons, half of which are not even in the monospaced font and are drawn by
/// a fallback face with its own metrics.
///
/// The marks stay three-quarters of the text size: a state mark is a
/// punctuation-weight thing beside its word, not a second word. Only its
/// POSITION was ever wrong.
private func placardText(
    _ text: String, color: NSColor = StateLegend.Lens.chrome.color
) -> NSAttributedString {
    ChromeType.line(text, font: StateLegend.placardFont, color: color, markScale: 0.68)
}

func letterspaced(_ text: String, size: CGFloat, tracking: CGFloat,
                          color: NSColor, headIndent: CGFloat = 0) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [
        // Chrome, like everything else that names rather than says (ruled
        // 18 Aug). This was the system font, which is why AGENTS and NEW AGENT
        // read as visitors on a monospaced panel — the letterspacing was doing
        // the work of looking deliberate while the face disagreed with every
        // row beneath it.
        .font: StateLegend.Face.chrome(size),
        .kern: tracking,
        .foregroundColor: color,
    ]
    // For a placard that shares its row with a control to its LEFT (the list
    // face's back chevron): the label's frame still spans the row, but the
    // text starts clear of the control. An indent in the string rather than a
    // second leading constraint, because the label lives in the content stack
    // and its frame is not this call's to move (observed 13 Aug: the chevron
    // painted over "PAST AGENTS"'s first glyphs).
    if headIndent > 0 {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = headIndent
        style.headIndent = headIndent
        attributes[.paragraphStyle] = style
    }
    return NSAttributedString(string: text, attributes: attributes)
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
/// The panel's whole surface, as a drag destination.
///
/// The surface, not a well: ruled 15 Aug — "the whole UI should be
/// draggable". A target zone would be one more thing to aim at on a panel
/// whose entire premise is that you are not looking at it carefully, and the
/// panel has nothing else a drag could mean.
///
/// Dragging needs neither key status nor activation, which is why this
/// feature costs the away-channel nothing: `.nonactivatingPanel` stays
/// exactly as unstealable as it was, and no gesture changes meaning.
final class DropSurfaceView: NSView {
    /// Who would receive a drop right now, or nil to refuse the drag. Asked
    /// on entry rather than assumed: a drag invited onto a panel with no
    /// resolvable session is a promise the app cannot keep, and "drop here"
    /// followed by "nothing to reply to" is worse than no invitation at all.
    var canAccept: (() -> String?)?
    var onDrop: (([StatusHUD.DroppedItem]) -> Bool)?
    /// Nil = the drag left or landed; non-nil = it is over us, addressed to
    /// this label.
    var onDragTargetChanged: ((String?) -> Void)?

    /// Everything a drop can carry that we know what to do with. Registered
    /// once at build; `.fileURL` covers Finder and most apps, the image types
    /// cover a drag straight out of a browser, which carries no file at all.
    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .tiff, .png]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let target = canAccept?(), !items(from: sender).isEmpty else {
            onDragTargetChanged?(nil)
            return []
        }
        onDragTargetChanged?(target)
        return .copy
    }

    /// AppKit asks this repeatedly while the pointer moves inside us. It must
    /// keep returning `.copy` or the cursor reverts to the no-drop badge
    /// halfway across the panel, which reads as "this bit is not a target".
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept?() == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragTargetChanged?(nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        // The overlay's one guaranteed teardown. `draggingExited` does NOT
        // fire when a drop is performed, and a dropped file that left the
        // invitation on screen would look like the drop never took.
        onDragTargetChanged?(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canAccept?() != nil && !items(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let dropped = items(from: sender)
        guard !dropped.isEmpty else { return false }
        return onDrop?(dropped) ?? false
    }

    /// Files first, bitmap second. A Finder drag advertises both a file URL
    /// and a preview image; taking the image would copy a file that already
    /// has a perfectly good path, and hand the session a name like
    /// "pasted-3f2a.png" instead of its own.
    private func items(from sender: any NSDraggingInfo) -> [StatusHUD.DroppedItem] {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { .file($0.path) }
        }
        // A drag with no file behind it: PNG if offered, else the TIFF every
        // AppKit drag carries, re-encoded so what lands on disk is a format
        // anything downstream can open.
        if let png = board.data(forType: .png) {
            return [.imageData(png, suggestedName: "png")]
        }
        if let tiff = board.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [.imageData(png, suggestedName: "png")]
        }
        return []
    }
}

/// The drop tray's chips: one row per staged file, above the action row.
///
/// A vertical list rather than wrapped pills, for the reason the grid is a
/// list: filenames are long and a wrapped row reflows unpredictably as the
/// set changes, while rows only ever grow downward — the geometry the panel
/// already handles by anchoring its top edge.
final class TrayRowView: NSStackView {
    /// Per-path, never clear-all (a cross that took files you did not point
    /// at is the surprise this whole feature exists to avoid).
    var onRemove: ((String) -> Void)?

    /// What is drawn right now, so `apply` can skip identical repaints —
    /// render() runs on every tick and rebuilding subviews under the pointer
    /// would kill the hover state on the ✕ you are reaching for.
    private(set) var paths: [String] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ next: [String]) {
        guard next != paths else { return }
        paths = next
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for path in next {
            let row = ChipRow(path: path)
            row.onRemove = { [weak self] in self?.onRemove?(path) }
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 348).isActive = true
        }
    }

    /// For the drill: the names as drawn, not the paths handed in.
    var displayedNamesForTesting: [String] {
        arrangedSubviews.compactMap { ($0 as? ChipRow)?.displayName }
    }

    var removeButtonsForTesting: [ConsoleButton] {
        arrangedSubviews.compactMap { ($0 as? ChipRow)?.removeButton }
    }

    private final class ChipRow: NSView {
        var onRemove: (() -> Void)?
        let displayName: String
        let removeButton: ConsoleButton

        init(path: String) {
            displayName = (path as NSString).lastPathComponent
            removeButton = ConsoleButton(title: StateLegend.Glyph.denied,
                                         target: nil, action: nil)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            // The paperclip is the one glyph here that is not from the state
            // legend: the legend's marks all mean something about a SESSION,
            // and a staged file is a fact about the message instead.
            // ONE label, mark and name together, so `ChromeType.line` centres
            // the ▣ on the name's cap line by measurement. It used to be its
            // own text field pinned with `centerY`, which centres two FRAMES —
            // ascender to descender — and left the mark visibly low. A mark in
            // its own view is a mark nobody is measuring.
            let name = NSTextField(labelWithString: "")
            let markRun = ChromeType.line("▣ ", font: ChromeType.mono(ofSize: 10, weight: .regular),
                                          color: StateLegend.Lens.chrome.color)
            let nameRun = NSAttributedString(
                string: displayName,
                attributes: [.font: ChromeType.mono(ofSize: 10.5, weight: .regular),
                             .foregroundColor: StateLegend.Lens.content.color])
            let composed = NSMutableAttributedString(attributedString: markRun)
            composed.append(nameRun)
            name.attributedStringValue = composed
            name.lineBreakMode = .byTruncatingMiddle
            name.maximumNumberOfLines = 1
            // Middle truncation, and it must actually happen: a long filename
            // otherwise stretches the row past the panel and the ✕ leaves the
            // screen — the control you need most when a drop was wrong.
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            name.translatesAutoresizingMaskIntoConstraints = false

            removeButton.isBordered = false
            removeButton.font = ChromeType.mono(ofSize: 10, weight: .medium)
            // The one control on the panel that already advertised itself (it
            // has carried a pointing hand since the tray shipped), so it is the
            // one that must not be the exception now there is a standard.
            removeButton.reink = { [weak removeButton] color in
                removeButton?.attributedTitle = NSAttributedString(
                    string: StateLegend.Glyph.denied,
                    attributes: [
                        .font: ChromeType.mono(ofSize: 10, weight: .medium),
                        .foregroundColor: color,
                    ])
            }
            removeButton.restingInk = StateLegend.Lens.chrome.color
            removeButton.target = self
            removeButton.action = #selector(removeTapped)
            removeButton.translatesAutoresizingMaskIntoConstraints = false

            addSubview(name); addSubview(removeButton)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 16),
                name.leadingAnchor.constraint(equalTo: leadingAnchor),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                name.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor,
                                               constant: -6),
                removeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
                removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                removeButton.widthAnchor.constraint(equalToConstant: 16),
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func removeTapped() { onRemove?() }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(removeButton.frame, cursor: .pointingHand)
        }
    }
}

/// The drop invitation: the whole surface, one sentence, shown only while a
/// drag is actually over the panel.
///
/// It covers the panel rather than joining the content stack on purpose. A
/// row appearing mid-drag would resize the window under the pointer, which
/// is reflow-on-hover — the same thing the collapsed strip's sticky note is
/// forbidden from doing, and worse here because the drag would land
/// somewhere other than where it was aimed.
final class DropOverlayView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The console surface at near-full opacity, so the card underneath
        // reads as covered rather than as competing with the message.
        layer?.backgroundColor = StateLegend.Palette.surface.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = StateLegend.Palette.hairline.cgColor

        label.font = ChromeType.mono(ofSize: 11, weight: .medium)
        label.textColor = StateLegend.Lens.content.color
        label.alignment = .center
        // Wraps rather than clips. With both edges pinned, wrapping is what
        // turns "too long" into "two lines" instead of "cut off mid-word" —
        // the shipped sentence never needs it, and that is the point: the
        // layout stops depending on the sentence.
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        // The sentence may never set the panel's width.
        //
        // Pinning both edges stopped the text running off the side and handed
        // the problem to the other end of the same wire: a label that refuses to
        // be narrower than its own text, inside an overlay pinned to all four
        // edges of the panel, is a required FLOOR under the window's width. A
        // window whose content view carries one does not go below it whatever
        // frame it is handed — so the 40pt collapsed column came out 200pt wide,
        // measured, within an hour of the invitation shipping (16 Aug). Hiding
        // the overlay does not help: a hidden view still holds its constraints,
        // and the label keeps its last string forever.
        //
        // Dropping the resistance rather than clearing the string on hide: the
        // width must not depend on remembering to blank a label, and with
        // wrapping already on, "too narrow" resolves as more lines instead of a
        // wider panel. The panel sizes the label; the label never sizes the
        // panel.
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Pinned on BOTH sides, not centred against one. A single
        // greater-than-or-equal leading pin lets a label wider than the panel
        // grow off the right edge while its centre stays put, which is
        // precisely what shipped: the destination's name ran past the corner
        // radius with no way to read the end of it. Two pins plus wrapping
        // make an overflowing string impossible by construction rather than
        // by keeping the text short enough — the text can now be anything.
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One fixed sentence, no destination name (ruled 16 Aug, from seeing it:
    /// "the message of the current agent is unnecessary in the drop screen
    /// and goes off the side").
    ///
    /// The name was here to catch a drop aimed at the wrong agent. In
    /// practice it could not do that job: the invitation covers the card, so
    /// the name it printed was the only identity on screen and there was
    /// nothing to check it against — an assertion, not a confirmation. The
    /// check that works is the one after the drop, where the chip sits under
    /// the card whose title names the agent, and the readback says what is
    /// riding before anything is sent.
    ///
    /// `target` is still taken and still required to be non-nil upstream: a
    /// drag with nowhere to go shows nothing at all, which is the part of the
    /// invitation that was ever load-bearing.
    func show(target: String) {
        label.stringValue = "Drop file for agent here"
        isHidden = false
    }

    var messageForTesting: String { label.stringValue }

    /// Force an arbitrary string in, so the drill can prove the CONSTRAINTS
    /// hold rather than proving the shipped wording happens to be short.
    func showForTesting(_ text: String) {
        label.stringValue = text
        isHidden = false
    }

    /// Does the text sit inside the panel, both edges? The ink, not the
    /// frame: a label frame can be clipped to bounds while the glyphs it
    /// draws still run past them.
    var textFitsForTesting: Bool {
        let ink = label.attributedStringValue.boundingRect(
            with: NSSize(width: label.bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return label.frame.minX >= 0
            && label.frame.maxX <= bounds.width + 0.5
            && ink.width <= label.bounds.width + 0.5
    }

    /// Invisible to the mouse: an overlay that hit-tests would swallow the
    /// drag it exists to advertise.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DoorLabel: NSTextField {
    var isADoor = false {
        didSet {
            guard isADoor != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if !isADoor { unlift() }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isADoor else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Hover
    //
    // The pill was a door with a cursor and no answer: "Speaking is clickable,
    // but doesn't have any hover effect." The cursor is a promise the pixels
    // were not keeping, and it is the same promise `Controls` keeps by
    // brightening — so the pill brightens too, by the same rule and the same
    // step. Repainted rather than tinted: the placard is an attributed string
    // whose runs carry their own colours (the mark and the word, amber or
    // chrome), and `contentTintColor` does not reach them.

    private var resting: NSAttributedString?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// The hover, without a mouse — `mouseEntered` reads an NSEvent no drill
    /// can post, and a hover nobody can assert is a hover that silently stops
    /// working.
    func setHovered(_ hovered: Bool) {
        guard hovered else { return unlift() }
        guard isADoor, resting == nil else { return }
        let current = attributedStringValue
        resting = current
        attributedStringValue = StateLegend.hoveredInk(current)
    }

    private func unlift() {
        guard let resting else { return }
        attributedStringValue = resting
        self.resting = nil
    }

    /// The gesture recogniser does the work; this only keeps a dead label from
    /// swallowing clicks meant for the card behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isADoor ? super.hitTest(point) : nil
    }
}

/// The card's prose: selectable by hand, and by hand ONLY.
///
/// A selectable `NSTextField` is a valid key view, and a text field that becomes
/// first responder selects ALL of its text. The two faces that take the keyboard
/// — the list and the settings pane — hand it to whatever AppKit picks, which
/// was this label; from then on the field editor stayed installed and every
/// programmatic `stringValue` arrived pre-selected, so a card would come back
/// from a turn with its whole body highlighted and nobody had touched it
/// (screenshot, 16 Aug). The highlight was also unreadable, which is the panel's
/// appearance and is fixed where the panel is built.
///
/// Selecting prose off a card is worth keeping — it is how a line gets quoted
/// into a reply — so this does not switch selection off. It narrows WHO may
/// start one to a pointer press that lands on these words. Keyboard traversal,
/// the window's automatic first-responder pick, and a click anywhere else on
/// the panel are all refused, so a selection means a hand made it.
final class CardBodyLabel: NSTextField {
    /// The gate, taking its event as an argument so a drill can ask the
    /// question without a mouse: `acceptsFirstResponder` reads
    /// `NSApp.currentEvent`, which no test can set.
    func acceptsPress(_ event: NSEvent?) -> Bool {
        guard let event, let window, event.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .leftMouseDragged: break
        default: return false
        }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override var acceptsFirstResponder: Bool { acceptsPress(NSApp.currentEvent) }

    /// New words, no selection.
    ///
    /// Guarded on the WORDS rather than on the assignment: `paintInk` rewrites
    /// this label once per spoken word to advance the karaoke ink, and dropping
    /// a hand-made selection on a repaint that changed only colour would be the
    /// same bug pointing the other way.
    override var stringValue: String {
        get { super.stringValue }
        set {
            let changed = newValue != super.stringValue
            super.stringValue = newValue
            if changed { dropSelection() }
        }
    }

    override var attributedStringValue: NSAttributedString {
        get { super.attributedStringValue }
        set {
            let changed = newValue.string != super.attributedStringValue.string
            super.attributedStringValue = newValue
            if changed { dropSelection() }
        }
    }

    /// True while a hand-made selection is on screen. The drill's evidence, and
    /// read from the field editor rather than from a flag we set, because the
    /// defect is precisely the editor disagreeing with what we think we did.
    var hasSelection: Bool {
        guard let editor = currentEditor() else { return false }
        return editor.selectedRange.length > 0
    }

    func dropSelection() {
        guard currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
    }
}

/// Every button on the panel answers the pointer the same way.
///
/// The standard (docs/ruling-the-panel-answers-the-pointer.md):
///
///  1. the CURSOR says a thing is a control — a pointing hand over its hit
///     rect, everywhere, because on this panel a control and a label are the
///     same object to the eye by design (the card's actions are quiet text with
///     no lozenge, ruled) and nothing else distinguishes them at rest;
///  2. the INK confirms the pointer is on THIS one — one step up the control's
///     own colour, `StateLegend.hovered` — a fixed +8 ΔL*;
///  3. nothing moves, nothing grows, no lozenge appears, no hue changes. A
///     panel where things jump under the pointer is an interface asking to be
///     looked at, which is the product this one exists not to be;
///  4. no control rests at `ink`. The brightest ink is the prose's; a control
///     resting there is louder than the message and has no step left to take.
///
/// A row-shaped control keeps the wash it already had (`Palette.hover`) instead
/// of the ink step — see `GridRowView`. Rule 1 applies to it all the same.
final class ConsoleButton: NSButton {
    /// The ink at rest. Its hover value is decided by the ramp, not here, so
    /// "one step" cannot become a different distance on a different button.
    ///
    /// Nil for a button that paints its own title for reasons the ramp does not
    /// know about — the settings tabs, whose ink carries WHICH TAB IS OPEN, a
    /// louder signal than the pointer and not one hover may overwrite. Rule 1
    /// still applies to those: they get the cursor, and their confirmation is
    /// the selection they already draw.
    var restingInk: NSColor? { didSet { paintInk() } }

    /// A door's title, held as plain words so the hover step can rebuild it in
    /// the new ink — rendered through `StateLegend.BottomLine.door`, the bottom
    /// line's one lexicon, so a hovering door cannot drift from a resting one.
    /// Buttons carrying a symbol leave this nil and are re-inked through
    /// `contentTintColor`.
    var wordmark: String? { didSet { paintInk() } }

    /// For a button drawn some third way — the chip's ✕ is a monospaced glyph
    /// in an attributed title, which neither a tint nor a wordmark reaches.
    /// Set this BEFORE `restingInk`, which is what triggers the first paint.
    var reink: ((NSColor) -> Void)?
    private var hovering = false {
        didSet { guard hovering != oldValue else { return }; paintInk() }
    }

    /// The hover, without a mouse. `mouseEntered` takes an NSEvent no drill can
    /// post, and the panel's only coverage is drills.
    func setHovered(_ hovered: Bool) { hovering = hovered }

    /// A hidden button gets no hover events, so a button hidden while the
    /// pointer is on it would come back lit. Faces swap buttons constantly.
    override var isHidden: Bool {
        didSet { if isHidden { hovering = false } }
    }

    private func paintInk() {
        guard let restingInk else { return }
        let color = hovering ? StateLegend.hovered(restingInk) : restingInk
        if let reink {
            reink(color)
        } else if let wordmark {
            attributedTitle = StateLegend.BottomLine.door(wordmark, color: color)
        } else {
            contentTintColor = color
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The pointer target this control keeps, whatever size its mark is.
    /// Ruled at 26 — "a hit target well under the ~24pt a fingertip-sized
    /// control needs even for a mouse".
    var pointerTarget: CGFloat = 26

    /// How far this control's box reaches past the MARK inside it, per side.
    ///
    /// Two boxes deep, and the second one is why the first attempt at this
    /// still missed. A symbol button centres its image in the 26pt target, and
    /// the image is itself padded around the glyph — so aligning by
    /// `image.size` put the chevron's paint at 16.5 when the column is at 14
    /// (measured). This rasterises the image once, at build, and finds the
    /// columns that actually carry alpha.
    ///
    /// Nothing here shrinks the target. These are the numbers a call site
    /// subtracts so the MARK lands on `StatusHUD.contentColumn` and the target
    /// overhangs outward, into the panel's own margin, where nothing else is
    /// competing for the space.
    var inkOverhang: (leading: CGFloat, trailing: CGFloat) {
        guard let image, image.size.width > 0 else { return (0, 0) }
        let slack = (pointerTarget - image.size.width) / 2
        let width = Int(image.size.width.rounded(.up))
        let height = max(1, Int(image.size.height.rounded(.up)))
        guard width > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (slack, slack) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()

        var first = width, last = -1
        for x in 0..<width {
            for y in 0..<height where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                first = min(first, x); last = max(last, x)
                break
            }
        }
        guard last >= first else { return (slack, slack) }
        return (slack + CGFloat(first),
                slack + (image.size.width - CGFloat(last + 1)))
    }

    /// The hover ink, for the drill. Reading it off the button rather than
    /// recomputing it is the difference between asserting the standard and
    /// asserting the arithmetic twice.
    var hoverInkForTesting: NSColor? { restingInk.map(StateLegend.hovered) }

    func setHoveringForTesting(_ on: Bool) { hovering = on }
    var currentInkForTesting: NSColor? {
        // Whatever PAINTS, not whatever a particular path happens to use. This
        // asked `wordmark != nil` and so read `contentTintColor` for a button
        // that repaints through `reink` — which is how `backWearsIt` went red
        // the moment the back button's ‹ started being composed as an
        // attributed title. Same mistake as the face census made an hour
        // earlier, in the same file: the instrument looked beside the pixels.
        if attributedTitle.length > 0 {
            return attributedTitle.attribute(.foregroundColor, at: 0,
                                             effectiveRange: nil) as? NSColor
        }
        return contentTintColor
    }
}

final class GridRowView: NSControl {
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
    static let auxFont = ChromeType.mono(ofSize: 11, weight: .regular)

    init(item: StateLegend.SessionRow, auxWidth: CGFloat,
         target: AnyObject, action: Selector) {
        nameLabel = NSTextField(labelWithString: item.name)
        super.init(frame: .zero)
        self.target = target
        self.action = action
        identifier = NSUserInterfaceItemIdentifier(item.id)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // Rest the pointer and read the whole thing. Both halves of this row
        // truncate, so until 18 Aug the end of an error or a stall lived only
        // in the log: "there's no way to see the full message."
        toolTip = StateLegend.hoverText(for: item)

        let ready = item.lamp == .ready

        // The lamp: a 9px CIRCLE (ruled — squares read as checkboxes), flat
        // fill, no gradients or shadows. Quiet lamps get the hairline ring.
        let lamp = NSView()
        lamp.translatesAutoresizingMaskIntoConstraints = false
        lamp.wantsLayer = true
        // READ STATE GETS ITS OWN CHANNEL: a lit lamp is SOLID while unread
        // and a RING once opened, in the same state colour (16 Aug).
        //
        // Brightness alone could not do this job. Measured on the rendered
        // panel: unread ink 199, a gone row 129, and any opened step strong
        // enough to see lands on top of the gone row — so read would have been
        // borrowing the death channel, which is the collision behind "turned
        // off is turned off". Fill-vs-ring is orthogonal: colour still says
        // WHICH state (green ready, blue working), the fill says whether you
        // have heard it, and a gone row is a grey socket, a different colour
        // entirely. It is also the oldest unread idiom there is — a solid dot
        // that hollows out once you have looked.
        let hollow = item.read == .opened && item.lamp.asksForYou
        lampLayer = lamp.layer
        lamp.layer?.backgroundColor = hollow ? NSColor.clear.cgColor : item.lamp.fill.cgColor
        lamp.layer?.cornerRadius = StateLegend.Lamp.diameter / 2
        if hollow {
            // 1.5pt, not the quiet ring's 1pt: at 9px a hairline ring reads as
            // a smudge rather than a deliberate outline.
            lamp.layer?.borderWidth = 1.5
            lamp.layer?.borderColor = item.lamp.fill.cgColor
        } else if let ring = item.lamp.ring {
            lamp.layer?.borderWidth = 1
            lamp.layer?.borderColor = ring.cgColor
        }

        // The type ramp: both columns monospaced (one family, two sizes — the
        // callsign is an identity, not prose). Semibold is the UNREAD weight
        // (ruled 13 Aug): a ready row drops to medium once its turn has been
        // opened, the iOS Messages move — the lamp stays lit because read is
        // not answered, but the weight stops claiming there is something you
        // have not been told.
        //
        // A row whose session has exited is drawn at reduced ink (ruled 11 Aug:
        // "they should be shown that they are not alive"). The dimming is the
        // second half of a two-channel statement, and both channels are about
        // presence rather than state: an empty socket where a lamp would be,
        // and type that has stepped back. No new colour is spent on it.
        let ink = item.lamp.rowAlpha
        let name = nameLabel
        // Unread is BRIGHT AND HEAVY; opened steps back on both channels.
        //
        // Weight alone shipped on 13 Aug and could not be seen: semibold
        // against medium at 13pt mono is a few hundredths of a stem width,
        // and the report was immediate — "it doesn't decrease the brightness
        // of the text or anything". Brightness is the channel a person
        // actually reads a list by, so the ink steps `ink -> secondary` (a
        // Palette step the callsign column already uses, not a new colour and
        // not an alpha fade — a fade is how a LIVE opened row would start
        // impersonating a dead one, which `rowAlpha` owns).
        // NO BOLD. Hierarchy is intensity plus the lamp, never weight.
        //
        // This is the AmberConsole law the MOCR research adopted and the panel had
        // been quietly breaking since the grid was built: "single hue at
        // multiple intensities; hierarchy via size/intensity/inverse-video,
        // NO BOLD; flat by philosophy" (2026-08-04-mocr-brand-aesthetic,
        // Established). Ready rows were semibold, and the 13 Aug read state
        // made it worse by recruiting weight to mean unread as well. A
        // console does not shout in a heavier cut of the same face; it
        // burns brighter.
        //
        // So intensity answers one question — is this row asking for you —
        // and it is the SAME answer on every face. A row that is merely
        // alive rests at the same level as one you have already heard,
        // because neither is asking; only their lamps differ.
        name.font = ChromeType.mono(ofSize: 13, weight: .medium)
        // FULL INK IS RESERVED FOR ROWS THAT WANT YOU, and after this change
        // that is exactly the green and amber ones you have not heard.
        //
        // Dark-cockpit doctrine, which this palette already states: the panel
        // is dark when all is nominal and a lit lamp always means deviation.
        // An advisory row rendered at full attention ink broke it — the agent
        // is working, there is nothing to do, and the brightest thing on the
        // panel was saying otherwise. It comes back the moment the agent
        // stops: the lamp returns to green, the turn is still unread, and the
        // row lights up on its own.
        name.textColor = (item.read.isAsking && item.lamp.asksForYou
                          ? StateLegend.Palette.ink
                          : StateLegend.Palette.restingInk).withAlphaComponent(ink)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let callsign = NSTextField(labelWithString: item.aux)
        callsign.font = Self.auxFont
        callsign.textColor = (ready ? StateLegend.Palette.secondary : StateLegend.Palette.muted)
            .withAlphaComponent(ink)
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

    /// Held so the drill can read the read-state channel back off a built
    /// row: fill present means unread, absent means opened.
    private(set) var lampLayer: CALayer?

    /// Held so the launch drill can read the weight back off a built row —
    /// the weight IS the read state now (unread semibold, opened medium),
    /// and a drill that cannot see it would be asserting a sort order about
    /// pixels it never checks.
    let nameLabel: NSTextField
    /// The name's ink at rest, so the hover step has something to return to.
    /// Read once at build: a row is rebuilt whenever its state changes, so a
    /// stale value cannot outlive the ink it describes.
    private lazy var restingName: NSColor = nameLabel.textColor ?? StateLegend.Palette.ink

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// A row lights in BOTH registers (ruled 18 Aug): the wash says which
    /// region the click lands in, and the name steps one hover distance so the
    /// row reads as LIT rather than as a grey box with the same words on it.
    ///
    /// Measured, because the question was whether the wash is enough: the wash
    /// is ΔL* 4.6 from the surface — the same distance a hovered word travels —
    /// so its advantage over text was never contrast, it was area. Area alone
    /// is what makes a hover feel cheap.
    ///
    /// The wash stays, though, and not out of taste: this is a non-activating
    /// panel, cursor rects only fire while the app is active, and on the common
    /// path — you in Terminal, the panel on screen — the pointer never becomes
    /// a hand. On that path the wash is the only cue there is, and a region is
    /// what it is cueing.
    /// The row lights its WORDS, and nothing else (ruled 18 Aug — "let's prefer
    /// that text hover on the agent grid list").
    ///
    /// The wash is gone. What it bought was area, not contrast — measured at
    /// ΔL* 4.6 from the surface, the same distance the name travels — and the
    /// cost was that a list of eight rows answered the pointer with a grey box
    /// instead of with the row.
    ///
    /// Worth knowing, because it is the one thing this treatment gives up: ink
    /// brightness on this grid ALSO carries read state — an unread row rests at
    /// full ink, an opened one below it — so a hovered opened row now lands
    /// about where an unread row rests. The lamp still separates them (solid
    /// unread, hollow opened) and the hover is transient, so it reads as
    /// pointer feedback rather than as a state; if it ever reads as ambiguous,
    /// the answer is an underline — a shape rather than a tier, which is what
    /// the card title already does at the top of the ramp.
    func setHovered(_ on: Bool) {
        nameLabel.textColor = on ? StateLegend.hovered(restingName) : restingName
    }

    /// Rule 1 of the hover standard: the wash says WHICH row the pointer is on,
    /// and the cursor says the row is a control at all. The wash alone cannot —
    /// the list has always lit its rows, and a lit row still reads as a
    /// read-state change to anyone who has not already learned otherwise.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
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
        plus.font = ChromeType.mono(ofSize: 12, weight: .regular)
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

/// A bare hover rectangle. `Controls` owns its own tracking rect rather than
/// borrowing the footer's: the footer spans the whole grid width, and hovering
/// the app's name in the opposite corner is not hovering a control.
private final class HoverBox: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways, like the grid rows'. The panel is a .nonactivatingPanel
        // and never becomes key — .activeInKeyWindow would simply never fire.
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The word `Controls`, wherever a face has a bottom line to put it on.
///
/// Ruled 18 Aug: the gestures do not stop existing when the grid does. The word
/// lived in the grid footer and nowhere else, so the moment a card took the
/// stage — the face you are on when a gesture is most likely to be the next
/// thing you do — the only place that names the chords was gone. One class, so
/// the hover behaviour, the ink tiers and the type cannot drift between the two
/// rows that host it; two instances, because they are two rows.
///
/// It sits in the CENTRE of its row on both faces. The card's bottom line
/// already spends both edges (OPEN HUB left, GO TO AGENT right) and the middle
/// is the only free space; putting the grid's copy anywhere else would make the
/// same word move when the face changed, which is how a permanent affordance
/// reads as a different thing each time.
private final class ControlsWordView: NSView {
    var onHover: ((Bool) -> Void)?
    /// For the drill: what the word is actually drawn with.
    private(set) var wordValue = NSAttributedString()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let word = NSTextField(labelWithString: "")
        wordValue = StateLegend.BottomLine.quiet(StateLegend.controlsTitle)
        word.attributedStringValue = wordValue
        word.translatesAutoresizingMaskIntoConstraints = false

        let box = HoverBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(word)
        box.onHover = { [weak self] hovering in
            // One ink tier under the cursor — `hint` to `ink`, both above their
            // floors, so the change is a confirmation and never the difference
            // between legible and not.
            word.attributedStringValue = StateLegend.BottomLine.quiet(
                StateLegend.controlsTitle,
                color: hovering ? StateLegend.Palette.ink : StateLegend.Palette.hint)
            self?.onHover?(hovering)
        }

        addSubview(box)
        NSLayoutConstraint.activate([
            // The target is bigger than the word (ruled 18 Aug: "the controls
            // hover area on the spoken page is too small"). On the grid the
            // footer lends it a 14pt strip and it feels right; in a card's
            // action row the view hugs its own label, so the hittable area was
            // exactly the glyphs — about 8pt tall and not much wider than the
            // word — and finding it was a hunt. 8pt of slack on each side and a
            // 20pt floor makes it the same size target on both faces, which is
            // the point: one affordance, one feel.
            word.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            word.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            word.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            // 20 is the target SIZE, exactly — not a floor.
            //
            // As `>=`, with the box pinned to all four edges, this view had no
            // opinion about its own height: the constraint system was left with
            // a degree of freedom, and in a stack with vertical slack the view
            // took the slack. Measured 19 Aug over repeated runs of one
            // unchanged binary, the same card laid this out at 20pt on some
            // launches and 113pt on others — inside an action row that grew
            // from 25pt to 125pt with it — so the word either sat under the
            // body where it belongs or floated sixty points below it, and which
            // one you got was a coin flip.
            //
            // Required, because the ruling that set the 20 set a size and not a
            // minimum: "8pt of slack on each side and a 20pt floor makes it the
            // same size target on both faces, which is the point: one
            // affordance, one feel." A target that is sometimes five times its
            // ruled height is not one feel, and a hover area that moves between
            // launches is worse than a small one.
            box.heightAnchor.constraint(equalToConstant: 20),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The grid's bottom line: `Controls` in the middle, `Tranquility Base` at the
/// right. Same size and same ink — the difference between them is that one
/// answers the cursor.
private final class GridFooterView: NSView {
    /// Shorter than a grid row on purpose: a rule-under-the-page line, not a
    /// row you might mistake for a session.
    static let height: CGFloat = 14

    /// True on enter, false on exit — for `Controls` only.
    var onControlsHover: ((Bool) -> Void)?
    /// The signature was tapped. The panel's one door to the project itself
    /// rather than to an agent.
    var onWordmark: (() -> Void)?
    /// The hover target, exposed so the note can be hung above the row that
    /// actually owns the word rather than above a hard-coded one.
    let controls = ControlsWordView()
    /// The signature, exposed for the same reason `controls` is: a door that
    /// silently stops being a door is the failure this panel keeps having, and
    /// a drill cannot assert what it cannot reach.
    let mark = DoorLabel(labelWithString: "")

    init(width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        controls.onHover = { [weak self] in self?.onControlsHover?($0) }

        // A `DoorLabel` rather than a label, so the signature answers the
        // pointer the way everything else on the panel does — the cursor says
        // it is a control, the ink says the pointer is on it. Both come with
        // the type; all this has to declare is that it IS a door.
        mark.attributedStringValue = StateLegend.BottomLine.quiet(StateLegend.wordmark)
        mark.isADoor = true
        mark.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(wordmarkTapped)))
        mark.translatesAutoresizingMaskIntoConstraints = false

        addSubview(controls); addSubview(mark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            mark.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func wordmarkTapped() { onWordmark?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The sticky note behind `Controls`: the chords the key line used to spell out
/// along the bottom of every grid, now shown only when asked for.
private final class ControlsNoteView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // One step up from the surface — the same lift the grid rows use for
        // hover, so the note reads as the panel raising a corner of itself
        // rather than a foreign window arriving on top of it.
        layer?.backgroundColor = StateLegend.Palette.hover.cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = StateLegend.Palette.hairline.cgColor

        let font = ChromeType.mono(ofSize: 9.5, weight: .regular)
        // ONE chord column, sized to the widest chord — the rule the grid's
        // callsign column already follows. Per-line widths would start every
        // meaning at its own x, and a three-line rag is what made the old
        // single-line key line read as a run-on.
        let chordWidth = StateLegend.controlsNote
            .map { ceil(($0.chord as NSString)
                .size(withAttributes: [.font: font]).width) }
            .max() ?? 0

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.translatesAutoresizingMaskIntoConstraints = false

        for entry in StateLegend.controlsNote {
            // Through the composer: these rows are nothing BUT marks beside
            // words — "⌃ Ctrl + ⌥ Option" — which makes them the last place
            // that should be setting a plain string.
            let chord = NSTextField(labelWithString: "")
            chord.attributedStringValue = ChromeType.line(
                entry.chord, font: font, color: StateLegend.Palette.ink)
            chord.font = font
            // The chord is the thing you are here to learn; the gloss explains
            // it. Full ink on the key, hint on the words.
            chord.textColor = StateLegend.Palette.ink
            chord.translatesAutoresizingMaskIntoConstraints = false
            chord.widthAnchor.constraint(equalToConstant: chordWidth).isActive = true

            let meaning = NSTextField(labelWithString: entry.meaning)
            meaning.font = font
            meaning.textColor = StateLegend.Palette.hint
            meaning.translatesAutoresizingMaskIntoConstraints = false

            let line = NSStackView(views: [chord, meaning])
            line.orientation = .horizontal
            line.alignment = .firstBaseline
            line.spacing = 10
            rows.addArrangedSubview(line)
        }

        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
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
/// A full-width row that is only a door to another pane. Styled like a row,
/// not a button, because it lives among rows.
private final class PaneLinkRowView: NSControl {
    private let onTap: () -> Void
    private let hairline = CALayer()

    init(title: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hairline.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
        layer?.addSublayer(hairline)

        let label = NSTextField(labelWithString: title)
        label.font = ChromeType.mono(ofSize: 12, weight: .medium)
        label.textColor = StateLegend.Palette.secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: VoiceRowView.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: VoiceRowView.gripWidth),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    override func mouseDown(with event: NSEvent) { onTap() }
}

/// One capture in the recent-audio log: when, how long, what it said — or
/// that it said nothing the chain could hear. Play sits on the row because
/// it has state a menu cannot show (▶ while stopped, ■ while playing —
/// ruled 13 Aug); everything stateless lives behind ⋯ — Copy transcript,
/// Retry transcription, Show in Finder.
private final class AudioEventRowView: NSControl, NSMenuDelegate {
    static let height: CGFloat = 34
    /// Trailing gutter the row's controls never enter. `scrollerStyle` is
    /// `.overlay` on the list, but macOS substitutes legacy bars when a mouse
    /// is connected or "Show scroll bars: Always" is set — which parked a
    /// scroller exactly on top of the old ↻ (reported 13 Aug, unclickable).
    /// The gutter is reserved unconditionally; against an overlay bar it is
    /// just breathing room.
    static let scrollerGutter: CGFloat = 16

    let eventId: String
    private let event: StatusHUD.AudioEventRow
    private let onPlay: () -> Void
    private let onRetry: () -> Void
    private let onReveal: () -> Void
    private let hairline = CALayer()
    private var playButton: ConsoleButton!
    private var menuButton: ConsoleButton!

    var playButtonTitle: String { playButton.title }
    var controlsClearTheScroller: Bool {
        menuButton.frame.maxX <= bounds.width - Self.scrollerGutter
    }
    /// The ⋯ menu's Retry item state, for the drill: present unless the row
    /// is already retrying.
    var retryEnabled: Bool { !event.retrying }

    init(event: StatusHUD.AudioEventRow,
         onPlay: @escaping () -> Void,
         onRetry: @escaping () -> Void,
         onReveal: @escaping () -> Void) {
        self.eventId = event.id
        self.event = event
        self.onPlay = onPlay
        self.onRetry = onRetry
        self.onReveal = onReveal
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hairline.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
        layer?.addSublayer(hairline)

        let when = NSTextField(labelWithString: event.timeLabel)
        when.font = ChromeType.mono(ofSize: 10, weight: .regular)
        when.textColor = StateLegend.Palette.secondary
        when.translatesAutoresizingMaskIntoConstraints = false

        let duration = NSTextField(labelWithString: event.durationLabel)
        duration.font = ChromeType.mono(ofSize: 10, weight: .regular)
        duration.textColor = StateLegend.Palette.faint
        duration.alignment = .right
        duration.translatesAutoresizingMaskIntoConstraints = false

        // The transcript is the row's name; its absence is stated in the
        // hint colour rather than left as a blank, because an empty slot
        // reads as a rendering bug and a stated absence reads as a fact.
        let snippet = NSTextField(labelWithString: event.transcript ?? "no transcript")
        snippet.font = ChromeType.mono(ofSize: 11, weight: .regular)
        snippet.textColor = event.transcript == nil
            ? StateLegend.Palette.hint : StateLegend.Palette.ink
        snippet.lineBreakMode = .byTruncatingTail
        snippet.translatesAutoresizingMaskIntoConstraints = false
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        playButton = ConsoleButton(title: event.playing ? "■" : "▶",
                                   target: self, action: #selector(playTapped))
        playButton.isBordered = false
        playButton.font = ChromeType.mono(ofSize: 12, weight: .regular)
        if event.playing {
            // Playing is a STATE, and it is already wearing `ink`. Hover does
            // not overwrite a louder signal with a quieter one, so a playing
            // row answers the pointer with the cursor alone — the same carve-out
            // the settings tabs take.
            playButton.contentTintColor = StateLegend.Palette.ink
        } else {
            playButton.restingInk = StateLegend.Palette.secondary
        }
        playButton.translatesAutoresizingMaskIntoConstraints = false

        menuButton = ConsoleButton(title: "⋯", target: self, action: #selector(menuTapped))
        menuButton.isBordered = false
        menuButton.font = ChromeType.mono(ofSize: 12, weight: .semibold)
        menuButton.restingInk = StateLegend.Palette.secondary
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        for view in [when, duration, snippet, playButton!, menuButton!] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            when.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            when.widthAnchor.constraint(equalToConstant: 74),
            when.centerYAnchor.constraint(equalTo: centerYAnchor),
            duration.leadingAnchor.constraint(equalTo: when.trailingAnchor, constant: 2),
            duration.widthAnchor.constraint(equalToConstant: 44),
            duration.centerYAnchor.constraint(equalTo: centerYAnchor),
            snippet.leadingAnchor.constraint(equalTo: duration.trailingAnchor, constant: 8),
            snippet.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: snippet.trailingAnchor, constant: 6),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.leadingAnchor.constraint(
                equalTo: playButton.trailingAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.scrollerGutter),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    /// The stateless verbs. Built fresh per click so the items reflect the
    /// row as it is now, not as it was rendered.
    func rowMenu() -> NSMenu {
        let menu = NSMenu()
        if event.transcript != nil {
            menu.addItem({ let i = NSMenuItem(
                title: "Copy transcript", action: #selector(copyTranscript),
                keyEquivalent: ""); i.target = self; return i }())
        }
        let retry = NSMenuItem(
            title: event.retrying ? "Retrying…" : "Retry transcription",
            action: event.retrying ? nil : #selector(retryFromMenu), keyEquivalent: "")
        retry.target = event.retrying ? nil : self
        menu.addItem(retry)
        menu.addItem({ let i = NSMenuItem(
            title: "Show audio in Finder", action: #selector(revealFromMenu),
            keyEquivalent: ""); i.target = self; return i }())
        return menu
    }

    var menuTitlesForSelfTest: [String] { rowMenu().items.map(\.title) }
    func performRetryForSelfTest() { retryFromMenu() }
    func tapPlayForSelfTest() { playButton.performClick(nil) }

    @objc nonisolated private func playTapped() {
        MainActor.assumeIsolated { onPlay() }
    }

    @objc nonisolated private func menuTapped() {
        MainActor.assumeIsolated {
            let menu = rowMenu()
            menu.popUp(positioning: nil,
                       at: NSPoint(x: menuButton.frame.minX,
                                   y: menuButton.frame.minY - 4),
                       in: self)
        }
    }

    @objc nonisolated private func copyTranscript() {
        MainActor.assumeIsolated {
            guard let text = event.transcript else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Permissions.log("recent-audio: copied \(text.count) chars from \(eventId.prefix(8))")
        }
    }

    @objc nonisolated private func retryFromMenu() {
        MainActor.assumeIsolated { onRetry() }
    }

    @objc nonisolated private func revealFromMenu() {
        MainActor.assumeIsolated { onReveal() }
    }
}

/// A section legend in the voices pane.
///
/// There are two rosters — ElevenLabs and system — and one flat list could not
/// say so. Set in capitals because that is what this panel's legends do (ruled
/// 18 Aug), and carrying its own count because "26 of 56" across both told you
/// nothing about either.
private final class VoiceSectionHeaderView: NSView {
    static let height: CGFloat = 28

    /// Extra air above a legend that follows ROWS rather than the tab rule.
    ///
    /// The eye compares optical air, not painted margins, and that depends on
    /// what sits above: the first legend sits under a hairline and reads settled
    /// at 0, while the second sits under a row of names and reads cramped at the
    /// same number. Measured by rendering the pane and looking at it, which is
    /// the lesson the card-floor revert paid for (0f216b3).
    static let airAboveFollowingSection: CGFloat = 9

    static func height(followingRows: Bool) -> CGFloat {
        height + (followingRows ? airAboveFollowingSection : 0)
    }

    init(title: String, onRoster: Int, available: Int, note: String?,
         followingRows: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let legend = NSTextField(labelWithString: title.uppercased())
        legend.font = ChromeType.mono(ofSize: 9.5, weight: .regular)
        legend.textColor = StateLegend.Palette.hint
        legend.translatesAutoresizingMaskIntoConstraints = false

        let count = NSTextField(labelWithString: "\(onRoster) of \(available)")
        count.font = ChromeType.mono(ofSize: 9.5, weight: .regular)
        count.textColor = StateLegend.Palette.faint
        count.translatesAutoresizingMaskIntoConstraints = false

        // The rule sits under the legend, not between the rows, so the two lists
        // read as two lists rather than as one list with a caption in it.
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = StateLegend.Palette.hairline.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        for v in [legend, count, rule] { addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(
                equalToConstant: Self.height(followingRows: followingRows)),
            legend.leadingAnchor.constraint(equalTo: leadingAnchor),
            legend.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -5),
            count.trailingAnchor.constraint(equalTo: trailingAnchor),
            count.lastBaselineAnchor.constraint(equalTo: legend.lastBaselineAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])

        if let note {
            let sub = NSTextField(labelWithString: note)
            sub.font = ChromeType.mono(ofSize: 9, weight: .regular)
            sub.textColor = StateLegend.Palette.faint
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: legend.trailingAnchor, constant: 8),
                sub.lastBaselineAnchor.constraint(equalTo: legend.lastBaselineAnchor),
                sub.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor,
                                              constant: -8),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

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

        let grip = NSTextField(labelWithString: onRoster ? "≡" : "")   // download rows never show one
        grip.font = ChromeType.mono(ofSize: 11, weight: .regular)
        grip.textColor = StateLegend.Palette.faint
        grip.translatesAutoresizingMaskIntoConstraints = false

        // A voice you do not have cannot be auditioned and cannot be cast, so it gets
        // neither control. Shipping it with a checkbox and a ▶ that opened System
        // Settings was worse than useless: a play button that does not play is a lie,
        // and a checkbox that cannot be checked is furniture.
        let isDownload = SystemVoiceCatalog.isDownloadRow(voice.id)

        let check = CheckView(on: onRoster) { [weak self] in self?.onToggle() }
        // Hidden rather than omitted, so the name column stays on the same x as every
        // other row. Dropping the view would shift the whole row left and misalign the
        // list against itself.
        check.isHidden = isDownload

        let play = ConsoleButton(title: "▶", target: self, action: #selector(playTapped))
        play.isBordered = false
        play.font = ChromeType.mono(ofSize: 14, weight: .regular)
        play.restingInk = StateLegend.Palette.secondary
        // Invisible, not absent: the slot holds the name column's x so every row's
        // name starts on the same pixel. Putting "Get" in this slot instead pushed
        // the name right and misaligned that row against the whole list.
        play.isHidden = isDownload
        play.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: Self.concise(voice.name))
        name.font = ChromeType.mono(ofSize: 12, weight: .medium)
        // Dimmed when it is not installed — the row is an offer, not a voice you have.
        name.textColor = isDownload ? StateLegend.Palette.secondary : StateLegend.Palette.ink
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let category = NSTextField(labelWithString: voice.category)
        category.font = ChromeType.mono(ofSize: 9.5, weight: .regular)
        category.textColor = StateLegend.Palette.hint
        category.translatesAutoresizingMaskIntoConstraints = false

        // The action sits on the right, where an action belongs, rather than in the
        // preview slot where it displaced the name.
        // Drawn from the panel's own palette, not AppKit's bezel.
        //
        // `bezelStyle = .rounded` paints a LIGHT system chrome and a dark title, which
        // on this dark console rendered as near-black text on near-black fill — the
        // one control on the pane you are meant to press, and the least visible thing
        // on it. The panel guarantees its own contrast everywhere else (`surface` is
        // opaque for exactly this reason); the button now does too.
        // The one control on the panel with a box of its own, so it is the one
        // that takes rule 1 and stops: it already looks like a button, and an
        // ink step on a title sitting on its own fill would say what the fill
        // has said since it was drawn.
        let get = ConsoleButton(title: "", target: self, action: #selector(playTapped))
        get.isBordered = false
        get.wantsLayer = true
        get.layer?.backgroundColor = StateLegend.Palette.hairline.cgColor
        get.layer?.cornerRadius = 5
        get.attributedTitle = NSAttributedString(
            string: "Get",
            attributes: [
                // ink on surface is 8.39:1 — the same ink the row names use, so the
                // action is at least as legible as the thing it acts on.
                .foregroundColor: StateLegend.Palette.ink,
                .font: ChromeType.mono(ofSize: 10, weight: .semibold),
            ])
        get.translatesAutoresizingMaskIntoConstraints = false
        get.isHidden = !isDownload

        addSubview(grip); addSubview(check); addSubview(play)
        addSubview(name); addSubview(category); addSubview(get)
        NSLayoutConstraint.activate([
            get.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            get.centerYAnchor.constraint(equalTo: centerYAnchor),
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
            category.trailingAnchor.constraint(
                equalTo: isDownload ? get.leadingAnchor : trailingAnchor,
                constant: isDownload ? -8 : -4),
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

    /// Rule 1 of the hover standard: a control says so with the cursor. A
    /// checkbox drawn by hand looks exactly as clickable as the glyph beside it,
    /// which is to say not at all.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

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
            mark.font = ChromeType.mono(ofSize: 9, weight: .bold)
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
