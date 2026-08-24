import AppKit

/// The two ephemeral top-band overlays StatusHUD shows outside its own
/// render funnel — the send receipt (a chip that says the words left, then
/// that they landed) and the acknowledge light (a bar that pulses the
/// instant a gesture registers). Split out of `StatusHUD.swift` 24 Aug
/// (App-lane P5) — the two were already adjacent and interleaved in the
/// file, which is why they land in one extension rather than two: both are
/// "an event, not state," both own exactly one widget no arm of `render()`
/// touches, and both always end by fading themselves out. Their stored
/// properties (`ackBar`, `receiptChip`, and the rest) stayed in
/// `StatusHUD.swift` itself — Swift extensions cannot add stored properties
/// to a type declared in another file.
extension StatusHUD {

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
        /// The resume actually completed. Added 23 Aug: `.reviving`'s own doc
        /// comment says "a Terminal window is about to appear and say the
        /// rest" — true when revive opened an AppleScript/Terminal.app
        /// window, false since revive moved onto `resumeTmux` (7325876):
        /// nothing visible appears any more, so a success that never updates
        /// the chip reads identically to one that hung, and the chip's own
        /// 12s ceiling fires and logs "timed out on screen" on EVERY revive,
        /// successful or not — caught live, 23 Aug, on a resume that had in
        /// fact already fully settled by the time the chip gave up on it.
        case revived(String)
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
            case .sent, .queued, .revived: return true
            case .sending, .reviving, .alreadyAwake, .notRevived: return false
            }
        }

        /// Still happening, so the chip gets the longer ceiling and logs if no
        /// outcome ever replaces it. A refusal is an outcome already.
        var inFlight: Bool {
            switch self {
            case .sending, .reviving: return true
            case .sent, .queued, .revived, .alreadyAwake, .notRevived: return false
            }
        }

        var text: String {
            switch self {
            case .reviving(let target):
                let name = target.count > 18
                    ? target.prefix(17).trimmingCharacters(in: .whitespaces) + "…"
                    : target
                return "↺ \(name.uppercased()) · RESUMING"
            case .revived(let target):
                let name = target.count > 18
                    ? target.prefix(17).trimmingCharacters(in: .whitespaces) + "…"
                    : target
                return "✓ \(name.uppercased()) · RESUMED"
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
        chip.attributedStringValue = Widgets.letterspaced(
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
}
