import Foundation

/// Which Terminal window an agent's tmux session was opened in.
///
/// The identity problem, stated plainly: a tty is not a unique key. Terminal
/// keeps reporting the tty of a tab whose shell has exited, and macOS recycles
/// tty device numbers, so several tabs answer to the same `/dev/ttysNNN` and
/// only one of them is alive. Measured 13 Sep on Robert's machine: 61 Terminal
/// windows, `/dev/ttys045` claimed by five of them — four corpses and the real
/// agent, which sorted last. `TerminalTabFocus` matched on tty and returned on
/// the first hit, so GO TO AGENT raised a dead canary window on all twelve
/// presses and reported `.focused` every time.
///
/// The fix is not a better filter over the same bad key (a liveness column
/// beside the tty list was the first proposal, and it is state stacked on
/// state: two scraped facts that have to agree, which is the arrangement that
/// produced this bug in the first place). The fix is to stop guessing. We
/// OPEN the window, so we know which one it is: `do script` hands back the
/// window and its `id` is Terminal's own stable handle. Keyed by tmux session
/// name because that is the durable identity of an agent's terminal — the pane
/// outlives the window, the window id outlives nothing but is cheap to remake.
///
/// In memory, deliberately, and not persisted. A window id means nothing
/// across a Terminal restart, and a file that can be wrong is worse than no
/// file: an unknown session simply opens a fresh window, which is the correct
/// answer anyway. The cost of forgetting is one extra window, once, and
/// `attach -d` makes even that self-cleaning.
public enum TerminalWindows {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var bySession: [String: Int] = [:]
        func get(_ session: String) -> Int? {
            lock.lock(); defer { lock.unlock() }
            return bySession[session]
        }
        func put(_ session: String, _ windowId: Int) {
            lock.lock(); bySession[session] = windowId; lock.unlock()
        }
        func forget(_ session: String) {
            lock.lock(); bySession.removeValue(forKey: session); lock.unlock()
        }
        func removeAll() {
            lock.lock(); bySession.removeAll(); lock.unlock()
        }
    }
    private static let store = Store()

    /// The window this session was last opened in, if we opened it.
    public static func windowId(for sessionName: String) -> Int? {
        store.get(sessionName)
    }

    /// Remember the window an attach just landed in.
    public static func remember(sessionName: String, windowId: Int) {
        store.put(sessionName, windowId)
    }

    /// The window is gone, or was never ours. The next focus opens a fresh one.
    public static func forget(sessionName: String) {
        store.forget(sessionName)
    }

    /// Tests only: a clean table between cases.
    public static func forgetAll() { store.removeAll() }
}
