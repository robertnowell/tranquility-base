import Foundation

/// Reads finished sessions out of `~/.claude/projects` so the summarizer can be
/// exercised against real material rather than invented fixtures. Read-only.
public enum TranscriptArchive {
    public struct Sample: Sendable {
        public let sessionId: String
        public let projectLabel: String
        public let lastAssistantMessage: String
        public let modifiedAt: Date
    }

    public static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Most recently modified sessions first, skipping any whose final message is
    /// too short to be worth summarizing.
    public static func recentSamples(limit: Int = 20, minimumLength: Int = 120) -> [Sample] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil) else { return [] }

        var transcripts: [(URL, Date)] = []
        for project in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                transcripts.append((file, modified))
            }
        }

        var samples: [Sample] = []
        for (url, modified) in transcripts.sorted(by: { $0.1 > $1.1 }) {
            guard samples.count < limit else { break }
            guard let message = lastAssistantMessage(in: url), message.count >= minimumLength
            else { continue }
            samples.append(Sample(
                sessionId: url.deletingPathExtension().lastPathComponent,
                projectLabel: projectLabel(from: url.deletingLastPathComponent().lastPathComponent),
                lastAssistantMessage: message,
                modifiedAt: modified))
        }
        return samples
    }

    /// Project directories are the cwd with `/` replaced by `-`, so the tail is the
    /// closest thing to a human name.
    static func projectLabel(from encodedDirectory: String) -> String {
        encodedDirectory.split(separator: "-").last.map(String.init) ?? encodedDirectory
    }

    public static func lastAssistantMessage(in url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var latest: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any]
            else { continue }

            var text = ""
            if let s = message["content"] as? String {
                text = s
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks
                    .filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: " ")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { latest = trimmed }
        }
        return latest
    }
}
