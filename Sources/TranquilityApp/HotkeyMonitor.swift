import AppKit
import CoreGraphics
import Foundation
import TranquilityCore

/// System-wide push-to-talk, via a listen-only `CGEvent` tap.
///
/// Adapted from Clicky's `GlobalPushToTalkShortcutMonitor` (MIT). Two details from
/// it are load-bearing and were kept deliberately:
///
/// 1. **A `CGEvent` tap, not `NSEvent.addGlobalMonitorForEvents`.** The AppKit
///    monitor is unreliable for modifier-only chords while the app is in the
///    background, and a macOS 26 field report has it crashing outright.
/// 2. **Do not restart a tap that is already running.** Permission polling calls
///    `start()` every couple of seconds; restarting resets the pressed state and
///    would kill an in-progress recording mid-utterance.
///
/// Listen-only means this needs Input Monitoring rather than Accessibility — it
/// observes the chord without consuming it. That is also why the shortcut is a
/// modifier combination rather than a bare key: an unconsumed bare key would still
/// reach whatever app is focused. Wispr Flow refuses bare keys for the same reason.
public final class HotkeyMonitor: @unchecked Sendable {
    public enum Transition: Sendable {
        /// Control, tapped on its own.
        case next
        /// Shift, tapped on its own.
        case pauseToggled
        /// ⌃⇧ tapped: dismiss what the panel is showing.
        case dismiss
        /// ⌥ tapped once, on its own. The app decides what it means: the second of
        /// a quick pair locks hands-free listening; a single tap while locked sends.
        /// The monitor stays dumb about timing on purpose — double-tap windows are
        /// policy, and policy lives where it can be logged with the rest.
        case optionTapped
        /// ⌃ tapped twice quickly, on its own. Unlike ⌥, a SINGLE bare-⌃ tap has no
        /// meaning in the app and never will (it is the first key of two chords), so
        /// there is no per-tap policy for the app to arbitrate and the pairing lives
        /// here — a deliberate exception to the optionTapped rule above. Reserved
        /// for WS-A's depth-1 pull; the handler today only logs.
        case controlDoubleTapped
        /// A bare ⌃ tap that is not a command: the first of a possible ⌃⌃, or a
        /// press that turned out to be nothing. Carries no instruction — it
        /// exists so the acknowledgment light can say "received" without also
        /// claiming "done", which are different facts that used to look alike.
        ///
        /// Emitted on RELEASE, like every other classification here, and that is
        /// load-bearing: a key-down signal would light the panel on the ⌃ of
        /// every ⌃C and the ⌥ of every typed special character. An interfered
        /// press never reaches this switch, so typing still never shows anything.
        case controlRegistered
        /// Option, held past the threshold.
        case replyBegan
        case replyEnded
        /// The hold turned out to be part of a real shortcut. Throw the audio away.
        case replyAborted
        /// Bare ⌥ survived the arm grace (~80ms) with no other input: the
        /// instant-arm window opened (docs/instant-arm.md). The app shows the
        /// arming face and opens the microphone optimistically. `pressedAt`
        /// is the key-down moment, carried for the latency log. The grace
        /// exists because bare ⌥ is also how every ⌥-chord special character
        /// starts while typing — typing must never flash the panel.
        case armWindowOpened(pressedAt: Date)
        /// The arm window closed without becoming a reply — a tap, a chord,
        /// or other input. The app reverts the arming face and discards the
        /// optimistic capture. Always precedes any tap-meaning transition
        /// (`optionTapped` etc.) from the same release.
        case armAborted
    }

    /// One gesture per action, told apart by which modifiers were held and for how
    /// long — not by a chord table.
    ///
    /// A three-key combination is a thing you have to remember; a single modifier is
    /// a thing you press. These are safe as bare keys for the same reason the old
    /// chord was: on their own they type nothing, so the listen-only tap can observe
    /// them without the keystroke doing damage on its way to the focused app.
    ///
    /// What makes them safe in PRACTICE is the other-input guard below. Shift alone
    /// is a pause; Shift followed by a letter is a capital letter and must be
    /// ignored. Control alone is next; Control-C is not. So a gesture is only ours
    /// if no other key or click happened while the modifier was down.
    public struct Bindings: Sendable {
        public var next: CGEventFlags = [.maskControl, .maskAlternate]
        public var pause: CGEventFlags = .maskShift
        public var reply: CGEventFlags = .maskAlternate
        /// Dismiss is a modifier chord, NOT Escape. The tap is listen-only, so any
        /// Escape variant still delivers ESC to the focused terminal — and in a
        /// Claude Code session ESC interrupts the running turn. A dismiss key that
        /// cancels your agent's work is worse than no dismiss key. Bare modifiers
        /// type nothing anywhere, which is the property the whole gesture set is
        /// built on.
        public var dismiss: CGEventFlags = [.maskControl, .maskShift]
        public init() {}
    }

    private var tap: CFMachPort?

    /// Watchdog, called from the app's tick. A tap can die without any callback
    /// firing — TCC re-evaluates after binary changes and disables silently
    /// (observed 06 Aug: mic stuck open, every gesture unheard, zero log lines,
    /// preflight still claiming granted). tapDisabledByTimeout has an in-callback
    /// re-enable, but a FULLY dead tap never calls back — only an outside check
    /// can notice. Re-enabling is free when healthy.
    func reviveTapIfDead() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            Permissions.log(CGEvent.tapIsEnabled(tap: tap)
                ? "hotkey: tap was DEAD; revived by watchdog"
                : "hotkey: tap dead and revive REFUSED — Input Monitoring likely revoked")
        }
    }
    private var runLoopSource: CFRunLoopSource?
    private let bindings = Bindings()
    private let holdThreshold: TimeInterval
    /// Instant-arm grace: bare ⌥ must be down alone this long before the arm
    /// window opens. Long enough that ⌥-chord typing (both keys land within a
    /// few tens of ms) never shows anything; short enough that the mic opens
    /// ~270ms before the hold resolves.
    private let armGrace: TimeInterval
    private let onTransition: @Sendable (Transition) -> Void

    /// State of the modifier press currently in progress.
    private var seenFlags: CGEventFlags = []
    private var pressStartedAt: Date?
    private var sawOtherInput = false
    /// The arm/hold decisions, delegated whole (docs/instant-arm.md, eval
    /// E1): the monitor schedules timers and feeds events; what they MEAN is
    /// answered by the machine, which is unit-tested with synthetic
    /// timelines in TranquilityCore.
    private var machine = ReplyGestureMachine()
    private var holdCheck: DispatchWorkItem?
    private var armCheck: DispatchWorkItem?
    /// When the last clean bare-⌃ tap ended. Same window as the app's ⌥⌥ detector.
    private var lastControlTapAt: Date?
    private let controlDoubleTapWindow: TimeInterval = 0.45

    /// Mutated only from the tap callback, which runs on the main run loop.
    public private(set) var isPressed = false

    /// Translate the machine's effects into transitions, in order. Runs on
    /// the main run loop (tap callback or a main-queue timer), like every
    /// other mutation here.
    private func perform(_ effects: [ReplyGestureMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .openArmWindow:
                onTransition(.armWindowOpened(pressedAt: pressStartedAt ?? Date()))
            case .abortArm:
                onTransition(.armAborted)
            case .beginReply:
                isPressed = true
                onTransition(.replyBegan)
            case .endReply:
                onTransition(.replyEnded)
            case .abortReply:
                onTransition(.replyAborted)
            }
        }
    }

    private func beginGesture(with flags: CGEventFlags) {
        seenFlags = flags
        pressStartedAt = Date()
        sawOtherInput = false
        perform(machine.apply(.began(isReply: flags == bindings.reply)))

        // The arm window (instant-arm): scheduled only for the reply chord —
        // the machine's guard is authoritative, this just avoids timer churn
        // on every ⇧/⌃ press. Cancelled on release; disqualification is the
        // machine's to decide at fire time.
        if flags == bindings.reply {
            let arm = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.perform(self.machine.apply(.graceElapsed))
            }
            armCheck = arm
            DispatchQueue.main.asyncAfter(deadline: .now() + armGrace, execute: arm)
        }

        // Recording COMMITS only once the hold outlives the threshold; the
        // arm window before it is optimistic and fully discarded on a tap.
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.perform(self.machine.apply(.holdElapsed))
        }
        holdCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: check)
    }

    private func endGesture() {
        holdCheck?.cancel()
        holdCheck = nil
        armCheck?.cancel()
        armCheck = nil
        guard let started = pressStartedAt else { return }
        let duration = Date().timeIntervalSince(started)
        let flags = seenFlags
        let interfered = sawOtherInput
        pressStartedAt = nil
        seenFlags = []
        isPressed = false

        let effects = machine.apply(.released)
        perform(effects)
        // A concluded reply (ended or aborted) was the gesture's whole
        // meaning; the tap classification below must not also run.
        if effects.contains(.endReply) || effects.contains(.abortReply) { return }
        guard !interfered, duration < holdThreshold else { return }
        switch flags {
        case bindings.next: onTransition(.next)
        case bindings.pause: onTransition(.pauseToggled)
        case bindings.dismiss: onTransition(.dismiss)
        case bindings.reply: onTransition(.optionTapped)
        case CGEventFlags.maskControl:
            // A bare ⌃ tap is unassigned on its own; two inside the window are the
            // depth-1 pull gesture (WS-A). The chord guards are already behind us:
            // an interfered press (⌃C, a click) never reached this switch, and a ⌃
            // that grew into ⌃⌥ or ⌃⇧ arrived here as that chord's flags — the
            // formUnion in handle() means it can never read as bare ⌃ — so a
            // chord's ⌃ press cannot count as a tap.
            if let last = lastControlTapAt,
               Date().timeIntervalSince(last) < controlDoubleTapWindow {
                lastControlTapAt = nil
                onTransition(.controlDoubleTapped)
            } else {
                lastControlTapAt = Date()
                // Say so. This tap commands nothing — it may yet become ⌃⌃, or
                // it may have been the whole of what the user did — but it WAS
                // received, and the one thing the panel must never do is leave
                // that in doubt. Emitted as its own case rather than folded into
                // the gesture cases because the light draws it differently: this
                // is the only transition that is not an instruction.
                onTransition(.controlRegistered)
            }
        default: break  // an unassigned combination: no action.
        }
    }

    public init(
        // 0.35 → 0.20 (ruled 06 Aug, from measurement). The log of a
        // frustrated session shows the failure exactly: press after press
        // arming and reverting with "arm: discarded, 35ms audio" — real
        // presses landing around 225ms, every one of them under the old
        // threshold and therefore meaning nothing. A press-to-talk key that
        // ignores a quarter-second press is not trustworthy. 200ms still
        // leaves the ⌥⌥ hands-free double-tap intact (those taps run
        // 50–100ms) and costs nothing in audio: capture has been running
        // since the 80ms arm either way.
        holdThreshold: TimeInterval = 0.20,
        armGrace: TimeInterval = 0.08,
        onTransition: @escaping @Sendable (Transition) -> Void
    ) {
        self.holdThreshold = holdThreshold
        self.armGrace = armGrace
        self.onTransition = onTransition
    }

    deinit { stop() }

    /// How many times the system has disabled this tap since launch, and when
    /// it last did.
    ///
    /// A count, not a flag, because the failure is intermittent and its
    /// frequency is the diagnosis: one deaf window in a day is macOS being
    /// macOS, and four in a minute is the main run loop saturated. Public so a
    /// drill can assert it stays at zero through a render storm — the
    /// before/after measurement open issue #15 asks for.
    public private(set) var deafWindows = 0
    private var lastDeafAt: Date?

    public var isRunning: Bool { tap != nil }

    /// Whether the tap is actually DELIVERING — not merely whether one exists.
    ///
    /// `isRunning` answers "did we get a tap object". This answers "can this
    /// process see keystrokes", and the gap between the two is the whole reason
    /// the permission checklist can say "restart to finish".
    ///
    /// The 08 Aug probe measured that gap directly: `accessibility=true
    /// listenEventAccess=false tapEnabled=false eventsReceived=0` — a tap that
    /// exists, is disabled, and is silent. Freshly-granted Input Monitoring
    /// looks the same way until the app is restarted, because `tapCreate` keeps
    /// returning nil for a process that was already running when the grant
    /// landed.
    ///
    /// Nothing here assumes WHICH permissions need a restart. It measures, so
    /// the day macOS starts picking Input Monitoring up live, `tapCreate`
    /// succeeds, this goes true, and the checklist stops asking. That is the
    /// repo's rule — measured, not reasoned — applied to a moving target.
    public var isListening: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    public func start() -> Bool {
        // Already running — see note 2 above. Restarting would drop a live press.
        guard tap == nil else { return true }

        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        self.tap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        isPressed = false
        // Silent reset, no effects: stop() runs from deinit and app teardown,
        // where emitting transitions would call into a dying delegate. A
        // mid-gesture arm left behind is cleaned up by the app's own
        // teardown (applicationWillTerminate abandons the recorder).
        machine = ReplyGestureMachine()
        holdCheck?.cancel(); holdCheck = nil
        armCheck?.cancel(); armCheck = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap {
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that times out or is interrupted by user
        // input. Re-enabling is the difference between "works" and "worked until
        // the machine got busy once" — but doing it SILENTLY is why open issue
        // #15 sat unproven since 12 Aug.
        //
        // Robert pressed ⌃⌃ during an announcement and the log has zero trace of
        // it: no acknowledgement, no refusal, nothing. A press the classifier
        // REFUSES still logs; a press that leaves nothing was never seen at all.
        // His next press, one second after the speech ended, worked normally.
        //
        // This is the window it fell into. macOS disables a tap whose callback
        // is too slow — the timeout is around a second and is undocumented —
        // and during playback the main run loop is doing a full HUD render per
        // spoken word, roughly fifteen times a second, on the same run loop the
        // tap delivers on. The tap comes back, so nothing is broken afterwards,
        // and every gesture lost in between is uncounted and unattributable.
        // The 5s watchdog only catches a tap still dead at its tick, so a
        // sub-5s gap is invisible to it by construction.
        //
        // So the window leaves a record. Not a fix for the saturation — that is
        // the throttle half of #15 and it lives in the render path — but the
        // difference between "a gesture went missing" and "a gesture went
        // missing HERE, at 21:12:38, in the 340ms this tap was deaf, for the
        // fourth time today." An absence cannot be debugged; a timestamped
        // absence can.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            deafWindows += 1
            let since = lastDeafAt.map { String(format: " (%.1fs since the last)",
                                                Date().timeIntervalSince($0)) } ?? ""
            lastDeafAt = Date()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                let back = CGEvent.tapIsEnabled(tap: tap)
                Permissions.log("hotkey: tap went DEAF (\(reason)) — "
                    + (back ? "re-enabled" : "re-enable REFUSED")
                    + "; gestures in this window were not seen. "
                    + "deaf window #\(deafWindows)\(since)")
            } else {
                Permissions.log("hotkey: tap went DEAF (\(reason)) with no tap to revive. "
                    + "deaf window #\(deafWindows)\(since)")
            }
            return Unmanaged.passUnretained(event)
        }

        // Any other key or a click while a modifier is down means this is a real
        // shortcut — Shift-A, Control-C, Option-drag — not one of ours. If the
        // arm window was open, the machine aborts it HERE, immediately: the
        // user is typing and must not stare at an arming face until key-up.
        if type == .keyDown || type == .leftMouseDown || type == .rightMouseDown {
            if pressStartedAt != nil {
                sawOtherInput = true
                perform(machine.apply(.sawOtherInput))
            }
            return Unmanaged.passUnretained(event)
        }

        let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let held = event.flags.intersection(relevant)

        if held.isEmpty {
            endGesture()
        } else if pressStartedAt == nil {
            beginGesture(with: held)
        } else {
            // Adding a second modifier disqualifies the gesture: one modifier each
            // is the whole point, and ⌃⌥ must not be mistaken for either. An
            // open arm window aborts immediately (a hold growing into ⌃⌥).
            seenFlags.formUnion(held)
            perform(machine.apply(.flagsChanged(isReply: seenFlags == bindings.reply)))
        }

        return Unmanaged.passUnretained(event)
    }
}
