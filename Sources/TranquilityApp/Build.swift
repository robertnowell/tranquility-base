import AppKit
import TranquilityCore

/// The panel's one-time view construction: `ConsolePanel` (the borderless,
/// non-activating `NSPanel` subclass) and `build()`, the single largest
/// function in the app before this split — every subview StatusHUD ever
/// shows is instantiated and constrained here, once, at first paint.
/// Split out of `StatusHUD.swift` 24 Aug (App-lane P5).
extension StatusHUD {
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

    func build() -> ConsolePanel {
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
            switch SessionRow.lampAction(for: row, on: .list) {
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
}
