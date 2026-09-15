import Foundation

/// Where this Mac stands with its credits, as one app-level state.
///
/// Ruled 15 Sep: a summary that falls to the floor must never look like a
/// broken prompt. The first real credited summaries failed twice in an hour
/// for reasons outside the app, and what Robert saw was a flat card with a
/// callsign and no ladder, which he read as a prompt regression. The app knew
/// exactly what had happened and said nothing. So: one standing, kept here,
/// shown as an amber line the person can press, with a Settings row that
/// says what to do about it.
///
/// The standing is derived from summaries as they finish, never from a poll:
/// there is nothing to know about credits between two summaries that the
/// last one did not already say.
public enum CreditStanding: Sendable, Equatable {
    /// This Mac is not on credits and nothing is wrong: not connected to a
    /// hub, or paired before key binding. Summaries use whatever it has.
    case notOnCredits(connectAgain: Bool)
    /// This Mac can spend and nothing has happened yet this launch: the
    /// balance is not known until the first receipt.
    case onCredits
    /// Summaries are running on credits. The balance is the last receipt's.
    case good(availableMicros: String, at: Date)
    /// The last managed summary did not happen on credits. The reason names
    /// the resolution, which is the only thing worth showing.
    case floored(Reason, at: Date)

    public enum Reason: Sendable, Equatable {
        /// The grant is spent. Not a fault; a state with a door.
        case outOfCredits
        /// The hub refused or revoked this Mac. Pair it again.
        case connectAgain
        /// Hub or Gateway unreachable, or unable to mint. Nothing to do.
        case serviceUnavailable
        /// The Gateway admitted the summary and the provider failed it.
        /// Charged nothing. Nothing to do.
        case summaryFailed
    }

    /// The amber line, short enough for the placard. Nil when nothing is amber.
    public var line: String? {
        switch self {
        case .notOnCredits(connectAgain: true): return "Connect this Mac again for credits"
        case .notOnCredits, .onCredits, .good: return nil
        case .floored(.outOfCredits, _): return "Out of credits"
        case .floored(.connectAgain, _): return "Connect this Mac again for credits"
        case .floored(.serviceUnavailable, _): return "Credits unavailable right now"
        case .floored(.summaryFailed, _): return "Last summary fell back, not charged"
        }
    }

    /// The Settings row's detail: what is true and what to do.
    public var detail: String {
        switch self {
        case .notOnCredits(connectAgain: false):
            return "sign in to your hub and summaries run on us, ten dollars to start"
        case .notOnCredits(connectAgain: true), .floored(.connectAgain, _):
            return "this Mac was connected before credits existed. Sign in again and it is on credits"
        case .onCredits:
            return "summaries run on credits · balance after the next one"
        case let .good(micros, _):
            return "\(Self.dollars(micros)) available · summaries run on credits"
        case .floored(.outOfCredits, _):
            return "out of credits. Top-ups are coming; until then your own Anthropic key keeps summaries going"
        case .floored(.serviceUnavailable, _):
            return "the credits service could not be reached. Summaries use the built-in floor until it is back; nothing to do"
        case .floored(.summaryFailed, _):
            return "the last summary could not be produced on credits and was not charged. The next one tries again"
        }
    }

    /// Whether the row is the person's to act on now.
    public var needsAttention: Bool {
        switch self {
        case .notOnCredits(connectAgain: true), .floored(.outOfCredits, _), .floored(.connectAgain, _): return true
        case .floored(.serviceUnavailable, _), .floored(.summaryFailed, _): return true
        case .notOnCredits, .onCredits, .good: return false
        }
    }

    static func dollars(_ micros: String) -> String {
        guard let value = Int64(micros) else { return "$?" }
        let cents = (value + 5_000) / 10_000
        return String(format: "$%d.%02d", cents / 100, cents % 100)
    }

    // MARK: - From a summary

    /// What one finished summary says about the standing, or nil when it says
    /// nothing (a summary that never went near credits).
    public static func from(receipt: GatewayReceipt?, failure: ManagedSummaryFailure?,
                            provider: String, now: Date = Date()) -> CreditStanding? {
        if let receipt { return .good(availableMicros: receipt.balanceAfter.availableMicros, at: now) }
        guard let failure else { return nil }
        switch failure {
        case let .refused(code, _):
            switch code {
            case "insufficient_credit": return .floored(.outOfCredits, at: now)
            case "rebinding_required", "not_connected":
                // Not a floor: the chain went on to the person's own key.
                return .notOnCredits(connectAgain: code == "rebinding_required")
            case "connection_rejected", "auth_required": return .floored(.connectAgain, at: now)
            case "provider_failed", "cancelled": return .floored(.summaryFailed, at: now)
            default: return .floored(.serviceUnavailable, at: now)
            }
        case .pending, .outcomeUnknown, .invalidResponse: return .floored(.serviceUnavailable, at: now)
        case .missingSourceIdentity, .sourceIdentityConflict, .correctiveRetryNotAllowed:
            // The request itself was not eligible; not a standing.
            return provider == "deterministic-fallback" ? .floored(.summaryFailed, at: now) : nil
        }
    }

    // MARK: - The one current standing

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current_: CreditStanding = .notOnCredits(connectAgain: false)
    nonisolated(unsafe) private static var observers: [@Sendable (CreditStanding) -> Void] = []

    public static var current: CreditStanding {
        lock.lock(); defer { lock.unlock() }
        return current_
    }

    /// Replace the standing and tell whoever is listening, if it changed.
    public static func set(_ standing: CreditStanding) {
        lock.lock()
        let changed = standing != current_
        current_ = standing
        let listeners = observers
        lock.unlock()
        guard changed else { return }
        for listener in listeners { listener(standing) }
    }

    public static func observe(_ listener: @escaping @Sendable (CreditStanding) -> Void) {
        lock.lock(); observers.append(listener); let now = current_; lock.unlock()
        listener(now)
    }

    /// Reset, for tests and for sign-out.
    public static func reset() {
        lock.lock(); current_ = .notOnCredits(connectAgain: false); observers = []; lock.unlock()
    }
}
