import Foundation

/// Readable search evidence, never tool output, reasoning, or harness prompts.
/// Reads complete lines so an old conversation is not lost behind a large tool
/// result at the end of its transcript. The index caches this projection.
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

    public static func read(_ url: URL, since: Date) throws -> [Message] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var pending = Data()
        var messages: [Message] = []
        var seen: Set<MessageKey> = []
        func consume(_ line: Data) {
            // JSON bridging creates temporary Foundation objects, including
            // large discarded tool results. Release them after every record.
            let parsed = autoreleasepool { message(in: line) }
            guard let value = parsed, value.at >= since,
                  seen.insert(MessageKey(value)).inserted else { return }
            messages.append(value)
        }
        var searched = 0
        while let bytes = try file.read(upToCount: 256 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            pending.append(bytes)
            var start = pending.startIndex
            var searchFrom = pending.index(start, offsetBy: searched)
            while let end = pending[searchFrom...].firstIndex(of: 10) {
                consume(Data(pending[start..<end]))
                start = pending.index(after: end)
                searchFrom = start
            }
            if start != pending.startIndex { pending = Data(pending[start...]) }
            searched = pending.count
        }
        if !pending.isEmpty { consume(pending) }
        return messages
    }

    private struct MessageKey: Hashable {
        let at: Date
        let role: String
        let text: String
        init(_ value: Message) { at = value.at; role = value.role; text = value.text }
    }
}
