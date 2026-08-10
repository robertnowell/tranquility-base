import Foundation

/// The most recent page a session made, so the panel can offer to open it.
///
/// This deliberately does NOT go through the spool and the events table. Two
/// reasons, and the second is the one that matters:
///
/// 1. There is nothing to announce. An artifact is not a turn; it has no
///    summary, no callsign line, no place in the waiting queue. Putting it in
///    `events` would mean teaching every query that reads that table to exclude
///    a row type it never wants.
/// 2. `SpoolRecord.toEvent()` maps an unknown `hookEvent` to `.stop`. A new
///    event kind written by a new hook and read by an older build would
///    therefore be filed as a finished turn and SPOKEN — the user hearing a
///    summary of a file write, from a hook they installed for a button. A
///    separate file cannot do that to anyone.
///
/// So: one small file per session, holding one absolute path, replaced by
/// rename. The last writer wins, which is exactly the semantics wanted — "the
/// most recent page this agent made" — and a partial write is impossible.
public enum ArtifactStore {

    public static func directory(root: String) -> String {
        (root as NSString).appendingPathComponent("artifacts")
    }

    /// A session id is a UUID from the harness, but it arrives here from a hook
    /// payload and ends up in a path, so it is checked rather than trusted:
    /// anything but hex and dashes could escape the directory.
    static func isPlausibleSession(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    @discardableResult
    public static func record(_ path: String, session: String, root: String) -> Bool {
        guard isPlausibleSession(session), path.hasPrefix("/") else { return false }
        let dir = directory(root: root)
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let target = (dir as NSString).appendingPathComponent(session)
        // Write beside it and rename: a reader either sees the old path or the
        // new one, never half of either.
        let temp = target + ".tmp"
        guard (try? (path + "\n").write(toFile: temp, atomically: false,
                                        encoding: .utf8)) != nil else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: target),
                                                      withItemAt: URL(fileURLWithPath: temp))
        } catch {
            // replaceItemAt refuses when there is nothing to replace.
            guard (try? FileManager.default.moveItem(atPath: temp, toPath: target)) != nil
            else { try? FileManager.default.removeItem(atPath: temp); return false }
        }
        return true
    }

    /// The page to offer, or nil — and nil is the common case, so every caller
    /// must render without it.
    ///
    /// The existence check is not defensive tidiness: pages get regenerated,
    /// moved into HQ, and deleted, and a button that opens a file that is gone
    /// is worse than no button, because it spends a click to say nothing.
    public static func latest(for session: String, root: String,
                              exists: (String) -> Bool = {
                                  FileManager.default.fileExists(atPath: $0)
                              }) -> String? {
        guard isPlausibleSession(session) else { return nil }
        let target = (directory(root: root) as NSString)
            .appendingPathComponent(session)
        guard let contents = try? String(contentsOfFile: target, encoding: .utf8)
        else { return nil }
        let path = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), exists(path) else { return nil }
        return path
    }
}
