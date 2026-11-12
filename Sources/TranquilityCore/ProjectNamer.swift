import Foundation

/// A new folder's first name: two or three words for the most specific thing
/// the agents in it share.
///
/// RE-RULED 11 Nov 2026, on a measurement. The 29 Sep version named "the
/// PROJECT the two agents share, never the topic", in one or two words, and
/// was told to reuse one of the user's folder names when it fit. Robert:
/// *"half the time it just gets named Tranquility Base, which is dumb. It
/// should choose just the best two or three word name for the unique
/// combination of things that those two agents share."* All 14 naming calls
/// in `model-calls.jsonl` were read back and three causes found:
///
///   1. The prompt showed two titles and two directory names and nothing
///      else, so the directory was the only thing the two had in common.
///   2. "Reuse an existing name when one fits" pulled answers toward names
///      that did not fit: an accountable-plan session was filed as
///      "Apartment", a mute button and a writing standard as "Hub".
///   3. The names shown as "the user's folder names so far" were not the
///      user's. `ProjectBook.rename` remembers every name a folder is given,
///      the model's included, and `clean` cut each reply to its first two
///      words. So "These sessions don't fit your existing folders…" became a
///      folder called "These sessions", "Session A: Puerto Rico" became
///      "Session A:", and both were then shown to every later call as the
///      user's own vocabulary.
///
/// So the prompt is now shown what each agent is for, is told which names
/// are already TAKEN rather than which to reuse, and a reply that is not one
/// short line is refused whole instead of being cut down to its first words.
/// The finding that people name groups specifically (Mozilla on tab groups,
/// research record 2026-09-29-agent-project-folders) still stands, and is why
/// the name is the narrowest shared thing and never a catch-all.
/// Everything here is pure; the app makes the call.
public enum ProjectNamer {

    public struct Agent: Sendable, Equatable {
        public let title: String
        /// The working directory's last component, when known.
        public let folder: String?
        /// What the agent is working toward, in a sentence, when the
        /// summaries have recorded one.
        public let goal: String?
        public init(title: String, folder: String?, goal: String? = nil) {
            self.title = title
            self.folder = folder
            self.goal = goal
        }
    }

    public static let system = """
        You name a folder that groups a few of a user's coding-agent sessions. \
        Reply with the name only: two or three words, no quotes, no punctuation, one line. \
        Name the most specific thing these particular sessions have in common: \
        the feature, client, campaign or problem they all work on. \
        The name of a product, company or codebase alone is right only when \
        the sessions share nothing narrower than that. \
        Do not answer with a directory name such as "Projects". \
        Never the kind of work ("Email Analysis", "Bug Fixes"), never a \
        catch-all ("Misc", "General", "Project"), and never a name that is \
        already taken.
        """

    /// `taken` is every folder that exists now. A new folder that deserved
    /// one of those names would have been dropped into that folder.
    public static func prompt(_ agents: [Agent], taken: [String]) -> String {
        var lines: [String] = []
        if !taken.isEmpty {
            lines.append("Folder names already taken: \(taken.joined(separator: ", ")).")
        }
        for (index, agent) in agents.enumerated() {
            let letter = String(UnicodeScalar(UInt8(65 + min(index, 25))))
            let place = agent.folder.map { "  (directory: \($0))" } ?? ""
            lines.append("Session \(letter): \(agent.title)\(place)")
            if let goal = agent.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
                lines.append("  It is working on: \(String(goal.prefix(300)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static let generic: Set<String> = [
        "misc", "miscellaneous", "general", "project", "projects", "folder", "other",
        "various", "stuff", "work", "tasks", "sessions", "agents", "untitled", "new folder",
    ]

    /// The model's reply, made fit for a header, or nil when it is not a name.
    ///
    /// Refused whole when it is more than one line or more than four words.
    /// Cutting a long reply down to its first two words is what turned an
    /// explanation into a folder called "These sessions".
    public static func clean(_ reply: String, taken: [String] = []) -> String? {
        let lines = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 1, let line = lines.first else { return nil }
        let name = line
            .replacingOccurrences(of: "Name:", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*.:;,!“”‘’ ").union(.whitespaces))
        let words = name.split(whereSeparator: \.isWhitespace)
        guard !name.isEmpty, words.count <= 4, name.count <= 32,
              !name.contains(":"),
              !generic.contains(name.lowercased()),
              !AgentNamer.collides(name, with: taken) else { return nil }
        return name
    }

    /// When there is no model, or it did not answer usefully: the directory
    /// both agents work in, else a word both titles share, else the first
    /// title's first real word.
    public static func fallback(_ agents: [Agent], taken: [String]) -> String {
        let name = fallback(agents)
        guard AgentNamer.collides(name, with: taken) else { return name }
        var number = 2
        while AgentNamer.collides("\(name) \(number)", with: taken) { number += 1 }
        return "\(name) \(number)"
    }

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
