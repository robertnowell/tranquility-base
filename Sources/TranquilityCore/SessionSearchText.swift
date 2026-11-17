import Foundation

/// Readable search evidence, never tool output, reasoning, or harness prompts.
/// Reads complete lines so an old conversation is not lost behind a large tool
/// result at the end of its transcript. The index stores this projection.
public enum SessionSearchText {
    public struct Message: Codable, Sendable, Equatable {
        public let at: Date
        public let role: String
        public let text: String
    }

    static func userWords(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Named wrappers only: a person's HTML example is still their message.
        let wrappers = ["environment_context", "task-notification", "subagent_notification",
                        "system-reminder", "turn_aborted", "local-command-caveat",
                        "command-name", "command-message", "command-args", "local-command-stdout"]
        while let tag = wrappers.first(where: { text.hasPrefix("<\($0)>") }) {
            guard let end = text.range(of: "</\(tag)>") else { return "" }
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("# AGENTS.md instructions for") { return "" }
        if text.hasPrefix("[assistant]:"), let split = text.range(of: "[user]:") {
            text = String(text[split.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// The only records that can hold a message, as the harnesses write them.
    /// Both write compact JSON, so the key and its value are adjacent bytes.
    private static let speakers: [[UInt8]] = [
        Array(#""type":"user""#.utf8), Array(#""type":"assistant""#.utf8),
        Array(#""type":"response_item""#.utf8)]
    private static let toolResult: [UInt8] = Array(#""toolUseResult":"#.utf8)

    private static func holds(_ line: UnsafeRawPointer, _ length: Int, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { memmem(line, length, $0.baseAddress, $0.count) != nil }
    }

    /// Whether a line is worth parsing at all. A session log is mostly tool
    /// output: measured on 15 Nov 2026, parsing every line of every log on
    /// one machine took 183 seconds, and nearly all of it was JSON that
    /// `message(in:)` then threw away. A quote inside message text is escaped
    /// in the file, so these unescaped byte runs are real keys, never words
    /// somebody said.
    static func mayHoldMessage(_ line: UnsafeRawPointer, _ length: Int) -> Bool {
        guard !holds(line, length, toolResult) else { return false }
        return speakers.contains { holds(line, length, $0) }
    }

    static func mayHoldMessage(_ line: Data) -> Bool {
        line.withUnsafeBytes { raw in
            raw.baseAddress.map { mayHoldMessage($0, raw.count) } ?? false
        }
    }

    public static func message(in data: Data) -> Message? {
        guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let at = RolloutClock.date(row["timestamp"]),
              row["isMeta"] as? Bool != true,
              row["isCompactSummary"] as? Bool != true,
              row["toolUseResult"] == nil else { return nil }
        let role: String
        let message: [String: Any]
        if row["type"] as? String == "response_item" {
            guard let payload = row["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let r = payload["role"] as? String else { return nil }
            role = r; message = payload
        } else {
            role = row["type"] as? String ?? ""
            message = row["message"] as? [String: Any] ?? [:]
        }
        guard role == "user" || role == "assistant" else { return nil }
        let content = message["content"]
        let words: String
        if let string = content as? String {
            words = string
        } else if let blocks = content as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            words = blocks.compactMap { block -> String? in
                guard let type = block["type"] as? String,
                      ["text", "input_text", "output_text"].contains(type) else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        } else { return nil }
        let text = (role == "user" ? userWords(words) : words)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Message(at: at, role: role, text: text)
    }

    /// Read the complete lines that follow `offset`, and say where they end.
    ///
    /// A session log only grows, so the index keeps a byte position for each
    /// log and reads the new bytes alone. A final line with no newline is a
    /// record the harness is still writing: it stays unread, and the returned
    /// position stops before it, so the next read takes it whole.
    ///
    /// The file is mapped, not copied, and lines are found and filtered on
    /// the mapped bytes. The first version read 256 KB at a time into a
    /// buffer and copied every line out of it: 75 of the 93 seconds a first
    /// build took on a real archive (15 Nov 2026) were spent there, on tool
    /// output that was never going to be indexed.
    public static func read(_ url: URL, from offset: UInt64 = 0) throws
        -> (messages: [Message], offset: UInt64) {
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        var messages: [Message] = []
        var seen: Set<MessageKey> = []
        var consumed = min(offset, UInt64(data.count))
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = Int(consumed)
            var lines = 0
            while start < count {
                guard let newline = memchr(base + start, 10, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(newline))
                let length = end - start
                if length > 0, mayHoldMessage(base + start, length) {
                    // JSON bridging creates temporary Foundation objects.
                    // Release them after every record.
                    let parsed: Message? = autoreleasepool {
                        message(in: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                         count: length, deallocator: .none))
                    }
                    if let parsed, seen.insert(MessageKey(parsed)).inserted { messages.append(parsed) }
                }
                start = end + 1
                lines += 1
                if lines % 256 == 0 { try Task.checkCancellation() }
            }
            consumed = UInt64(start)
        }
        return (messages, consumed)
    }

    private struct MessageKey: Hashable {
        let at: Date
        let role: String
        let text: String
        init(_ value: Message) { at = value.at; role = value.role; text = value.text }
    }
}
