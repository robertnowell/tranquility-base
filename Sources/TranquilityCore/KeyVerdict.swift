import Foundation

/// What the provider said about a key, kept so the lamp can say it too.
///
/// `KeyCheck` already asked the right question and got the right answer. The
/// answer went into one line of row text and nowhere else, so the row could
/// read "rejected by the provider (401)" beside a GREEN lamp, which is the
/// state a first-run install was actually in on 1 Sep. Robert: "shows a green
/// lamp, so that's dumb."
///
/// He is right, and the reason is that `Prerequisites` was asking a different
/// question from the one the row was answering. Its probe was `hasSecret`, so
/// the lamp meant "a key is stored" while the text beside it meant "a key
/// works". Those are the same on a good day and opposite on the day the screen
/// exists for. A lamp is the fastest thing on the row to read and the last
/// thing anyone re-reads, so when they disagree the lamp is what the person
/// walks away believing.
///
/// One verdict per key, written where the check happens, read where the lamp is
/// painted. Deliberately NOT re-checked on every scan: the scan runs on a
/// timer, and a network round trip per key per tick would be three requests a
/// second to three vendors for a row that has not changed.
///
/// THE VALUE IS NEVER HERE. This stores a verdict about a key, in the same
/// spirit as `KeyCheck` itself: nothing written by this type could reconstruct
/// a credential.
public enum KeyVerdict {

    private static func defaultsKey(_ key: Secrets.Key) -> String {
        "keycheck.verdict." + key.rawValue
    }

    /// Record what the provider said. `nil` forgets, which is what a freshly
    /// typed key deserves: the old verdict is about a credential that is no
    /// longer there.
    public static func record(_ outcome: KeyCheck.Outcome?, for key: Secrets.Key) {
        guard let outcome else {
            UserDefaults.standard.removeObject(forKey: defaultsKey(key))
            return
        }
        UserDefaults.standard.set(encode(outcome), forKey: defaultsKey(key))
    }

    /// The last thing the provider said, or nil if it was never asked.
    public static func last(for key: Secrets.Key) -> KeyCheck.Outcome? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey(key))
        else { return nil }
        return decode(raw)
    }

    /// Whether the provider looked at this key and said no.
    ///
    /// Only an outright refusal. A key that could not be checked (offline, a
    /// 500, a captive portal) is not a key that is wrong, and a lamp that goes
    /// amber on a train is a lamp nobody trusts afterwards.
    public static func isRejected(_ key: Secrets.Key) -> Bool {
        last(for: key)?.isBad ?? false
    }

    // MARK: - Encoding

    /// Flat strings rather than Codable: this is two facts, it has to survive a
    /// version of the app that added a case, and an unreadable verdict must
    /// degrade to "never checked" rather than to a crash.
    static func encode(_ outcome: KeyCheck.Outcome) -> String {
        switch outcome {
        case .working: return "working"
        case .rejected(let status): return "rejected:\(status)"
        case .unexpected(let status): return "unexpected:\(status)"
        case .unreachable: return "unreachable"
        }
    }

    static func decode(_ raw: String) -> KeyCheck.Outcome? {
        let parts = raw.split(separator: ":", maxSplits: 1)
        switch parts.first {
        case "working": return .working
        case "unreachable": return .unreachable
        case "rejected":
            guard parts.count == 2, let status = Int(parts[1]) else { return nil }
            return .rejected(status: status)
        case "unexpected":
            guard parts.count == 2, let status = Int(parts[1]) else { return nil }
            return .unexpected(status: status)
        default: return nil
        }
    }
}
