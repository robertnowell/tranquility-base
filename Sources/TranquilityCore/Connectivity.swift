import Foundation
import Network

/// Whether this Mac can reach the internet. One monitor for the whole app.
///
/// Ruled 22 Sep. The app launched at login a few seconds after boot, before
/// Wi-Fi had joined, and the credits check failed at once with "The Internet
/// connection appears to be offline". Nothing in the app knew what offline
/// was, so the failure surfaced as the only state it could reach: amber text
/// saying credits were unavailable. Offline is not a credits state, not a
/// sign-in state, and not a fault. It is its own state, and it is this one.
///
/// Two readings, for two different questions:
///
/// - `isReachable` is the raw path, right now. Features ask it before trying
///   the network, and `onReconnect` runs whenever it goes from no to yes, so
///   work that could not happen offline happens as soon as it can.
/// - `isOffline` is what the person sees. It turns true only after the path
///   has been down for `debounce` without a break, so a blip, a Wi-Fi
///   handover, or the seconds before Wi-Fi joins at login show nothing.
public final class Connectivity: @unchecked Sendable {
    /// The app's one instance. Nil until the app starts it; readers treat
    /// that as reachable, so tests and tools that never start it are online.
    nonisolated(unsafe) public private(set) static var shared: Connectivity?

    /// True unless the app's monitor has seen the path down.
    public static var isReachable: Bool { shared?.isReachable ?? true }

    public static func start(debounce: TimeInterval = 10) -> Connectivity {
        if let shared { return shared }
        let made = Connectivity(debounce: debounce)
        made.monitor = NWPathMonitor()
        made.monitor?.pathUpdateHandler = { [weak made] path in made?.ingest(path.status == .satisfied) }
        made.monitor?.start(queue: made.queue)
        shared = made
        return made
    }

    /// Test isolation only: install a monitor-less instance, or clear it.
    static func installForTesting(_ instance: Connectivity?) { shared = instance }

    private let queue = DispatchQueue(label: "base.tranquility.connectivity")
    private let debounce: TimeInterval
    private var monitor: NWPathMonitor?
    private var reachable: Bool?
    private var offline = false
    private var goingOffline: DispatchWorkItem?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var reconnectListeners: [UUID: @Sendable () -> Void] = [:]
    private var offlineListeners: [UUID: @Sendable (Bool) -> Void] = [:]

    /// Seam for tests: no monitor, readings arrive through `ingest`.
    init(debounce: TimeInterval) {
        self.debounce = debounce
        queue.setSpecific(key: Self.onQueue, value: true)
    }

    /// Listeners hear changes in order, off the monitor's queue.
    private let delivery = DispatchQueue(label: "base.tranquility.connectivity.delivery")

    deinit { monitor?.cancel() }

    public var isReachable: Bool { queue.sync { reachable ?? true } }
    public var isOffline: Bool { queue.sync { offline } }

    /// Runs on every transition from unreachable to reachable.
    @discardableResult
    public func onReconnect(_ listener: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        queue.sync { reconnectListeners[id] = listener }
        return id
    }

    /// Hears the debounced display state now and on every change.
    @discardableResult
    public func observeOffline(_ listener: @escaping @Sendable (Bool) -> Void) -> UUID {
        let id = UUID()
        let now: Bool = queue.sync { offlineListeners[id] = listener; return offline }
        listener(now)
        return id
    }

    /// Returns once the path is reachable, or after `timeout`.
    public func waitUntilReachable(timeout: Duration = .seconds(60)) async {
        let id = UUID()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.queue.async {
                        if self.reachable != false { continuation.resume() }
                        else { self.waiters[id] = continuation }
                    }
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
            // Release this call's waiter if the timeout won, so it cannot leak.
            self.queue.sync { self.waiters.removeValue(forKey: id)?.resume() }
        }
    }

    /// One reading of the path. The monitor calls this on `queue`; tests call
    /// it directly.
    func ingest(_ satisfied: Bool) {
        if DispatchQueue.getSpecific(key: Self.onQueue) == nil {
            queue.sync { apply(satisfied) }
        } else {
            apply(satisfied)
        }
    }

    private static let onQueue = DispatchSpecificKey<Bool>()

    private func apply(_ satisfied: Bool) {
        let before = reachable
        reachable = satisfied
        if satisfied {
            goingOffline?.cancel(); goingOffline = nil
            let ready = waiters; waiters = [:]
            ready.values.forEach { $0.resume() }
            setOffline(false)
            if before == false {
                let listeners = Array(reconnectListeners.values)
                delivery.async { listeners.forEach { $0() } }
            }
        } else if goingOffline == nil, !offline {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.reachable == false else { return }
                self.goingOffline = nil
                self.setOffline(true)
            }
            goingOffline = item
            queue.asyncAfter(deadline: .now() + debounce, execute: item)
        }
    }

    private func setOffline(_ value: Bool) {
        guard offline != value else { return }
        offline = value
        let listeners = Array(offlineListeners.values)
        delivery.async { listeners.forEach { $0(value) } }
    }
}
