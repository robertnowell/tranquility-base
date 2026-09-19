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
        case .notOnCredits(connectAgain: true): return "Connect this Mac again for credits"
        case .notOnCredits, .onCredits, .good, .balanceUnknown: return nil
        case .floored(.outOfCredits, _): return "Out of credits"
        case .floored(.connectAgain, _): return "Connect this Mac again for credits"
        case .floored(.serviceUnavailable, _): return "Credits unavailable right now"
        case .floored(.summaryFailed, _): return "Last summary fell back, not charged"
        }
    }

    /// The Settings row's detail: what is true and what to do.
    public var detail: String { detail(ownKey: false) }

    public func detail(ownKey: Bool) -> String {
        switch self {
        case .floored(.outOfCredits, _) where ownKey:
            return "out of credits · summaries use your own Anthropic key. Top-ups are coming"
        case .notOnCredits(connectAgain: false):
            return "sign in to your hub and summaries run on us, ten dollars to start"
        case .notOnCredits(connectAgain: true), .floored(.connectAgain, _):
            return "this Mac needs to sign in again for credits; use the same hub sign-in"
        case .onCredits:
            return "signed in · checking credits"
        case let .good(micros, _):
            return "\(Self.dollars(micros)) at last balance check · summaries use credits"
        case .balanceUnknown:
            return "summaries use credits · the last one was paid for; the balance could not be refreshed and will be at the next"
        case .floored(.outOfCredits, _):
            return "out of credits. Top-ups are coming; until then your own Anthropic key keeps summaries going"
        case .floored(.serviceUnavailable, _):
            return "the credits service could not be reached. Summaries use the built-in floor until it is back; nothing to do"
        case .floored(.summaryFailed, _):
            return "the last summary could not be produced on credits and was not charged. The next one tries again"
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
        case .floored(.serviceUnavailable, _), .floored(.summaryFailed, _): return true
        case .notOnCredits, .onCredits, .good, .balanceUnknown: return false
        }
    }

    static func dollars(_ micros: String) -> String {
        guard let value = Int64(micros) else { return "$?" }
        let cents = (value + 5_000) / 10_000
        return String(format: "$%lld.%02lld", cents / 100, cents % 100)
    }

    // MARK: - From a summary

    /// What one finished summary says about the standing, or nil when it says
    /// nothing (a summary that never went near credits).
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
