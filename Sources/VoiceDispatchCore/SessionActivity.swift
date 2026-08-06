import Foundation

/// What a session is doing right now, read from its transcript.
///
/// Two questions the grid could not answer before this (Robert, 06 Aug): "is
/// this agent working, or just sitting there?" and "did this one die on an
/// error while I wasn't looking?" Both are answerable from the same place —
/// the tail of the session's JSONL — because Claude Code writes every turn,
/// tool call, and API failure into it as it happens.
///
/// Deliberately NOT hook-driven. Measured on this machine's archive: a turn
/// that dies on a usage limit fires no Stop hook in 9 of 10 cases, so an
/// event-driven design would be blind to exactly the case that matters most.
/// Polling the tail is the only honest path.
public enum SessionActivity: Equatable, Sendable {
    /// The agent has work in hand: a prompt it has not answered, a tool call
    /// in flight, or a turn still being written.
    case working
    /// The agent stopped on an error it cannot get past on its own.
    case blocked(reason: String)
    /// Alive, turn complete, nothing in flight.
    case idle

    /// How much of the file's end to read. Transcripts run to hundreds of
    /// megabytes; the last few entries are all that can possibly matter, and
    /// 64KB comfortably holds them even when one entry is a large tool result.
    static let tailBytes = 64 * 1024

    /// A `working` verdict older than this is not believable — the process is
    /// gone, or a tool call hung days ago. Prevents a lamp stuck on blue for
    /// a session nobody will ever come back to.
    static let freshness: TimeInterval = 15 * 60

    /// Classify a session from its transcript. Returns nil when the file
    /// cannot be read at all — the caller keeps whatever it had rather than
    /// inventing a state from an absent file.
    public static func read(transcriptPath: String, now: Date = Date()) -> SessionActivity? {
        guard let tail = tail(of: transcriptPath) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date
        return classify(tail: tail, modified: modified, now: now)
    }

    /// The decision itself, taking lines rather than a path so every rule
    /// below is testable without a filesystem.
    static func classify(tail: [String], modified: Date?, now: Date = Date()) -> SessionActivity {
        // Walk backwards to the first entry that says anything about the
        // conversation. system/attachment/summary lines are bookkeeping —
        // Claude Code writes several of them AFTER an error, which is why
        // "the last line" is the wrong question to ask.
        for line in tail.reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = entry["type"] as? String

            if entry["isApiErrorMessage"] as? Bool == true {
                return .blocked(reason: text(of: entry))
            }
            switch type {
            case "assistant":
                // A turn that ends in a tool call is still running; one that
                // ends in prose has said its piece.
                return hasToolUse(entry) ? working(since: modified, now: now) : .idle
            case "user":
                // Either a real prompt (the agent owes an answer) or a tool
                // result (the agent is mid-loop). Both mean working.
                return working(since: modified, now: now)
            default:
                continue  // system, attachment, summary, ai-title…
            }
        }
        return .idle
    }

    /// `working` only while the file is still warm — see `freshness`.
    private static func working(since modified: Date?, now: Date) -> SessionActivity {
        guard let modified, now.timeIntervalSince(modified) <= freshness else { return .idle }
        return .working
    }

    private static func hasToolUse(_ entry: [String: Any]) -> Bool {
        guard let message = entry["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { ($0["type"] as? String) == "tool_use" }
    }

    private static func text(of entry: [String: Any]) -> String {
        guard let message = entry["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let first = content.first, let text = first["text"] as? String
        else { return "stopped on an error" }
        return text
    }

    /// The last `tailBytes` of the file, split into whole lines. The first
    /// line of the window is dropped: seeking to a byte offset lands
    /// mid-record, and half a JSON object is not a record.
    static func tail(of path: String) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let window = String(data: data, encoding: .utf8) else { return nil }
        var lines = window.split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

extension SessionActivity {
    /// The short reason a blocked row shows, in the row's own width: the
    /// first clause of the error, without the instructions that follow it.
    public var shortReason: String? {
        guard case .blocked(let reason) = self else { return nil }
        let firstSentence = reason.split(separator: ".").first.map(String.init) ?? reason
        return firstSentence
            .replacingOccurrences(of: "You've ", with: "")
            .replacingOccurrences(of: "API Error: ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
