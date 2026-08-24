import Foundation

/// An agent that has been launched but has not told us its name yet.
///
/// Pressing + NEW AGENT does two things that are not synchronised. The panel
/// paints a card and speaks its question in milliseconds — ruled 18 Aug, and
/// right, because the one moment you always know what you want to say is the
/// moment you started the agent. Meanwhile Terminal opens a window, Claude Code
/// boots, and the session finally announces itself to `claude agents --json`.
/// That second half measured five to nine seconds across every launch in the
/// 18 Aug log.
///
/// Answer the card inside that window — three seconds in, on one occasion — and
/// the app had no id for the new agent, so the reply fell back to whoever you
/// were last talking to and was typed into THAT agent. Three times in one
/// evening, once into a session in a different repository, and silently every
/// time. The gap is not going to close: it is Terminal and a CLI starting up,
/// against a person answering a question they were just asked.
///
/// So the words wait for the agent instead of being handed to a different one.
/// This is the promise they wait on: one launch, resolved once, by whichever
/// comes first — the session registering, or the launch being abandoned.
///
/// Lives in Core rather than beside the launcher that creates it: it is pure
/// state with no AppKit in it, and Core is the layer that has unit tests. The
/// app layer's only evidence is the launch drills, which cannot exercise a
/// promise's timeout.
///
/// `@unchecked Sendable` with a lock rather than an actor: the resolve arrives
/// on a detached launcher task and the await happens on the main actor, and an
/// actor hop in the middle of the reply path buys nothing over one `NSLock`
/// around three fields.
public final class PendingLaunch: @unchecked Sendable {
    /// The directory the agent was started in — the only name it has until it
    /// registers, and what the panel shows while you talk to it.
    public let label: String
    public let directory: String
    public let startedAt: Date

    /// The session you were in when + NEW AGENT was pressed, or nil if you were
    /// in none.
    ///
    /// Stored on the launch rather than kept as a local in `newSession`,
    /// because it is a fact ABOUT THE LAUNCH and two moments need it: the
    /// adoption at registration, and — since 24 Aug — the microphone. It was a
    /// stack local, so the microphone could not see it, and that is half of why
    /// the microphone was left asking `isPending` instead of asking the real
    /// question.
    public let conversationAtLaunch: String?

    private let lock = NSLock()
    private var sessionId: String?
    private var abandoned = false
    private var settled = false
    private var waiters: [UUID: CheckedContinuation<String?, Never>] = [:]

    public init(label: String, directory: String,
                conversationAtLaunch: String?, startedAt: Date = Date()) {
        self.label = label
        self.directory = directory
        self.conversationAtLaunch = conversationAtLaunch
        self.startedAt = startedAt
    }

    /// True while the agent has neither arrived nor been given up on.
    public var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return sessionId == nil && !abandoned
    }

    /// Whether this launch still owns where your words go.
    ///
    /// NOT the same question as `isPending`, and conflating them is exactly the
    /// 24 Aug misroute. `isPending` asks whether the agent has an id yet;
    /// `resolve` answers it on a detached launcher task the instant
    /// `claude agents --json` reports the session. But the DESTINATION is
    /// handed over one main-actor hop later, in the adoption block, and in the
    /// gap between the two `isPending` was false while the panel's
    /// `activeConversation` still named the previous agent. The microphone
    /// opened in that gap, found no branch that matched, and addressed the
    /// capture to whoever had spoken last.
    ///
    /// So the claim expires when it is ANSWERED, not when the id arrives:
    /// `abandon()` (the agent never came up, so it owns nothing) or `settle()`
    /// (the adoption ran and handed the destination to the panel, whichever way
    /// it decided). Every exit from `newSession` reaches one of those two —
    /// there is no third — which is what keeps an hour-old launch from
    /// capturing a microphone it has no business capturing.
    public var ownsTheReply: Bool {
        lock.lock(); defer { lock.unlock() }
        return !abandoned && !settled
    }

    /// The session id if it has arrived, without waiting for it.
    ///
    /// `session(timeout:)` is the right call when you are about to send and can
    /// afford to wait. This is the right call when you are DECIDING and cannot:
    /// a launch that already has an id can be addressed as a session outright,
    /// which lets the panel name the real agent while you speak.
    public var resolvedSession: String? {
        lock.lock(); defer { lock.unlock() }
        return sessionId
    }

    /// The destination question for this launch has been answered.
    ///
    /// Called from the adoption block on BOTH branches — the launch took the
    /// reply, or you had moved on and it did not. Either way the answer now
    /// lives in the panel's `activeConversation`, and the launch stops being
    /// consulted. Idempotent, like `resolve` and for the same reason.
    public func settle() {
        lock.lock(); defer { lock.unlock() }
        settled = true
    }

    /// The session, once Claude Code has minted it. Idempotent: a second call
    /// changes nothing, because a launch names one session for its whole life.
    public func resolve(sessionId id: String) {
        lock.lock()
        guard sessionId == nil, !abandoned else { lock.unlock(); return }
        sessionId = id
        let pending = waiters
        waiters = [:]
        lock.unlock()
        for (_, waiter) in pending { waiter.resume(returning: id) }
    }

    /// The agent never came up — the trust prompt was never answered, Terminal
    /// refused, the watcher timed out. Every waiter is released with nothing,
    /// which is what makes the failure card honest rather than a hang.
    public func abandon() {
        lock.lock()
        guard sessionId == nil, !abandoned else { lock.unlock(); return }
        abandoned = true
        settled = true
        let pending = waiters
        waiters = [:]
        lock.unlock()
        for (_, waiter) in pending { waiter.resume(returning: nil) }
    }

    /// Wait for the session id, up to `timeout`. Returns nil if the launch was
    /// abandoned or the wait ran out.
    ///
    /// Returns immediately in the common case: by the time a reply has been
    /// spoken and transcribed, a launch that started while you were drawing
    /// breath has usually long since registered.
    ///
    /// One continuation with a timer beside it, rather than a task group racing
    /// a sleeper against a waiter. The task-group shape deadlocks: a
    /// `withCheckedContinuation` child cannot be cancelled, so when the sleeper
    /// wins the group waits forever for a waiter nobody will ever resume. It
    /// hung the test suite exactly once, which was enough.
    public func session(timeout: TimeInterval) async -> String? {
        switch settledNow() {
        case .arrived(let id): return id
        case .gone: return nil
        case nil: break
        }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            var immediate: String??
            lock.lock()
            if let sessionId { immediate = .some(sessionId) }
            else if abandoned { immediate = .some(nil) }
            else { waiters[token] = continuation }
            lock.unlock()
            // Resolved between the fast path and the lock — resume rather than
            // registering a waiter nothing will ever wake.
            if let immediate { continuation.resume(returning: immediate); return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.expire(token)
            }
        }
    }

    /// Give up on ONE waiter without giving up on the launch: the reply that
    /// waited has run out of patience, but the agent may still be coming, and
    /// another utterance may still be waiting on it.
    private func expire(_ token: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: token)
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    /// Whether this launch has an answer yet, and what it is.
    ///
    /// `.pending` is not the same as `.gone`, which is why this is an enum and
    /// not an optional-of-optional: one means keep waiting, the other means
    /// stop and say so.
    private enum Settled { case arrived(String), gone }

    private func settledNow() -> Settled? {
        lock.lock(); defer { lock.unlock() }
        if let sessionId { return .arrived(sessionId) }
        if abandoned { return .gone }
        return nil
    }
}
