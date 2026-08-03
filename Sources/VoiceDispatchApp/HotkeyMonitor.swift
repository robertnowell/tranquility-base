import AppKit
import CoreGraphics
import Foundation

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
        /// Option, held past the threshold.
        case replyBegan
        case replyEnded
        /// The hold turned out to be part of a real shortcut. Throw the audio away.
        case replyAborted
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
        public init() {}
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let bindings = Bindings()
    private let holdThreshold: TimeInterval
    private let onTransition: @Sendable (Transition) -> Void

    /// State of the modifier press currently in progress.
    private var seenFlags: CGEventFlags = []
    private var pressStartedAt: Date?
    private var sawOtherInput = false
    private var isReplying = false
    private var holdCheck: DispatchWorkItem?

    /// Mutated only from the tap callback, which runs on the main run loop.
    public private(set) var isPressed = false

    private func beginGesture(with flags: CGEventFlags) {
        seenFlags = flags
        pressStartedAt = Date()
        sawOtherInput = false
        isReplying = false

        // Recording starts only once the hold outlives the threshold, so a tap never
        // opens the microphone.
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.pressStartedAt != nil, !self.sawOtherInput,
                  self.seenFlags == self.bindings.reply else { return }
            self.isReplying = true
            self.isPressed = true
            self.onTransition(.replyBegan)
        }
        holdCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: check)
    }

    private func endGesture() {
        holdCheck?.cancel()
        holdCheck = nil
        guard let started = pressStartedAt else { return }
        let duration = Date().timeIntervalSince(started)
        let flags = seenFlags
        let interfered = sawOtherInput
        pressStartedAt = nil
        seenFlags = []
        isPressed = false

        if isReplying {
            isReplying = false
            onTransition(interfered ? .replyAborted : .replyEnded)
            return
        }
        guard !interfered, duration < holdThreshold else { return }
        switch flags {
        case bindings.next: onTransition(.next)
        case bindings.pause: onTransition(.pauseToggled)
        default: break  // Option tapped, or two modifiers: no action.
        }
    }

    public init(
        holdThreshold: TimeInterval = 0.35,
        onTransition: @escaping @Sendable (Transition) -> Void
    ) {
        self.holdThreshold = holdThreshold
        self.onTransition = onTransition
    }

    deinit { stop() }

    public var isRunning: Bool { tap != nil }

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
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap {
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
    }

    /// Called on Escape. Set by the app; ignored when nothing is active.
    var onEscape: (() -> Void)?

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that times out or is interrupted by user input.
        // Silently re-enabling is the difference between "works" and "worked until
        // the machine got busy once".
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Escape dismisses, but only while the panel is showing something you would
        // want to stop. The tap is listen-only, so the keystroke still reaches
        // whatever is frontmost — we observe it, we do not swallow it.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            onEscape?()
            return Unmanaged.passUnretained(event)
        }

        // Any other key or a click while a modifier is down means this is a real
        // shortcut — Shift-A, Control-C, Option-drag — not one of ours.
        if type == .keyDown || type == .leftMouseDown || type == .rightMouseDown {
            if pressStartedAt != nil { sawOtherInput = true }
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
            // is the whole point, and ⌃⌥ must not be mistaken for either.
            seenFlags.formUnion(held)
        }

        return Unmanaged.passUnretained(event)
    }
}
