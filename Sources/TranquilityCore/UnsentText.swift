import Foundation

/// Words the send path could not take, kept where they can be got back.
///
/// The second half of "we cannot ever fucking lose user input ever ever ever"
/// (29 Sep 2026). The first half was a keystroke discarded before it reached a
/// field. This is the one after: text that reached `submitTypedReply` in full
/// and was dropped on the floor by a guard.
///
///     guard let target = try store.allKnownSessions()
///         .first(where: { $0.sessionId == sessionId })
///     else { return .noTarget }      // <- the message dies here
///
/// A session the store does not know — it exited, it was filed, the id came
/// from a stale card — and everything typed is gone. Nothing is written,
/// because the store's first record of a reply is made four lines further
/// down. The caller then logged "nothing typed and nothing staged", which is
/// true of a different failure and actively misleading about this one.
///
/// So the words are written here first. This does not make the send happen:
/// the target really is gone and there is nothing to send it to. It makes the
/// words survivable, which is the part that was missing — recovery becomes a
/// `cat` rather than retyping from memory.
public enum UnsentText {

    /// Beside the queue database, not in the log: the log rotates and this is
    /// the user's own words.
    public static var url: URL {
        QueueStore.supportDirectory.appendingPathComponent("unsent-text.log")
    }

    /// Keep text that is about to be discarded, with why and who it was for.
    ///
    /// Appended, never rewritten, so a second loss cannot cost the first. A
    /// failed write is reported and swallowed: text already being lost is not
    /// improved by throwing.
    public static func keep(_ text: String, for sessionId: String, because reason: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }   // nothing typed is not a loss
        trace?("unsent: kept \(words.count) chars for \(sessionId.prefix(8)) — \(reason)")

        // Tab-separated with newlines escaped, so one multi-line message stays
        // one record and `all()` can read it back whole.
        let stamp = ISO8601DateFormatter().string(from: Date())
        let escaped = words.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: " ")
        let line = "\(stamp)\t\(sessionId)\t\(reason)\t\(escaped)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            trace?("unsent: could not keep it: \(error)")
        }
    }

    /// Everything kept, oldest first, with the newlines put back.
    public static func all() -> [(at: String, sessionId: String, reason: String, text: String)] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { return nil }
            let text = parts.dropFirst(3).joined(separator: "\t")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
            return (at: parts[0], sessionId: parts[1], reason: parts[2], text: text)
        }
    }

    /// Where the app's log line goes. Set by the app; nil in a test.
    public nonisolated(unsafe) static var trace: ((String) -> Void)?
}
