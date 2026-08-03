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
    public enum Transition: Sendable { case pressed, released }

    /// ⌃⌥ held together. Matches Clicky's default and avoids every system chord.
    public struct Chord: Sendable {
        public var flags: CGEventFlags
        public init(flags: CGEventFlags = [.maskControl, .maskAlternate]) { self.flags = flags }

        func isSatisfied(by eventFlags: CGEventFlags) -> Bool {
            let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            return eventFlags.intersection(relevant) == flags
        }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let chord: Chord
    private let onTransition: @Sendable (Transition) -> Void

    /// Mutated only from the tap callback, which runs on the main run loop.
    public private(set) var isPressed = false

    public init(chord: Chord = Chord(), onTransition: @escaping @Sendable (Transition) -> Void) {
        self.chord = chord
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

        let satisfied = chord.isSatisfied(by: event.flags)
        if satisfied, !isPressed {
            isPressed = true
            onTransition(.pressed)
        } else if !satisfied, isPressed {
            isPressed = false
            onTransition(.released)
        }
        return Unmanaged.passUnretained(event)
    }
}
