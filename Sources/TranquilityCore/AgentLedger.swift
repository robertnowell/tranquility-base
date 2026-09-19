import Foundation

// MARK: - Where an agent is

/// The one answer to "where is this agent, and may I act on it?"
///
/// Ruled 15 Sep 2026, after the seventh incident of one class since 19 Aug:
/// an agent's address was re-derived at every use from whatever happened to
/// be on the machine (a tty, recycled; a pid, recycled; a pane id, unique
/// only per server), and a destructive verb waited on a miss. That morning
/// a TEST build could not see two agents on its own isolated tmux server,
/// called them hand-started, SIGTERMed both and resumed them into a server
/// the real app could not see; the real app then matched their pane ids
/// against its own panes and typed two replies into two strangers, verified
/// green because a stranger's input box emptied.
///
/// The rule that replaces the inference: the address of an agent is a fact
/// this app WROTE when it made or adopted the agent, and every use verifies
/// that fact against the one server it names, by pid. Nothing here falls
/// back to another server, another tty, or another pane. What it cannot
/// verify it says it cannot verify, in words a caller can act on.
public enum AgentLocation: Sendable, Equatable {
    /// Verified: this pane, on a server this instance owns, hosts this pid,
    /// and the pid is alive on that pane's tty. Safe to type into.
    case here(TmuxPaneAddress, pid: Int)
    /// Alive, and hosted by something this instance cannot reach: the
    /// harness's own registry names a tmux session that is on none of our
    /// servers. Another instance owns it (a TEST build, a second install, a
    /// server started by hand). Never touched, never "hand-started".
    case elsewhere(String)
    /// Alive, and in no tmux anybody knows of: a bare Terminal process. The
    /// only location an ownership transfer may act on.
    case unhosted(pid: Int)
    /// No live process answers to this session.
    case gone
    /// A server could not be asked, or the facts contradict each other. Not
    /// an answer, and by rule never grounds for anything destructive.
    case unknown(String)

    /// The pane, when the answer is a pane.
    public var pane: TmuxPaneAddress? {
        if case .here(let pane, _) = self { return pane }
        return nil
    }

    public var pid: Int? {
        switch self {
        case .here(_, let pid), .unhosted(let pid): return pid
        default: return nil
        }
    }

    /// One line for a log or a refusal.
    public var summary: String {
        switch self {
        case .here(let pane, let pid): return "here: \(pane.sessionName) \(pane.paneId) pid \(pid)"
        case .elsewhere(let why): return "elsewhere: \(why)"
        case .unhosted(let pid): return "unhosted: pid \(pid) in no tmux"
        case .gone: return "gone"
        case .unknown(let why): return "unknown: \(why)"
        }
    }
}

// MARK: - The ledger

public enum AgentLedger {

    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// One row of a live server's `list-panes -a`, on one socket.
    public struct PaneRow: Sendable, Equatable {
        public var socketName: String?
        public var sessionName: String
        public var paneId: String
        public var paneTty: String
        public var dead: Bool

        public init(socketName: String?, sessionName: String, paneId: String,
                    paneTty: String, dead: Bool = false) {
            self.socketName = socketName
            self.sessionName = sessionName
            self.paneId = paneId
            self.paneTty = paneTty
            self.dead = dead
        }

        public var address: TmuxPaneAddress {
            TmuxPaneAddress(socketName: socketName, paneId: paneId,
                            sessionName: sessionName, paneTty: paneTty)
        }
    }

    /// What one server said, or that it could not be asked.
    public enum Inventory: Sendable, Equatable {
        case listed([PaneRow])
        case unaskable(String)
    }

    /// Everything a decision needs, gathered first so the decision itself is
    /// pure and testable against two invented servers with colliding ids.
    public struct Facts: Sendable {
        public var record: SessionOwnershipRecord?
        public var registry: SessionRegistry.Entry?
        public var pidHint: Int?
        /// Per socket, in `TmuxOwnership.sockets` order.
        public var inventories: [(socket: String?, inventory: Inventory)]
        public var isAlive: @Sendable (Int) -> Bool
        public var ttyOf: @Sendable (Int) -> String?

        public init(record: SessionOwnershipRecord?, registry: SessionRegistry.Entry?,
                    pidHint: Int?, inventories: [(socket: String?, inventory: Inventory)],
                    isAlive: @escaping @Sendable (Int) -> Bool,
                    ttyOf: @escaping @Sendable (Int) -> String?) {
            self.record = record
            self.registry = registry
            self.pidHint = pidHint
            self.inventories = inventories
            self.isAlive = isAlive
            self.ttyOf = ttyOf
        }
    }

    /// The decision, plus the record it now believes. `locate` writes that
    /// record when it differs from what the store held, so an agent found
    /// through the harness's registry or a pid is adopted once and addressed
    /// by record ever after.
    public struct Decision: Sendable, Equatable {
        public var location: AgentLocation
        public var adopt: SessionOwnershipRecord?
    }

    // MARK: Live

    /// Where the session is, verified now. Adopts what it verifies.
    public static func locate(sessionId: String, pid pidHint: Int? = nil,
                              harness: String? = nil,
                              store: any SessionOwnershipStore = FileSessionOwnershipStore.shared)
    -> AgentLocation {
        let facts = Facts(
            record: store.current(sessionId: sessionId),
            registry: SessionRegistry.entry(forSessionId: sessionId),
            pidHint: pidHint,
            inventories: TmuxOwnership.sockets.map { socket in
                (socket, Self.inventory(socket: socket))
            },
            isAlive: { ProcessProbe.isAlive($0) },
            ttyOf: { ProcessProbe.tty(of: $0) })
        let decision = decide(sessionId: sessionId, harness: harness, facts: facts)
        if let adopt = decision.adopt {
            store.record(adopt)
            trace?("ledger: \(sessionId.prefix(8)) recorded \(adopt.sessionName ?? "?") "
                + "\(adopt.paneId ?? "?") pid \(adopt.pid)")
        }
        trace?("ledger: \(sessionId.prefix(8)) \(decision.location.summary)")
        return decision.location
    }

    /// One server's panes, with the fields a verification needs.
    public static func inventory(socket: String?) -> Inventory {
        let listing = Tmux.run(
            ["list-panes", "-a", "-F", "#{session_name}\t#{pane_id}\t#{pane_tty}\t#{pane_dead}"],
            socket: socket, timeout: 3)
        switch listing {
        case .success(let out):
            guard TmuxOwnership.inventoryIsIntelligible(out) else {
                return .unaskable("listing could not be parsed")
            }
            return .listed(parse(inventory: out, socket: socket))
        case .failure(let error):
            if TmuxOwnership.serverIsAbsent(error.message)
                || TmuxOwnership.serverHoldsNoPanes(error.message) {
                return .listed([])
            }
            return .unaskable(error.message)
        }
    }

    static func parse(inventory: String, socket: String?) -> [PaneRow] {
        inventory.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3,
                                   omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, !parts[0].isEmpty, parts[1].hasPrefix("%") else { return nil }
            return PaneRow(socketName: socket, sessionName: parts[0], paneId: parts[1],
                           paneTty: parts[2], dead: parts.count > 3 && parts[3] == "1")
        }
    }

    // MARK: Pure

    /// The whole rule, with no process table and no server behind it.
    ///
    /// Claims are tried in order of who is speaking: this app's own record
    /// first, then the harness's own registry, then a bare pid. Every claim
    /// is verified the same way before it is believed: the named session
    /// AND pane exist on the named server, and a live pid sits on that
    /// pane's tty. A claim that names a server we cannot see is
    /// `.elsewhere`; a server that could not answer is `.unknown`; and only a
    /// live pid that no claim places in any tmux is `.unhosted`.
    public static func decide(sessionId: String, harness: String?, facts: Facts) -> Decision {
        let harnessId = harness ?? facts.record?.harness ?? ClaudeCodeAdapter().id
        var candidatePids: [Int] = []
        for pid in [facts.record?.pid, facts.registry?.pid, facts.pidHint] {
            if let pid, !candidatePids.contains(pid) { candidatePids.append(pid) }
        }
        let livePids = candidatePids.filter(facts.isAlive)

        func rows(on socket: String?) -> Inventory? {
            facts.inventories.first { $0.socket == socket }?.inventory
        }
        func anyUnaskable() -> String? {
            for entry in facts.inventories {
                if case .unaskable(let why) = entry.inventory {
                    return "\(entry.socket ?? "default") server: \(why)"
                }
            }
            return nil
        }
        /// The live pid on this pane's tty, if any of ours is.
        func occupant(of row: PaneRow) -> Int? {
            livePids.first { facts.ttyOf($0) == row.paneTty }
        }
        func adoption(_ row: PaneRow, pid: Int) -> SessionOwnershipRecord? {
            let current = facts.record
            if let current, current.pid == pid, current.paneId == row.paneId,
               current.sessionName == row.sessionName, current.socketName == row.socketName {
                return nil
            }
            return SessionOwnershipRecord(
                sessionId: sessionId, harness: harnessId, pid: pid,
                paneId: row.paneId, socketName: row.socketName,
                sessionName: row.sessionName, paneTty: row.paneTty,
                cwd: current?.cwd ?? facts.registry?.cwd)
        }

        // 1. Our own record: the pane we made, on the server we made it on.
        if let record = facts.record, let sessionName = record.sessionName, let paneId = record.paneId {
            switch rows(on: record.socketName) {
            case .unaskable(let why):
                return Decision(location: .unknown("\(record.socketName ?? "default") server "
                    + "holds \(sessionName) and could not be asked: \(why)"), adopt: nil)
            case .listed(let rows):
                if let row = rows.first(where: { $0.sessionName == sessionName && $0.paneId == paneId }),
                   !row.dead, let pid = occupant(of: row) {
                    return Decision(location: .here(row.address, pid: pid),
                                    adopt: adoption(row, pid: pid))
                }
                // Our pane is gone from its server, or nobody we know is on
                // it any more. The record is history, not an address; fall
                // through to what the harness itself says.
            case nil:
                break
            }
        }

        // 2. The harness's own word (Claude Code writes its pane down).
        if let registry = facts.registry, let name = registry.tmuxSessionName, let paneId = registry.paneId {
            var found: PaneRow?
            for entry in facts.inventories {
                if case .listed(let rows) = entry.inventory,
                   let row = rows.first(where: { $0.sessionName == name && $0.paneId == paneId }) {
                    found = row
                    break
                }
            }
            if let row = found {
                if row.dead { return Decision(location: .gone, adopt: nil) }
                if let pid = occupant(of: row) {
                    return Decision(location: .here(row.address, pid: pid),
                                    adopt: adoption(row, pid: pid))
                }
                // Session and pane are ours by name, but no pid we know sits
                // on that tty. Something is mid-change; say so, do nothing.
                return Decision(location: .unknown("registry names \(name) \(paneId) on "
                    + "\(row.paneTty) but no live pid for this session is on that tty"), adopt: nil)
            }
            if let why = anyUnaskable() {
                return Decision(location: .unknown("registry names \(name) \(paneId); \(why)"),
                                adopt: nil)
            }
            if livePids.isEmpty { return Decision(location: .gone, adopt: nil) }
            return Decision(location: .elsewhere("in tmux session \(name) (pane \(paneId)), "
                + "which is on no server this app can see"), adopt: nil)
        }

        // 3. No claim of a pane from anyone. A live pid is either on one of
        //    our panes (a harness with no registry: adopt it) or bare.
        guard let pid = livePids.first else { return Decision(location: .gone, adopt: nil) }
        guard let tty = facts.ttyOf(pid) else {
            return Decision(location: .unknown("pid \(pid) is alive but has no tty"), adopt: nil)
        }
        for entry in facts.inventories {
            if case .listed(let rows) = entry.inventory,
               let row = rows.first(where: { $0.paneTty == tty && !$0.dead }) {
                return Decision(location: .here(row.address, pid: pid), adopt: adoption(row, pid: pid))
            }
        }
        if let why = anyUnaskable() {
            return Decision(location: .unknown("pid \(pid) on \(tty); \(why)"), adopt: nil)
        }
        return Decision(location: .unhosted(pid: pid), adopt: nil)
    }
}
