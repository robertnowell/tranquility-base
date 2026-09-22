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
/// ManagedCreditSession publishes this view. Historical receipts are never a
/// balance source; balance checks are explicit at sign-in and after summaries.
public enum CreditStanding: Sendable, Equatable {
    /// This Mac is not on credits and nothing is wrong: not connected to a
    /// hub, or paired before key binding. Summaries use whatever it has.
    case notOnCredits(connectAgain: Bool)
    /// Signed in, but authority and account readiness are still being checked.
    case onCredits
    /// Balance from the account endpoint, not an operation's historical receipt.
    case good(availableMicros: String, at: Date)
    /// Summaries are running on credits and the last one was paid for, but
    /// the balance could not be refreshed afterwards. Not a floor: nothing
    /// fell back and nothing is owed; only the number is stale. Audit A10
    /// found this shown as "credits unavailable", which was untrue.
    case balanceUnknown(at: Date)
    /// The server said credits cannot be spent, and why. Only an answer
    /// from the server lands here, and the reason names the resolution.
    ///
    /// Ruled 22 Sep: this is an account state, not a health report. A request
    /// that could not get through (offline, gateway down, a provider that
    /// failed one summary) says nothing about the account, so it changes
    /// nothing here; the last known standing holds. Offline is Connectivity's
    /// to show, and a gateway fault is ours to fix, not the person's. The two
    /// lines that used to say so ("Credits unavailable right now", "Last
    /// summary fell back, not charged") were amber with nothing to do.
    case floored(Reason, at: Date)

    public enum Reason: Sendable, Equatable {
        /// The grant is spent. Not a fault; a state with a door.
        case outOfCredits
        /// The hub refused or revoked this Mac. Pair it again.
        case connectAgain
    }

    /// The amber line, short enough for the placard. Nil when nothing is amber.
    public var line: String? { line(ownKey: false) }

    /// The same, knowing whether the person has a key of their own.
    ///
    /// Out of credits with a pasted key is not a fault: the chain moves onto
    /// that key and summaries carry on. Robert, 19 Sep, seeing the amber line
    /// beside a green Anthropic row: "if I have an Anthropic key then it
    /// shouldn't be an error". The state stays what it is, out of credits; the
    /// alarm is for the person with nothing to fall to.
    public func line(ownKey: Bool) -> String? {
        switch self {
        case .floored(.outOfCredits, _) where ownKey: return nil
        // Each line names the thing to do, not the thing that went wrong
        // (ruled 22 Sep: "positive, not error-focused"). Out of credits
        // reads "Add credits" by Robert's ruling the same day, although
        // nothing sells credits yet: the door opens Settings, whose detail
        // says buying is coming and a key keeps summaries going meanwhile.
        case .notOnCredits(connectAgain: true): return "Sign in for credits"
        case .notOnCredits, .onCredits, .good, .balanceUnknown: return nil
        case .floored(.outOfCredits, _): return "Add credits"
        case .floored(.connectAgain, _): return "Sign in for credits"
        }
    }

    /// The Settings row's detail: what is true and what to do.
    public var detail: String { detail(ownKey: false) }

    public func detail(ownKey: Bool) -> String {
        switch self {
        case .floored(.outOfCredits, _) where ownKey:
            return "starting credits used · summaries run on your own Anthropic key. Buying more credits is coming"
        case .notOnCredits(connectAgain: false):
            return "sign in to your hub and summaries run on us, ten dollars to start"
        case .notOnCredits(connectAgain: true), .floored(.connectAgain, _):
            return "sign in with your hub account and summaries run on credits"
        case .onCredits:
            return "signed in · checking credits"
        case let .good(micros, _):
            return "\(Self.dollars(micros)) at last balance check · summaries use credits"
        case .balanceUnknown:
            return "summaries use credits · the last one was paid for; the balance could not be refreshed and will be at the next"
        case .floored(.outOfCredits, _):
            return "starting credits used. Buying credits is coming; until then your own Anthropic key keeps summaries going"
        }
    }

    /// Verified on credits with the last summary paid for: a known balance,
    /// or a balance that merely could not be refreshed. What waives the
    /// personal key and what paints the row green.
    public var isOnCredits: Bool {
        switch self {
        case .good, .balanceUnknown: return true
        case .notOnCredits, .onCredits, .floored: return false
        }
    }

    /// Whether the row is the person's to act on now.
    public var needsAttention: Bool { needsAttention(ownKey: false) }

    public func needsAttention(ownKey: Bool) -> Bool {
        switch self {
        case .floored(.outOfCredits, _) where ownKey: return false
        case .notOnCredits(connectAgain: true), .floored(.outOfCredits, _), .floored(.connectAgain, _): return true
        case .notOnCredits, .onCredits, .good, .balanceUnknown: return false
        }
    }

    /// The standing's name for telemetry. Never carries the balance.
    public var token: String {
        switch self {
        case .notOnCredits(connectAgain: true): return "sign_in_needed"
        case .notOnCredits: return "not_on_credits"
        case .onCredits: return "checking"
        case .good: return "on_credits"
        case .balanceUnknown: return "balance_unknown"
        case .floored(.outOfCredits, _): return "out_of_credits"
        case .floored(.connectAgain, _): return "sign_in_needed"
        }
    }

    static func dollars(_ micros: String) -> String {
        guard let value = Int64(micros) else { return "$?" }
        let cents = (value + 5_000) / 10_000
        return String(format: "$%lld.%02lld", cents / 100, cents % 100)
    }

    // MARK: - From a summary

    /// What one finished summary says about the standing, or nil when it says
    /// nothing: a summary that never went near credits, or a failure that is
    /// not an answer about the account (unreachable, timed out, a provider
    /// fault, a malformed reply). Nil keeps the last known standing.
    public static func from(receipt: GatewayReceipt?, failure: ManagedSummaryFailure?,
                            provider: String, now: Date = Date()) -> CreditStanding? {
        // A successful replay says nothing about today's balance or access.
        // Failures still take precedence even if a caller also has a receipt.
        guard let failure else { return nil }
        switch failure {
        case let .refused(code, _):
            switch code {
            case "insufficient_credit": return .floored(.outOfCredits, at: now)
            case "rebinding_required", "not_connected":
                // Not a floor: the chain went on to the person's own key.
                return .notOnCredits(connectAgain: code == "rebinding_required")
            case "connection_rejected", "auth_required": return .floored(.connectAgain, at: now)
            default: return nil
            }
        case .pending, .outcomeUnknown, .invalidResponse: return nil
        case .missingSourceIdentity, .sourceIdentityConflict, .correctiveRetryNotAllowed: return nil
        }
    }

    // MARK: - The one current standing

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current_: CreditStanding = .notOnCredits(connectAgain: false)
    nonisolated(unsafe) private static var observers: [UUID: @Sendable (CreditStanding) -> Void] = [:]
    nonisolated(unsafe) private static var isCurrent: @Sendable () -> Bool = { true }

    public static var current: CreditStanding {
        lock.lock(); let value = current_; let valid = isCurrent; lock.unlock()
        return valid() ? value : .notOnCredits(connectAgain: false)
    }

    /// Replace the standing and tell whoever is listening, if it changed.
    static func set(_ standing: CreditStanding, isCurrent valid: @escaping @Sendable () -> Bool = { true }) {
        lock.lock()
        let changed = standing != current_
        current_ = standing
        isCurrent = valid
        let listeners = Array(observers.values)
        lock.unlock()
        guard changed else { return }
        // The product stream sees every change of standing, as a token: no
        // amounts, no account. Before 22 Sep a Mac could sit out of credits
        // or signed out and nothing off the machine knew.
        Track.record("credit_standing", ["standing": .token(standing.token)])
        for listener in listeners { listener(standing) }
    }

    @discardableResult
    public static func observe(_ listener: @escaping @Sendable (CreditStanding) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = listener; lock.unlock()
        listener(current)
        return id
    }

    public static func removeObserver(_ id: UUID) {
        lock.lock(); observers.removeValue(forKey: id); lock.unlock()
    }

    /// Test isolation only. Session changes publish a new standing without
    /// disconnecting the UI's observers.
    public static func reset() {
        lock.lock(); current_ = .notOnCredits(connectAgain: false); isCurrent = { true }; observers = [:]; lock.unlock()
    }
}
