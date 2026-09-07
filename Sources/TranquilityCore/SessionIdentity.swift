import Foundation

/// What a session is called on disk, and when two spellings of its id mean
/// the same session.
///
/// A hub directory was named by the first eight characters of the session id
/// from 15 Aug to 06 Sep. That was fine for Claude Code, whose ids are random,
/// and wrong for Codex, whose ids are UUIDv7 and therefore time-ordered: two
/// threads started within about 65 seconds share those eight characters.
/// Measured 06 Sep in Codex's own database: 249 threads, 116 distinct
/// prefixes, and one hub directory (01a06cf1) holding two sessions' pages.
///
/// So the directory is the FULL id, and this is the one place that says so.
/// The eight-character form survives as a display name — a footer, a log
/// line, a grid row's aux column — and as the name of the compatibility
/// symlink the migration leaves behind, which is why `same` accepts either
/// spelling: a page stamped by the older hook declares the short form, and it
/// is still that session's page.
public enum SessionIdentity {
    /// The directory a session's pages live in.
    public static func directoryName(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The eight characters a person reads and a footer prints.
    public static func short(_ id: String) -> String { String(id.prefix(8)) }

    /// Equal, or one is the other's prefix and the shared part is at least
    /// the eight characters a short id has: "01a0" against anything is not a
    /// match, and neither is an empty string.
    public static func same(_ a: String, _ b: String) -> Bool {
        let x = directoryName(a), y = directoryName(b)
        if x == y { return !x.isEmpty }
        let (head, whole) = x.count <= y.count ? (x, y) : (y, x)
        return head.count >= 8 && whole.hasPrefix(head)
    }

    /// A directory under agents/ that names a session: eight hex characters
    /// (the legacy form, now a symlink) or a full id. `_archive` is not one.
    public static func isDirectoryName(_ name: String) -> Bool {
        name.count >= 8 && name.count <= 64
            && name.allSatisfy { $0.isHexDigit || $0 == "-" }
            && (name.first?.isHexDigit ?? false)
    }
}
