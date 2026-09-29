import Foundation

/// Project folders on the grid: which agents the user has grouped, under what
/// name, in what order, and whether each folder is collapsed.
///
/// Ruled 29 Sep 2026 (`docs/rulings/ruling-project-folders.md`): drag an agent
/// onto another and the two become a folder; folders sit above the loose rows;
/// a folder whose agents all finish hides and waits, and goes away only when
/// the user drags its last agent out or deletes it.
///
/// Membership is keyed by the conversation's ORIGIN id. `--resume` keeps a
/// session's id, and the left arrow's continuation resolves to its origin
/// through `SessionLineage`, so a revived agent finds its folder with nothing
/// else to do. A Codex fork changes the id outright, so `rekey` follows it the
/// way `LampSwitch.rekey` carries the lamp switch.
public struct ProjectBook: Codable, Equatable, Sendable {

    public struct Folder: Codable, Equatable, Sendable {
        public let id: String
        public var name: String
        public var collapsed: Bool
        public init(id: String, name: String, collapsed: Bool = false) {
            self.id = id
            self.name = name
            self.collapsed = collapsed
        }
    }

    /// In the user's order: the order a header drag sets. Folders with an
    /// agent asking for you rise above it (rule 3); this is the order beneath.
    public var folders: [Folder]
    /// Origin session id to folder id.
    public var members: [String: String]
    /// Every folder name the user has kept, oldest first, no repeats. The
    /// namer is shown these so a new folder reuses the user's own words
    /// ("Mirai") rather than inventing a topic ("Email Analysis").
    public var names: [String]

    public init(folders: [Folder] = [], members: [String: String] = [:], names: [String] = []) {
        self.folders = folders
        self.members = members
        self.names = names
    }

    public static let empty = ProjectBook()

    // MARK: - Reading

    public func folder(id: String) -> Folder? { folders.first { $0.id == id } }

    /// The folder a session belongs to. Looked up under the id itself first,
    /// then under its origin: a row may be drawn under a continuation's id
    /// while membership was recorded under the conversation's first one.
    public func folder(of sessionId: String, origin: (String) -> String = { $0 }) -> Folder? {
        let key = members[sessionId] ?? members[origin(sessionId)]
        return key.flatMap { folder(id: $0) }
    }

    public func memberCount(of folderId: String) -> Int {
        members.values.filter { $0 == folderId }.count
    }

    // MARK: - Writing

    /// Two agents dropped one on the other. Returns the new folder's id.
    /// A folder name is not known yet at the drop: the namer answers later
    /// and `rename` records it.
    @discardableResult
    public mutating func create(name: String, with sessionIds: [String],
                                origin: (String) -> String = { $0 },
                                id: String = ProjectBook.newId()) -> String {
        folders.append(Folder(id: id, name: name))
        for sessionId in sessionIds { assign(sessionId, to: id, origin: origin) }
        return id
    }

    public mutating func join(_ sessionId: String, folder folderId: String,
                              origin: (String) -> String = { $0 }) {
        guard folder(id: folderId) != nil else { return }
        let left = folder(of: sessionId, origin: origin)?.id
        assign(sessionId, to: folderId, origin: origin)
        if let left, left != folderId { dropIfEmpty(left) }
    }

    /// Dragged out onto the loose rows. Returns the folder that went away
    /// with it, if this was its last member: dragging the last agent out is
    /// one of the two ways a folder ends (rule 5).
    @discardableResult
    public mutating func leave(_ sessionId: String,
                               origin: (String) -> String = { $0 }) -> Folder? {
        guard let left = folder(of: sessionId, origin: origin) else { return nil }
        members.removeValue(forKey: sessionId)
        members.removeValue(forKey: origin(sessionId))
        return dropIfEmpty(left.id)
    }

    public mutating func rename(_ folderId: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == folderId })
        else { return }
        folders[index].name = trimmed
        remember(trimmed)
    }

    public mutating func setCollapsed(_ folderId: String, _ collapsed: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folderId }) else { return }
        folders[index].collapsed = collapsed
    }

    /// A header dropped on another header: before it, or after it.
    public mutating func move(_ folderId: String, to targetId: String, after: Bool) {
        guard folderId != targetId,
              let from = folders.firstIndex(where: { $0.id == folderId }) else { return }
        let moving = folders.remove(at: from)
        guard var to = folders.firstIndex(where: { $0.id == targetId }) else {
            folders.insert(moving, at: from)
            return
        }
        if after { to += 1 }
        folders.insert(moving, at: to)
    }

    /// Delete a folder. Its agents stay exactly where they are, loose.
    public mutating func delete(_ folderId: String) {
        folders.removeAll { $0.id == folderId }
        members = members.filter { $0.value != folderId }
    }

    /// A session changed identity (a Codex fork). A membership already
    /// recorded on the destination wins, as `LampSwitch.rekey` does.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func rekey(from oldSessionId: String, to newSessionId: String) -> Bool {
        guard oldSessionId != newSessionId,
              let folderId = members.removeValue(forKey: oldSessionId) else { return false }
        if members[newSessionId] == nil { members[newSessionId] = folderId }
        return true
    }

    public mutating func remember(_ name: String) {
        names.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        names.append(name)
    }

    public static func newId() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    private mutating func assign(_ sessionId: String, to folderId: String,
                                 origin: (String) -> String) {
        // One key per conversation: whatever it was filed under before goes.
        members.removeValue(forKey: sessionId)
        members[origin(sessionId)] = folderId
    }

    @discardableResult
    private mutating func dropIfEmpty(_ folderId: String) -> Folder? {
        guard memberCount(of: folderId) == 0, let gone = folder(id: folderId) else { return nil }
        folders.removeAll { $0.id == folderId }
        return gone
    }
}

/// The book on disk, and the one copy of it in memory.
///
/// `projects.json` beside `lamp-off.json`, rewritten whole on every change,
/// the same shape of persistence as `LampSwitch`: a handful of ids written on
/// a gesture and read on every repaint. The repaint reads the memory copy, so
/// drawing the grid never touches the disk.
public final class ProjectStore: @unchecked Sendable {

    public static var url: URL {
        QueueStore.supportDirectory.appendingPathComponent("projects.json")
    }

    public static let shared = ProjectStore(url: ProjectStore.url)

    public let url: URL
    private let lock = NSLock()
    private var book: ProjectBook

    public init(url: URL) {
        self.url = url
        self.book = Self.load(from: url)
    }

    public var current: ProjectBook {
        lock.lock(); defer { lock.unlock() }
        return book
    }

    /// Change the book and write it. Returns what the change returned.
    @discardableResult
    public func update<T>(_ change: (inout ProjectBook) -> T) -> T {
        lock.lock()
        let result = change(&book)
        let snapshot = book
        lock.unlock()
        Self.save(snapshot, to: url)
        return result
    }

    /// Put a whole book back: the drop's undo.
    public func restore(_ snapshot: ProjectBook) {
        update { $0 = snapshot }
    }

    public static func load(from url: URL) -> ProjectBook {
        guard let data = try? Data(contentsOf: url),
              let book = try? JSONDecoder().decode(ProjectBook.self, from: data)
        else { return .empty }
        return book
    }

    public static func save(_ book: ProjectBook, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(book) else { return }
        try? PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
        PrivateStorage.protect(url)
    }

    /// Follow a Codex fork. Called beside `LampSwitch.rekey`.
    public static func rekey(from oldSessionId: String, to newSessionId: String,
                             store: ProjectStore = .shared) {
        guard store.current.members[oldSessionId] != nil else { return }
        store.update { $0.rekey(from: oldSessionId, to: newSessionId) }
    }
}
