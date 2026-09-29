import Foundation

/// A new folder's first name: one or two words naming the PROJECT the two
/// agents share, never the topic.
///
/// Evidence behind the shape (research record 2026-09-29-agent-project-folders):
/// people's own group names are specific ("over half the time ... specific
/// terms such as name of a video game, friend or town", Mozilla on tab
/// groups), while a topic namer says "Email Analysis" or "Miscellaneous".
/// So the prompt is shown the user's own past folder names and told to reuse
/// one when it fits, and the reply is cleaned and refused when it is generic.
/// Everything here is pure; the app makes the call.
public enum ProjectNamer {

    public struct Agent: Sendable, Equatable {
        public let title: String
        /// The working directory's last component, when known.
        public let folder: String?
        public init(title: String, folder: String?) {
            self.title = title
            self.folder = folder
        }
    }

    public static let system = """
        You name a project folder that groups a user's coding-agent sessions. \
        Reply with the name only: one or two words, no quotes, no punctuation. \
        Name the product, client, company or codebase the sessions share, \
        never the kind of work ("Email Analysis", "Bug Fixes") and never a \
        catch-all ("Misc", "General", "Project"). When one of the user's \
        existing folder names fits, reply with exactly that name.
        """

    public static func prompt(_ agents: [Agent], vocabulary: [String]) -> String {
        var lines: [String] = []
        if !vocabulary.isEmpty {
            lines.append("The user's folder names so far: \(vocabulary.joined(separator: ", ")).")
        }
        for (index, agent) in agents.enumerated() {
            let letter = String(UnicodeScalar(UInt8(65 + min(index, 25))))
            let place = agent.folder.map { "  (directory: \($0))" } ?? ""
            lines.append("Session \(letter): \(agent.title)\(place)")
        }
        return lines.joined(separator: "\n")
    }

    static let generic: Set<String> = [
        "misc", "miscellaneous", "general", "project", "projects", "folder", "other",
        "various", "stuff", "work", "tasks", "sessions", "agents", "untitled", "new folder",
    ]

    /// The model's reply, made fit for a header, or nil when it is not a name.
    public static func clean(_ reply: String) -> String? {
        let firstLine = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let stripped = firstLine
            .replacingOccurrences(of: "Name:", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*.:;,!“”‘’ ").union(.whitespaces))
        let words = stripped.split(whereSeparator: \.isWhitespace).prefix(2)
        let name = words.joined(separator: " ")
        guard !name.isEmpty, name.count <= 24,
              !generic.contains(name.lowercased()) else { return nil }
        return name
    }

    /// When there is no model, or it did not answer usefully: the directory
    /// both agents work in, else a word both titles share, else the first
    /// title's first real word.
    public static func fallback(_ agents: [Agent]) -> String {
        let folders = agents.compactMap(\.folder).filter { !$0.isEmpty }
        if folders.count == agents.count, let first = folders.first,
           folders.allSatisfy({ $0.caseInsensitiveCompare(first) == .orderedSame }) {
            return tidy(first)
        }
        // Titles that open with the same words name their project there:
        // "U Vape checkout flow" and "U Vape newsletter drafts" are U Vape.
        // Raw words, so a one-letter word like the U survives.
        let raw = agents.map { $0.title.split(whereSeparator: \.isWhitespace).map(String.init) }
        if agents.count > 1, let first = raw.first {
            var shared: [String] = []
            for (index, word) in first.prefix(2).enumerated()
            where raw.allSatisfy({ $0.count > index && $0[index].caseInsensitiveCompare(word) == .orderedSame }) {
                shared.append(word)
            }
            if shared.count == min(2, first.count) || (shared.count == 1 && shared[0].count > 1),
               let lead = shared.first, !stopwords.contains(lead.lowercased()) {
                return tidy(shared.joined(separator: " "))
            }
        }
        let wordSets = agents.map { Set(words($0.title).map { $0.lowercased() }) }
        if let first = agents.first {
            for word in words(first.title)
            where wordSets.allSatisfy({ $0.contains(word.lowercased()) }) {
                return tidy(word)
            }
            if let word = words(first.title).first { return tidy(word) }
        }
        return "Folder"
    }

    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "for", "to", "in", "on", "with", "by",
        "fix", "add", "build", "make", "check", "review", "update", "new", "draft",
        "email", "emails", "agent", "session", "audit", "analysis", "investigation",
    ]

    static func words(_ title: String) -> [String] {
        title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0.lowercased()) }
    }

    /// `mirai-klaviyo` reads as "Mirai Klaviyo"; a word already carrying
    /// capitals ("BlankShirts", "iOS") keeps them.
    static func tidy(_ raw: String) -> String {
        let parts = raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).prefix(2)
        return parts.map { part in
            part.contains(where: \.isUppercase) ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }
}
