import Foundation
import Network

/// Whether this Mac has a route to the internet, and a call when it gets one.
///
/// Earned 22 Sep: the app launched at login a few seconds after boot, before
/// Wi-Fi had joined, and the credits balance check failed at once with "The
/// Internet connection appears to be offline". The grid said credits were
/// unavailable when they were fine. A check that can only fail without a
/// network waits for one, and runs again whenever the network comes back.
public final class NetworkPath: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "base.tranquility.network-path")
    private var satisfied: Bool?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let onReconnect: @Sendable () -> Void

    /// `onReconnect` runs on every offline-to-online transition after the first reading.
    public init(onReconnect: @escaping @Sendable () -> Void = {}) {
        self.onReconnect = onReconnect
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    private func update(_ now: Bool) {
        let before = satisfied
        satisfied = now
        guard now else { return }
        let ready = waiters; waiters = []
        ready.forEach { $0.resume() }
        if before == false { onReconnect() }
    }

    /// Returns once the network is up, or after `timeout`, whichever is first.
    public func waitUntilOnline(timeout: Duration = .seconds(60)) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.queue.async {
                        if self.satisfied == true { continuation.resume() }
                        else { self.waiters.append(continuation) }
                    }
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
            // A waiter still parked after the timeout is released here so it
            // cannot leak; resuming it later would be a double resume.
            self.queue.sync { let parked = self.waiters; self.waiters = []; parked.forEach { $0.resume() } }
        }
    }
}
