import CoreAudio
import Foundation

/// Whether coreaudiod is answering, learned from this app's own calls.
///
/// Why (09 Sep 2026): the daemon deadlocked at 09:59 and this app sat inside
/// that condition for three minutes without a word. The mic queue was blocked
/// in a HAL read that took six consecutive 30-second Mach timeouts to fail;
/// the announcer reported "player refused to start" and stayed silent; the
/// user learned the machine was broken from Zoom's empty device picker. The
/// 28 Aug hardening kept the panel alive, which is necessary and not enough:
/// an app that survives a wedge and says nothing has survived it privately.
///
/// Two signals, no polling. Every HAL-bound entry point in Core wraps its call
/// in `timed`, which arms a five-second watchdog on its own queue: a call that
/// has not returned by then means the daemon is wedged, whatever it eventually
/// says. And a call that does return with a Mach timeout code (`0x10004003`
/// MACH_RCV_TIMED_OUT, `0x10000004` MACH_SEND_TIMED_OUT, the two codes every
/// process logged on 09 Sep) says the same thing thirty seconds later. Either
/// way the app knows within seconds of its first attempt, not minutes.
///
/// No periodic probe, because an idle app makes no HAL call (the rule that
/// arrived with `AudioSystemWatch`). The one proactive check is a single read
/// ten seconds after a device mutation, which is the moment the 09 Sep wedge
/// began and the one moment worth one round trip.
public final class AudioSystemHealth: @unchecked Sendable {
    public static let shared = AudioSystemHealth()

    public enum State: Sendable, Equatable {
        case answering
        case wedged(since: Date)

        public var isWedged: Bool {
            if case .wedged = self { return true }
            return false
        }
    }

    /// Longer than any healthy HAL call measured here (p99 1011 ms, max
    /// 2081 ms with six devices and AirPods, 18 Aug) and shorter than the
    /// 30-second Mach timeout by enough to matter to a person waiting.
    public static let stallThreshold: TimeInterval = 5.0
    /// How long after a device mutation the one proactive read happens.
    public static let probeAfterMutation: TimeInterval = 10.0

    static let machReceiveTimedOut: OSStatus = 0x10004003
    static let machSendTimedOut: OSStatus = 0x10000004

    /// A code that means "the daemon did not answer", as opposed to "the
    /// daemon said no".
    public static func isTimeout(_ status: OSStatus) -> Bool {
        status == machReceiveTimedOut || status == machSendTimedOut
    }

    private let lock = NSLock()
    private var state: State = .answering
    private var subscribers: [@Sendable (State) -> Void] = []
    private let queue = DispatchQueue(label: "base.tranquility.audio-health")
    private let stall: TimeInterval
    private var watching = false

    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    init(stallThreshold: TimeInterval = AudioSystemHealth.stallThreshold) {
        self.stall = stallThreshold
    }

    public var current: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Hear every change, on the health queue. Hop to your own owner.
    public func subscribe(_ handler: @escaping @Sendable (State) -> Void) {
        lock.lock(); subscribers.append(handler); lock.unlock()
    }

    /// Wire the proactive read to the system watch. Idempotent.
    public func watchMutations(_ watch: AudioSystemWatch = .shared) {
        lock.lock()
        let first = !watching
        watching = true
        lock.unlock()
        guard first else { return }
        watch.start()
        watch.subscribe { [weak self] kind in
            guard let self, kind == .devices || kind == .defaultOutput else { return }
            self.queue.asyncAfter(deadline: .now() + Self.probeAfterMutation) { [weak self] in
                self?.probe(because: "\(kind.rawValue) changed")
            }
        }
    }

    /// Run a HAL-bound call under the watchdog. The call itself is not
    /// interrupted, because a HAL call cannot be; what changes is that the
    /// app learns it is stuck five seconds in, instead of when it fails.
    @discardableResult
    public func timed<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
        let began = Date()
        let watchdog = DispatchWorkItem { [weak self] in
            self?.declare(.wedged(since: began), because: "\(what) has not returned in \(Int(self?.stall ?? 5))s")
        }
        queue.asyncAfter(deadline: .now() + stall, execute: watchdog)
        defer {
            watchdog.cancel()
            let took = Date().timeIntervalSince(began)
            if took < stall { declare(.answering, because: "\(what) returned in \(Int(took * 1000))ms") }
        }
        return try body()
    }

    /// A HAL call returned. A Mach timeout code is the daemon not answering;
    /// anything else, including a plain error, is the daemon answering.
    public func note(_ status: OSStatus, from what: String) {
        if Self.isTimeout(status) {
            declare(.wedged(since: Date()), because: String(format: "%@ returned 0x%08x", what, status))
        } else {
            declare(.answering, because: "\(what) answered")
        }
    }

    /// One read of the device list under the watchdog, off the caller's
    /// thread. The recovery path calls this to confirm the restart worked.
    public func probe(because reason: String) {
        queue.async { [self] in
            // On a different thread than the watchdog's queue, deliberately:
            // a probe that blocks must not block the timer that reports it.
            let thread = Thread { [self] in
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                var size: UInt32 = 0
                let status = timed("probe (\(reason))") {
                    AudioObjectGetPropertyDataSize(
                        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
                }
                note(status, from: "probe")
            }
            thread.name = "audio-health-probe"
            thread.start()
        }
    }

    private func declare(_ new: State, because reason: String) {
        lock.lock()
        let old = state
        // A wedge keeps its first timestamp; only the direction of change is news.
        let changed: Bool
        switch (old, new) {
        case (.answering, .answering): changed = false
        case (.wedged, .wedged): changed = false
        default: changed = true
        }
        if changed { state = new }
        let handlers = subscribers
        lock.unlock()
        guard changed else { return }
        Self.trace?("audio-health: \(new.isWedged ? "WEDGED" : "answering") (\(reason))")
        for handler in handlers { handler(new) }
    }
}

/// The one repair for a wedged daemon, behind the standard macOS password
/// sheet. `killall coreaudiod` holds no user data; launchd relaunches it in
/// about a second and every client reconnects (measured twice on 09 Sep,
/// once with a capture open). It needs root, and the only root a user's Mac
/// hands an app is this sheet, so this is what the card's button does.
public enum AudioSystemRecovery {
    public enum Outcome: Sendable, Equatable {
        case restarted
        case declined
        case failed(String)
    }

    /// Runs the privileged restart. Blocks its thread while the sheet is up,
    /// so callers run it detached, never on the main actor.
    public static func restartDaemon() -> Outcome {
        let source = "do shell script \"/usr/bin/killall coreaudiod\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return .failed("could not build the script") }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .restarted }
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -128 { return .declined }
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "error \(code)"
        return .failed(message)
    }
}
