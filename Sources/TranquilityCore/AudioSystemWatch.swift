import CoreAudio
import Foundation

/// One listener on the HAL system object, for the three facts every audio
/// client in this app needed and none of them had: the device list changed,
/// a default device changed, the audio daemon restarted.
///
/// Why (09 Sep 2026, research HQ: coreaudiod-wedge-zoom-airpods): Zoom's
/// share-computer-sound swapped the default output to its virtual device at
/// 09:58:14, its Voice Isolation negotiation failed inside coreaudiod, and
/// the daemon deadlocked a minute later. The one thing this app did inside
/// that minute was start and stop two audio queues on the freshly-swapped
/// default output. Nothing in the log says that completed the deadlock;
/// nothing says it did not. Three trials the same morning, one deadlock, with
/// the app idle, quit, and open respectively: the app is not the switch, so
/// the most it can do is stay out of other apps' device mutations and
/// survive the daemon restart that fixes them. This type is how it learns
/// that a mutation is in progress, and how the speakers wait for it to
/// settle.
///
/// The system object is watched, not the bound device: `Recorder` already
/// listens on its own device for the Bluetooth profile flip; this is the
/// layer above it, the facts that are true for every device at once.
public final class AudioSystemWatch: @unchecked Sendable {
    public static let shared = AudioSystemWatch(installing: true)

    public enum Mutation: String, Sendable {
        case devices, defaultOutput, defaultInput, serviceRestarted
    }

    /// How long the speakers stay quiet after a mutation. Pure, so the table
    /// has tests: `settle` is the time a route change takes to stop moving
    /// (the mic rebuild already waits 2 s for a format change; the output
    /// side gets a little more because it is the one that reached into the
    /// mutation on 09 Sep), and `cap` is the most a single wait may total
    /// however many mutations arrive during it. A device flapping its route
    /// (AirPods Pro, 199 times in two hours on 28 Aug) must delay an
    /// announcement, never silence the app.
    public struct Hold: Sendable, Equatable {
        public var settle: TimeInterval
        public var cap: TimeInterval
        public init(settle: TimeInterval = 3.0, cap: TimeInterval = 6.0) {
            self.settle = settle
            self.cap = cap
        }

        /// Seconds still to wait before the speakers may be touched.
        public func remaining(lastMutation: Date?, now: Date, waitingSince: Date) -> TimeInterval {
            guard let lastMutation else { return 0 }
            let wanted = settle - now.timeIntervalSince(lastMutation)
            let allowed = cap - now.timeIntervalSince(waitingSince)
            return max(0, min(wanted, allowed))
        }
    }

    private let queue = DispatchQueue(label: "base.tranquility.audio-system-watch")
    private let lock = NSLock()
    private var lastKind: Mutation?
    private var lastAt: Date?
    private var subscribers: [@Sendable (Mutation) -> Void] = []
    private var installed = false
    private let installing: Bool
    private var block: AudioObjectPropertyListenerBlock?

    /// `installing: false` is the test seam: a watch that never touches the
    /// HAL and is fed by `noteMutation`.
    init(installing: Bool) {
        self.installing = installing
    }

    /// Register the listeners, once, off the caller's thread. Idempotent;
    /// every owner that depends on the watch calls it and the first wins.
    public func start() {
        guard installing else { return }
        lock.lock()
        let first = !installed
        installed = true
        lock.unlock()
        guard first else { return }
        queue.async { [self] in
            let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
                for i in 0..<Int(count) {
                    let kind: Mutation
                    switch addresses[i].mSelector {
                    case kAudioHardwarePropertyDevices: kind = .devices
                    case kAudioHardwarePropertyDefaultOutputDevice: kind = .defaultOutput
                    case kAudioHardwarePropertyDefaultInputDevice: kind = .defaultInput
                    case kAudioHardwarePropertyServiceRestarted: kind = .serviceRestarted
                    default: continue
                    }
                    self?.noteMutation(kind)
                }
            }
            self.block = block
            for selector in [kAudioHardwarePropertyDevices,
                             kAudioHardwarePropertyDefaultOutputDevice,
                             kAudioHardwarePropertyDefaultInputDevice,
                             kAudioHardwarePropertyServiceRestarted] {
                var addr = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            }
        }
    }

    /// Hear every mutation, on the watch's queue. Subscribers hop to their
    /// own owner before touching anything; nothing here is `audioQueue`.
    public func subscribe(_ handler: @escaping @Sendable (Mutation) -> Void) {
        lock.lock(); subscribers.append(handler); lock.unlock()
    }

    /// The most recent mutation, if any.
    public var lastMutation: (kind: Mutation, at: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let lastKind, let lastAt else { return nil }
        return (lastKind, lastAt)
    }

    /// Record a mutation. Internal so tests can stage one; production hears
    /// them from the HAL.
    func noteMutation(_ kind: Mutation, at: Date = Date()) {
        lock.lock()
        lastKind = kind
        lastAt = at
        let handlers = subscribers
        lock.unlock()
        for handler in handlers { handler(kind) }
    }

    /// Wait until the speakers may be touched: `hold.settle` seconds after
    /// the last mutation, or `hold.cap` seconds in total, whichever comes
    /// first. Returns at once when nothing has moved. Says so on the trace
    /// when it actually held, because a held announcement must be
    /// distinguishable from a slow one in app.log.
    public func settle(_ hold: Hold = Hold(), trace: ((String) -> Void)? = nil) async {
        let began = Date()
        var held = false
        while true {
            let last = lastMutation
            let wait = hold.remaining(lastMutation: last?.at, now: Date(), waitingSince: began)
            guard wait > 0.01 else { break }
            if !held, let last {
                held = true
                trace?(String(format: "speakers held %.1fs: %@ changed %.1fs ago",
                              wait, last.kind.rawValue, Date().timeIntervalSince(last.at)))
            }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        if held {
            trace?(String(format: "speakers released after %.1fs", Date().timeIntervalSince(began)))
        }
    }
}
