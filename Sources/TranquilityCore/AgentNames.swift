import Foundation

/// The names this app gives agents, as opposed to the names their harnesses
/// give them.
///
/// Until 11 Nov 2026 an agent had exactly one name and the app owned none of
/// it: the grid showed the harness's own title (Claude Code's transcript
/// title, Codex's thread name) and nothing could change it. Two things
/// followed. A row could not be renamed at all, and an agent started with
/// "Continue work with" was titled by its harness from a first message that
/// opens with the SOURCE's name in quotes, so it came back wearing the
/// source's name (measured over 45 days: 7 of 17 continued agents took a
/// title identical or nearly identical to their source, and no title changed
/// after it was first minted).
///
/// So a name can now be given here, and a given name outranks the harness's
/// in `GridAssembler`, the one place every surface resolves a name. Nothing
/// is written to the harness: no `/rename` typed into a live agent, no record
/// appended to a transcript this app does not own. That is what makes a
/// rename safe across ending, reviving and relaunching: the name is a fact in
/// this app's own file, keyed like folder membership.
///
/// Keyed by the conversation's ORIGIN id, the way `ProjectBook.members` is,
/// so a revived agent and a left-arrow continuation keep the name, and
/// `rekey` follows a Codex fork.
public struct AgentNameBook: Codable, Equatable, Sendable {

    public enum Source: String, Codable, Sendable {
        /// Typed by the user. Nothing automatic ever replaces it.
        case user
        /// Chosen by the app for a continued agent. The user's rename wins.
        case auto
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var source: Source
        public init(name: String, source: Source) {
            self.name = name
            self.source = source
        }
    }

    /// Origin session id to the name given.
    public var names: [String: Entry]

    public init(names: [String: Entry] = [:]) { self.names = names }

    public static let empty = AgentNameBook()

    /// Under the id itself first, then under its origin, for the same reason
    /// `ProjectBook.folder(of:)` looks twice.
    public func entry(for sessionId: String, origin: (String) -> String = { $0 }) -> Entry? {
        names[sessionId] ?? names[origin(sessionId)]
    }

    public func name(for sessionId: String, origin: (String) -> String = { $0 }) -> String? {
        entry(for: sessionId, origin: origin)?.name
    }

    /// Give a name. Returns whether it was taken: an automatic name never
    /// replaces one the user typed, and an empty name is not a name.
    @discardableResult
    public mutating func give(_ name: String, to sessionId: String, source: Source,
                              origin: (String) -> String = { $0 }) -> Bool {
        let trimmed = Self.tidy(name)
        guard !trimmed.isEmpty else { return false }
        if source == .auto, entry(for: sessionId, origin: origin)?.source == .user { return false }
        names.removeValue(forKey: sessionId)
        names[origin(sessionId)] = Entry(name: trimmed, source: source)
        return true
    }

    /// Back to the harness's own name.
    public mutating func clear(_ sessionId: String, origin: (String) -> String = { $0 }) {
        names.removeValue(forKey: sessionId)
        names.removeValue(forKey: origin(sessionId))
    }

    public mutating func rekey(from oldSessionId: String, to newSessionId: String) {
        guard let entry = names.removeValue(forKey: oldSessionId) else { return }
        names[newSessionId] = entry
    }

    /// One line, no control characters, and short enough for a row: a name
    /// pasted with a newline in it would otherwise break every surface that
    /// prints it, the menu item that quotes it included.
    public static func tidy(_ raw: String) -> String {
        let oneLine = raw.unicodeScalars
            .map { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                ? " " : String($0) }
            .joined()
        let collapsed = oneLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }

    public static let maxLength = 80
}

/// The book on disk and the one copy of it in memory, the same shape as
/// `ProjectStore`: written whole on a gesture, read from memory on every
/// repaint.
public final class AgentNameStore: @unchecked Sendable {

    public static var url: URL {
        QueueStore.supportDirectory.appendingPathComponent("agent-names.json")
    }

    public static let shared = AgentNameStore(url: AgentNameStore.url)

    public let url: URL
    private let lock = NSLock()
    private var book: AgentNameBook

    public init(url: URL) {
        self.url = url
        self.book = Self.load(from: url)
    }

    public var current: AgentNameBook {
        lock.lock(); defer { lock.unlock() }
        return book
    }

    @discardableResult
    public func update<T>(_ change: (inout AgentNameBook) -> T) -> T {
        lock.lock()
        let result = change(&book)
        let snapshot = book
        lock.unlock()
        Self.save(snapshot, to: url)
        return result
    }

    /// The name given to a session, by the last known lineage. Never scans:
    /// this is asked on every repaint.
    public func name(for sessionId: String) -> String? {
        current.name(for: sessionId, origin: SessionLineage.lastKnownOrigin)
    }

    public static func load(from url: URL) -> AgentNameBook {
        guard let data = try? Data(contentsOf: url),
              let book = try? JSONDecoder().decode(AgentNameBook.self, from: data)
        else { return .empty }
        return book
    }

    public static func save(_ book: AgentNameBook, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(book) else { return }
        try? PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
        PrivateStorage.protect(url)
    }

    /// Follow a Codex fork. Called beside `ProjectStore.rekey`.
    public static func rekey(from oldSessionId: String, to newSessionId: String,
                             store: AgentNameStore = .shared) {
        guard store.current.names[oldSessionId] != nil else { return }
        store.update { $0.rekey(from: oldSessionId, to: newSessionId) }
    }
}

/// A continued agent's own name: what THIS agent was asked to do, told apart
/// from the agent it continues and from every other row.
///
/// The harness cannot do this. It titles a session from the first message,
/// and a continued agent's first message opens "Please continue the work of
/// “<source's name>”", so the source's name is the strongest signal in it.
/// The fix is the context, not a filter on the result: this prompt is given
/// the instruction the user spoke AFTER the handoff, separately from the
/// source's name, and the names already in use.
///
/// Pure. The app makes the call and stores the answer.
public enum AgentNamer {

    public static let system = """
        You name one coding-agent session in a list of sessions. \
        Reply with the name only: three to six words, no quotes, no final punctuation. \
        The session continues an earlier session, and the user then gave it a new instruction. \
        Name what the new instruction asks for, in the user's own terms. \
        The name must tell this session apart from every name already in use, \
        so do not repeat one of those names and do not start with "Continue".
        """

    public static func prompt(sourceName: String, instruction: String, taken: [String]) -> String {
        var lines = ["The earlier session is named: \(sourceName)"]
        let others = taken.filter { $0.caseInsensitiveCompare(sourceName) != .orderedSame }
        if !others.isEmpty {
            lines.append("Other names in use: \(others.prefix(40).joined(separator: "; "))")
        }
        lines.append("The new instruction:\n\(String(instruction.prefix(instructionLimit)))")
        return lines.joined(separator: "\n")
    }

    /// Enough of a dictated instruction to name it by. A long dictation says
    /// what it wants in its first sentences.
    static let instructionLimit = 1500

    /// The model's reply made fit for a row, or nil when it is not a usable
    /// name: empty, an essay, or a name another row already wears.
    public static func clean(_ reply: String, taken: [String]) -> String? {
        let lines = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // One line or nothing. A reply that runs to several is the model
        // explaining itself, and its first line is the explanation.
        guard lines.count == 1, let line = lines.first else { return nil }
        let name = line
            .replacingOccurrences(of: "Name:", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*.:;,!“”‘’ ").union(.whitespaces))
        let words = name.split(whereSeparator: \.isWhitespace)
        guard !name.isEmpty, words.count <= 8, name.count <= 60,
              !collides(name, with: taken) else { return nil }
        return name
    }

    /// When there is no model or no usable answer: the source's name with the
    /// lowest number that no row wears. Dull, and never mistaken for its
    /// source, which is the one thing a continued agent's name must manage.
    public static func fallback(sourceName: String, taken: [String]) -> String {
        let base = stem(sourceName)
        var number = 2
        while collides("\(base) \(number)", with: taken + [sourceName]) { number += 1 }
        return "\(base) \(number)"
    }

    /// "Mirai flows 2" continues as "Mirai flows 3", not "Mirai flows 2 2".
    static func stem(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        if words.count > 1, let last = words.last, Int(last) != nil {
            return words.dropLast().joined(separator: " ")
        }
        return name
    }

    /// Two names a person could not tell apart in a list: the same letters
    /// and digits once case, spacing and punctuation are set aside.
    public static func collides(_ name: String, with taken: [String]) -> Bool {
        let key = fold(name)
        return taken.contains { fold($0) == key }
    }

    static func fold(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
