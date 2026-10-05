import Foundation
import CryptoKit

extension TurnText {
    /// Summary input needs the whole event's turn, unlike a bounded hub preview.
    /// Memory holds one log record plus prose, not the session's tool output.
    public static func completed(in url: URL, finalMessage: String,
                                 completedAt: Date) -> Turn? {
        let final = finalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty, let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var reversed: [String] = []
        var result: Turn?
        do {
            try reverseLines(file) { line in
                guard !line.isEmpty else { return true }
                guard let data = line.data(using: .utf8),
                      let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return reversed.isEmpty } // Never certify a damaged turn.
                let at = RolloutClock.date(row["timestamp"])
                if let at, at > completedAt { return true }
                var human = ""
                var assistant = ""
                if row["message"] != nil {
                    let message = row["message"] as? [String: Any] ?? [:]
                    if row["type"] as? String == "user", row["toolUseResult"] == nil,
                       isPersonSpeaking(row) {
                        if row["isCompactSummary"] as? Bool == true { return true }
                        human = humanText(message["content"])
                    } else if row["type"] as? String == "assistant" {
                        assistant = assistantText(message["content"])
                    }
                } else if case .content(let message) = CodexRollout.record(line) {
                    if message.role == "user" { human = humanPart(message.text) }
                    if message.role == "assistant" {
                        assistant = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if !human.isEmpty {
                    // Don't cross a real prompt while searching for this final.
                    guard !reversed.isEmpty else { return false }
                    let blocks = Array(reversed.reversed())
                    result = Turn(prompt: human, prose: blocks.joined(separator: "\n\n"), at: at, blocks: blocks)
                    return false
                }
                if !assistant.isEmpty, !reversed.isEmpty || assistant == final {
                    reversed.append(assistant)
                }
                return true
            }
        } catch { return nil }
        return result
    }

    static func transcript(for sessionId: String, suppliedPath: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        if let suppliedPath { return URL(fileURLWithPath: suppliedPath) }
        return claudeTranscript(for: sessionId, home: home)
            ?? CodexRollout.rolloutPath(forSessionId: sessionId,
                                       sessions: home.appendingPathComponent(".codex/sessions")).map { URL(fileURLWithPath: $0) }
    }

    /// Length framing makes the fingerprint sensitive to message boundaries.
    public static func fingerprint(_ blocks: [String]) -> String {
        var hash = SHA256()
        for block in blocks {
            let data = Data(block.utf8)
            hash.update(data: Data("\(data.count):".utf8))
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func reverseLines(_ file: FileHandle, visit: (String) -> Bool) throws {
        var offset = try file.seekToEnd()
        var fragments: [Data] = []
        func emit(_ first: Data) -> Bool {
            var line = first
            line.reserveCapacity(first.count + fragments.reduce(0) { $0 + $1.count })
            for fragment in fragments.reversed() { line.append(fragment) }
            fragments.removeAll(keepingCapacity: true)
            guard let text = String(data: line, encoding: .utf8) else { return false }
            return visit(text)
        }
        while offset > 0 {
            let count = Int(min(offset, 64 * 1024))
            offset -= UInt64(count)
            try file.seek(toOffset: offset)
            guard let bytes = try file.read(upToCount: count), bytes.count == count else {
                throw CocoaError(.fileReadUnknown)
            }
            let pieces = bytes.split(separator: 10, omittingEmptySubsequences: false)
            for piece in pieces.dropFirst().reversed() {
                if !emit(Data(piece)) { return }
            }
            fragments.append(Data(pieces[0]))
        }
        if !fragments.isEmpty { _ = emit(Data()) }
    }
}
