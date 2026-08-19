import Foundation

/// Reads finished sessions out of `~/.claude/projects` so the summarizer can be
/// exercised against real material rather than invented fixtures. Read-only.
public enum TranscriptArchive {
    public struct Sample: Sendable {
        public let sessionId: String
        public let projectLabel: String
        /// The session's opening ask. Without this a summary is a fragment — you
        /// cannot tell what "the fix has never run in the deployed pipeline" is
        /// *about* when ten sessions are in flight.
        public let firstUserMessage: String?
        public let lastAssistantMessage: String
        public let gitBranch: String?
        public let modifiedAt: Date
    }

    public static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// The transcript file for one session id — FOUND, not derived.
    ///
    /// Claude Code files a session under a directory named for its cwd with the
    /// separators mangled, and reproducing that mangling here would be a second
    /// copy of somebody else's private encoding: it works until the day they
    /// change it, and then it fails silently. A session id is a uuid, so the
    /// file it names is unique across every project directory; checking for it
    /// is one `fileExists` per directory and no assumptions at all.
    ///
    /// Nil when the session has not written a transcript yet, which is a real
    /// state — a session registers with `claude agents --json` a beat before its
    /// first line lands on disk.
    public static func transcriptPath(forSessionId id: String,
                                      projects: URL = projectsDirectory) -> String? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects,
                                                     includingPropertiesForKeys: nil)
        else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(id).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    /// Most recently modified sessions first, skipping any whose final message is
    /// too short to be worth summarizing.
    ///
    /// KNOWN CONTAMINATION, tolerated here on purpose: transcript mtime is not
    /// "when the conversation last moved" — Claude Code touches dead transcripts
    /// with untimestamped bookkeeping on open/resume/bridge-sync, which is the
    /// 19 Aug closed-band ordering bug. This walk feeds only `tbase sample`,
    /// where a browsed-but-old transcript is still real material, so the cheap
    /// clock stands. Anything USER-FACING that ranks transcripts must use
    /// `SessionDiscovery.lastMoved(tail:)` instead — do not copy this sort.
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
            let context = sessionContext(in: url)
            samples.append(Sample(
                sessionId: url.deletingPathExtension().lastPathComponent,
                projectLabel: projectLabel(from: url.deletingLastPathComponent().lastPathComponent),
                firstUserMessage: context.firstUserMessage,
                lastAssistantMessage: message,
                gitBranch: context.gitBranch,
                modifiedAt: modified))
        }
        return samples
    }

    /// The session's opening ask and its branch. Both come from the transcript
    /// envelope, so no extra process or lookup is needed.
    /// The branch a transcript was on, but ONLY when it was on exactly one.
    ///
    /// For the v16 backfill. A brief written before v14 has no branch of its
    /// own, and the transcript is where `gitBranch` came from in the first
    /// place — so it is recoverable rather than guessable. The catch is that a
    /// long session moves between branches (worktrees, especially), and the
    /// file does not say which turn sat on which. Attributing all of them to
    /// the first branch found would hand some turns another branch's pull
    /// request, which is the exact class of error this whole rewrite exists to
    /// stop. So: unanimous or nothing.
    public static func soleBranch(in url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var seen: Set<String> = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let b = obj["gitBranch"] as? String, !b.isEmpty else { continue }
            seen.insert(b)
            if seen.count > 1 { return nil }
        }
        return seen.first
    }

    public static func sessionContext(in url: URL) -> (firstUserMessage: String?, gitBranch: String?) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        var firstUser: String?
        var branch: String?

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }

            if firstUser == nil, (obj["type"] as? String) == "user",
               let message = obj["message"] as? [String: Any] {
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
                // Skip hook-injected context and command wrappers — they aren't the ask.
                if !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:") {
                    firstUser = String(trimmed.prefix(1200))
                }
            }
            if firstUser != nil, branch != nil { break }
        }
        return (firstUser, branch)
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
