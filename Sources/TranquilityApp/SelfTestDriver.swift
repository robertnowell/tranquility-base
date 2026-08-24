import Foundation
import AppKit
import TranquilityCore

/// The self-test driver: `selfTest()` itself (run with `--selftest-hud`,
/// which `scripts/relaunch.sh` passes on every deploy — CLAUDE.md rule 7,
/// this is the panel's ONLY evidence, since `Sources/TranquilityApp` has
/// no unit tests and cannot easily have them) plus its own support —
/// `beginDrills`/`endDrills` (hold the panel for the drills' length),
/// `settleAnimations` (let a frame animation finish before measuring
/// geometry), `topBandDrill`/`selfTestReadbackDoor`/`selfTestPendingSend`
/// (drills `selfTest()` itself calls out to), and `widgetMatrix` (the
/// render-contract line every selftest log ends with).
///
/// Split out of `StatusHUD.swift` 23 Aug (App-lane P4, "drills + pose out
/// via TestSurface") — see `TestSurface.swift`'s own doc comment for why
/// this is a straight `extension StatusHUD` rather than a rewrite against
/// `any TestSurface`: the coupling here is structural (these functions
/// living inside StatusHUD's class body), not an access-control problem,
/// and a generic rewrite would have been a much bigger redesign than
/// "name the coupling before moving" ever asked for.
extension StatusHUD {

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
                   about: (sessionId: "somebody-else", pid: nil, label: "recall"))
        let namesTheFailingAgent = titleLabel.stringValue == "recall"
        let notTheCardOnStage = titleLabel.stringValue != "promotions"
        // The other direction, which must not regress: a failure that IS about
        // the card on stage still wears its name.
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("a card already on the stage"),
            sessionId: "on-stage", pid: 1, project: "promotions", cwd: "/tmp/promotions")
        showResult("Its own failure.", about: (sessionId: "on-stage", pid: 1, label: "promotions"))
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
}
