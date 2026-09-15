import Foundation

/// The session grid's data model — one row, its lamp, and the rules for
/// what a tap on it does. Extracted from `StateLegend` (App-lane P6, 24
/// Aug, "SessionRow model + grid statics to Core, with unit tests"): this
/// was 59+ call sites of pure String/enum/Bool logic sitting in the app
/// layer with zero unit coverage, because `Sources/TranquilityApp` has
/// none and cannot easily have any (CLAUDE.md rule 7 — it needs a window
/// server). None of it needs one. `StateLegend` keeps everything that
/// actually renders (`Lamp.fill`/`.ring`/`.rowAlpha`, both `NSColor`; see
/// its own extension there) — this file keeps everything that DECIDES.

/// Green: waiting on you. Advisory blue: the agent has work in hand right
/// now (ruled 06 Aug — "we have no indicator if the agent is actually
/// working or idle"). Blue because MIL-STD-411's advisory channel is
/// exactly this: news, nothing for you to do. Solid, never blinking — a
/// room full of blinking lamps is the opposite of calm.
public enum Lamp: Equatable, Sendable {
    case ready
    case working
    /// Quiet: alive, turn complete, nothing in flight.
    case running
    /// Amber: stopped on something it cannot pass on its own — a usage
    /// limit, a dead API. Amber is the needs-you channel.
    case fault
    /// No lamp at all: the session exited, or the liveness probe could not
    /// say. Ruled 11 Aug — an agent does not stop existing when its process
    /// ends, so it keeps its row; but nothing is running behind that lens,
    /// so nothing lights it.
    ///
    /// Deliberately NOT a fifth colour. v1.1 ruled against a "we don't
    /// know" hue and that stands: this is the ABSENCE of one, an empty
    /// socket against `running`'s unlit-but-seated lamp.
    case unlit

    /// Whether this lamp's row is ASKING the user for something — and so
    /// whether the read state is worth showing on it at all.
    ///
    /// `working` is MIL-STD-411's ADVISORY channel, "news, nothing for you
    /// to do" — a hollow blue ring would be the panel contradicting its own
    /// legend. Same for `running` (alive, nothing in flight) and `unlit`
    /// (gone). Green and amber are the two channels that ask: `ready` is
    /// "waiting on you", `fault` is the needs-you channel. Ruled 16 Aug —
    /// "idk that blue should be empty circle?"
    public var asksForYou: Bool { self == .ready || self == .fault }

    /// Is this lamp ON? Green, blue and amber are; the seated socket and
    /// the empty one are not.
    ///
    /// The grid's whole membership rule, in one property (18 Aug): "the
    /// grid is for lit lamps." `running` reads as off because it IS off —
    /// alive with nothing in flight is exactly what the user means when he
    /// turns a lamp off by hand, and the panel cannot treat the two
    /// differently without the switch looking broken.
    public var isLit: Bool {
        switch self {
        case .ready, .working, .fault: return true
        case .running, .unlit: return false
        }
    }
}

/// Has this row's turn been heard — and does it even HAVE a turn?
///
/// This was a `Bool` named `unread`, defaulting to true, and the default
/// was a lie with a visible consequence (16 Aug). A row with no waiting
/// turn at all — an idle session, a past agent just sitting there — is
/// not "unread"; it is asking nothing. Defaulting it to unread rendered
/// it at full attention intensity, so an idle session in Past Agents
/// outshone an ACTIVE session you had already heard.
public enum ReadState: Sendable {
    /// A turn is waiting and you have not heard it. The only tier that
    /// gets full ink, because it is the only one asking for you.
    case unread
    /// Heard, still owed an answer (read is not answered, 12 Aug).
    case opened
    /// No waiting turn. Renders at the SAME intensity as `opened` — both
    /// mean "nothing new here" — and is separated from it by the lamp
    /// alone, which is the channel that already says what a session is
    /// doing.
    case none

    /// Intensity is a two-tier question even though the state is three:
    /// are you being asked for, or not.
    public var isAsking: Bool { self == .unread }
}

/// One row of the idle grid: a session, its lamp, and its callsign.
/// Equatable so the intake timer can refresh the grid only when content
/// actually changed, not on every poll.
public struct SessionRow: Equatable, Sendable {
    public let id: String
    /// The displayed identity: the tab's string (see displayName).
    public let name: String
    /// The right column. RE-RULED 12 Aug: the session's own short id, in
    /// the shape of a commit hash — because the question this column has
    /// to answer changed. It held the minted callsign so eye and ear
    /// shared one identity (05 Aug: hear "home sessions", find "home
    /// sessions"), which is right when every row is a session you are
    /// talking to. It is not right once the panel and its list are full of
    /// sessions you are trying to FIND: "there is a workstream I did a
    /// week ago and I don't know which tab it is in" is answered by an
    /// identifier, not a name.
    ///
    /// The callsign is not lost — it is still the spoken identity, still
    /// minted, and still the fallback for `name` when a session has no tab
    /// title yet. It simply stops being the thing this column shows.
    ///
    /// A stopped session shows its REASON here instead. Amber is the
    /// needs-you channel and the reason is the entire message; an id would
    /// be the one row where this column says nothing useful.
    public let aux: String
    public let lamp: Lamp
    /// Whether tapping this row brings the session back — `claude --resume`
    /// in whatever directory `SessionDiscovery.landingDirectory` resolves:
    /// its own when that survives, else the repository root above it, else
    /// `~/Projects`. NOT "its own directory" any more (24 Aug): a closed
    /// worktree used to retire its agent, and 95% of worktree sessions were
    /// unrevivable for that reason alone.
    ///
    /// NOT simply "the lamp is unlit". It requires POSITIVE evidence the
    /// process is gone, plus somewhere to land. A probe that
    /// failed proves nothing, and resuming a session that is still running
    /// leaves the original process alive and adds a second live entry
    /// under the same id, which crashed the app twice (06 Aug 14:35, 07
    /// Aug 17:39). So an unproven row shows unlit and offers nothing, and
    /// the two failure directions are opposite ON PURPOSE: the display
    /// fails toward showing you the work, the verb fails toward doing
    /// nothing.
    public let revivable: Bool
    /// Where this row sits in the read ladder.
    public let read: ReadState
    /// The user switched this session's lamp OFF (18 Aug). Its process is
    /// untouched and its row is untouched; the flag decides only which of
    /// the two faces draws it, and the lamp it draws with.
    ///
    /// Carried on the ROW rather than read from `LampSwitch` at every call
    /// site, because the rule that produces it is not "is the id in the
    /// file" — a waiting turn overrides the switch — and two readers
    /// evaluating that separately is how they start disagreeing.
    public let switchedOff: Bool
    /// The whole message, for the hover. The row shows `aux`, which is a
    /// clause of it cut to a column and then truncated again by the label;
    /// until 18 Aug that meant an error or a stall could only be READ in
    /// the log. Nil where there is nothing more to say than the row says.
    public let detail: String?

    /// Which harness runs this session, when it is known.
    ///
    /// Carried on the row rather than looked up by the view, for the reason
    /// every other field here is: a view that resolves its own facts is a
    /// second reader, and two readers of one question start disagreeing. The
    /// grid learned that expensively between 30 Aug and 01 Sep, when the same
    /// session's harness was decided in four places and three of them were
    /// wrong at least once.
    ///
    /// Optional because it genuinely can be unknown: a row rebuilt from disk
    /// for a session with no ownership record has no way to say.
    public let harness: String?
    /// **Where Go to Agent goes.**
    ///
    /// A FACT ABOUT THE ROW, set by whoever built it, rather than a question
    /// anybody asks about what kind of agent this is. That is the whole point:
    /// "does this have a terminal" is a capability, and writing
    /// `if harness == "opencode"` here would be the 48th identity comparison
    /// (#382) on the day the seam exists to stop them.
    ///
    /// Defaults to `.terminal`, so every row the four local bands build is
    /// unchanged.
    public let door: Door

    /// **When this agent last did something.** The sort key for lit rows.
    ///
    /// Added 14 Sep 2026 (#454), and it is the field whose absence caused two
    /// sessions to rule opposite ways on ordering within hours: #428 ranked by
    /// read-state, #439 reverted that under the title "Green orders by
    /// recency" and then tied every lit row, because ordering by recency was
    /// not something the row could do. A tie falls back to arrival order,
    /// arrival order is BAND order, and band 5 is last — which is why a remote
    /// agent could never win a slot however recently it had spoken.
    ///
    /// `nil` means the band had nothing to offer, and those rows keep their
    /// arrival order at the end rather than being flung to 1970.
    public let lastActivity: Date?

    public enum Door: Equatable, Sendable {
        /// A tmux pane this Mac owns. Every local agent.
        case terminal
        /// A page in the provider's own interface. crobot has one per task.
        case page(URL)
        /// Neither, and that is honest rather than a gap: a local
        /// `opencode serve` has no web page and no terminal of ours. Go to
        /// Agent has nowhere to go, so it is not offered.
        case none

        /// Opens somewhere that is not a pane this Mac owns.
        public var isPage: Bool {
            if case .page = self { return true }
            return false
        }

        /// The page, when there is one. The card asks for this to decide
        /// whether it can offer Go to Agent at all.
        public var url: URL? {
            if case .page(let url) = self { return url }
            return nil
        }
    }

    public init(id: String, name: String, aux: String, lamp: Lamp,
               revivable: Bool = false, read: ReadState = .none,
               switchedOff: Bool = false, detail: String? = nil,
               harness: String? = nil, door: Door = .terminal,
               lastActivity: Date? = nil) {
        self.id = id
        self.name = name
        self.aux = aux
        self.lamp = lamp
        self.revivable = revivable
        self.read = read
        self.lastActivity = lastActivity
        self.switchedOff = switchedOff
        self.detail = detail
        self.harness = harness
        self.door = door
    }

    /// The same row with its lamp out, as a session the user has filed.
    ///
    /// The lamp is overridden rather than merely flagged because that is
    /// what "off" LOOKS like — Robert, 18 Aug: "an idle session, that is,
    /// the process is alive. But the lamp is off." Turning it back on
    /// hands the row its real state again, because this copy is derived
    /// on every repaint and never stored.
    public func switchedOffCopy() -> SessionRow {
        SessionRow(id: id, name: name, aux: aux, lamp: .running,
                   revivable: revivable, read: read, switchedOff: true,
                   detail: detail, harness: harness, door: door)
    }

    /// What the pointer gets when it rests on a row: the full name, and
    /// under it the full message, neither of them cut.
    ///
    /// Ruled 18 Aug. Both halves of a row truncate — the name against the
    /// callsign column, the reason against the row's edge — so a stalled
    /// or blocked session showed "silent for 2h, no…" and the rest of the
    /// sentence existed nowhere a human could reach. One function for both
    /// faces, because a row that says one thing on the grid and another in
    /// the list is worse than one that says nothing.
    public static func hoverText(for row: SessionRow) -> String? {
        let message = row.detail ?? (row.aux == shortId(row.id) ? nil : row.aux)
        guard let message, !message.isEmpty else { return row.name }
        return "\(row.name)\n\(message)"
    }

    /// What a tap on a row does. One tap, two verbs, and a third case that
    /// is the whole safety story.
    ///
    /// Stated as a function rather than as a branch inside the click
    /// handler so it can be asserted by a drill without a window server,
    /// which is the only evidence the panel layer has.
    public enum RowAction: Equatable, Sendable {
        /// Live: hear what it has to say.
        case announce
        /// Amber: stopped on something it cannot pass alone, so the only
        /// useful thing this app can do is put you in front of it (ruled
        /// 18 Aug).
        ///
        /// Announcing an amber row was the wrong verb twice over. A
        /// blocked session is not in the waiting set — it has no unread
        /// turn — so the announcement had nothing to say and the panel sat
        /// on Preparing; and even when it did speak, hearing "it cannot
        /// reach the API" is not the move. The reason is already on the
        /// row, in the column where every other row shows its id. What is
        /// missing is the tab, and that is the one thing a tap can hand
        /// you.
        ///
        /// Blue joined amber here on 24 Aug, and for the same reason
        /// rather than a second one. A working row has no unread turn
        /// either — it has work IN HAND — so announcing it says nothing,
        /// or reads back the turn BEFORE this one, which is worse than
        /// silence because it sounds current. Robert: *"why not just send
        /// the user to the agent the same way we do with an amber lamp?
        /// If you want to see the progress, just go to the source."*
        /// Summarising progress was the alternative, and it is strictly
        /// more machinery for strictly less truth: the pane is already
        /// writing the thing a summary would paraphrase, so the summary
        /// can only be later and thinner than what it stands in for.
        ///
        /// The dark lamp followed the same day, closing the rule rather
        /// than extending it. `.running` was left on announce for one
        /// turn of this conversation on the theory that a finished,
        /// already-heard turn could still be asked for again — and the
        /// code says otherwise: there is no re-read path. `announceNext`
        /// falls through to `.nothingWaiting`, logs a line, and drops you
        /// back on the grid. So the tap on the one lamp nobody had looked
        /// at was a control that did nothing at all, which is the 18 Aug
        /// amber complaint exactly, surviving on the quietest row because
        /// a silent no-op is the hardest kind of dead control to notice.
        ///
        /// What is left is one sentence, and it is the whole rule:
        /// **announce is for a row with an unread turn — and green is the
        /// only lamp that has one.** Green gets the card. Every other live
        /// lamp gets the door. Amber cannot speak because it is stopped,
        /// blue because it is mid-turn, dark because its turn was already
        /// read; three different reasons, one verb, and no lamp left whose
        /// tap has to be learned as an exception.
        case goToAgent
        /// Go to Agent for a row whose agent lives on a web page rather than
        /// in a pane. Same verb to the user, different door.
        case openPage(URL)
        /// Proven gone, and its directory is still there: bring it back.
        case revive
        /// Unlit but unproven — the probe could not answer, or the
        /// directory is gone. Doing nothing is the correct outcome, NOT
        /// falling through to announce: a `--resume` against a session
        /// that is actually alive puts two processes under one id, and
        /// that crashed the app twice.
        case none
    }

    public static func action(for row: SessionRow) -> RowAction {
        switch row.lamp {
        case .fault, .working, .running: return goTo(row)
        // **Green consults the door too, since 14 Sep.** Announce reads a
        // finished turn out of the LOCAL store, so it is the right verb only
        // for a row that has one. A remote agent has no local transcript and
        // no local id, so `announceNext(only:)` guarded on a lookup that could
        // never succeed and returned in silence: the click did nothing at all,
        // which is worse than a control that refuses.
        //
        // Latent until this morning, and then mine. Remote rows used to be
        // unlit or quiet, so the door was only ever reachable through the
        // three lamps above; making them green under the three-lamp ruling
        // stranded it. A row that carries a page has somewhere to go, and that
        // is true whatever colour it is.
        // A green row ANNOUNCES only when there is something to announce.
        // Announce reads a turn out of the local store, and a row with
        // `read: .none` has no turn there — it is green because its agent
        // finished (the three-lamp ruling, and right), not because it said
        // anything. Robert, 15 Sep, on 29 such rows in Past Agents: "clicking
        // on them does nothing. It's very weird that they're there." Every
        // one was a probe session that had never spoken. So: the door if it
        // has one, otherwise nothing, and never an announce that finds nothing.
        case .ready:
            if row.door.isPage { return goTo(row) }
            return row.read == .none ? .none : .announce
        case .unlit: return row.revivable ? .revive : .none
        }
    }

    /// Go to Agent, through whichever door this row has.
    ///
    /// The verb is the same to the user, which is the ruling: they picked an
    /// agent, not a mechanism. Only the destination differs, and it differs
    /// because the row says so rather than because anything here guessed.
    private static func goTo(_ row: SessionRow) -> RowAction {
        switch row.door {
        case .terminal: return .goToAgent
        case .page(let url): return .openPage(url)
        // Offering a door that opens on nothing is worse than offering none:
        // it reads as broken rather than as absent.
        case .none: return .none
        }
    }

    /// What a click on the LAMP does. The answer depends on WHICH FACE you
    /// clicked it on, and that is the design rather than an inconsistency.
    ///
    /// Ruled 18 Aug, correcting a first attempt that read the lamp as
    /// power over the PROCESS and so made "off" mean kill. It does not.
    /// Robert: *"clicking an ON lamp turns it off. Turns it to idle. It
    /// does not kill the process… if I'm on the grid and I click the lamp,
    /// the lamp turns off and it goes to past agents. If I'm on past
    /// agents and I click the lamp and it's idle, it goes back into the
    /// grid, takes the lamp colour whatever the state is."*
    ///
    /// So the lamp is the GRID'S MEMBERSHIP CONTROL, and it reads as one
    /// sentence: on the grid it files a session away, in the list it
    /// brings one back. The single exception is a session whose process
    /// has exited — you cannot flip a terminated process on, so a dead
    /// lamp means resurrect on either face: *"you can't just flip the lamp
    /// on, you got to resurrect it. So a one-click revives the session."*
    public enum LampFace: Equatable, Sendable {
        /// The panel's grid — the sessions that are ON.
        case grid
        /// Past Agents — the ones that are off, and the ones that are gone.
        case list
    }

    public enum LampAction: Equatable, Sendable {
        /// Alive, on the grid: turn it off. Idle, filed, drawn by the list.
        /// The process is untouched.
        case turnOff
        /// Alive, in the list: turn it on. Back to the grid, wearing
        /// whatever state it is actually in.
        case turnOn
        /// The process has exited. `claude --resume`, one click, either
        /// face.
        case revive
    }

    public static func lampAction(for row: SessionRow, on face: LampFace) -> LampAction {
        switch row.lamp {
        // Deliberately not gated on `revivable`. `revive()` re-probes at
        // ttl 0 and refuses safely with a reason, so the guard lives where
        // it works; a switch that silently does nothing was the bug this
        // replaced.
        case .unlit: return .revive
        case .ready, .working, .running, .fault:
            return face == .grid ? .turnOff : .turnOn
        }
    }

    /// Is there a process behind this row — the question END SESSION and
    /// GO TO AGENT both have to answer.
    ///
    /// Asked through `action(for:)` rather than off the lamp, so the menu
    /// and the left-click can never drift into disagreeing about which
    /// rows are alive. That drift is not hypothetical: offering to kill a
    /// process we cannot see is a control that can only lie, and the menu
    /// used to test `== .announce` — which stopped meaning "live" the
    /// moment amber got its own verb.
    public static func isLive(_ row: SessionRow) -> Bool {
        switch action(for: row) {
        // `openPage` is live for the same reason `goToAgent` is: it is the
        // same verb through a different door, and an agent you can open is an
        // agent that exists. Listing it here rather than defaulting, because a
        // default is what let the menu and the left-click drift apart before.
        case .announce, .goToAgent, .openPage: return true
        case .revive, .none: return false
        }
    }

    /// Four bands: sessions doing something, then sessions merely alive,
    /// then sessions the user switched off by hand, then sessions that
    /// have exited — which sink below all of them, because a row you
    /// cannot speak to must never sit between two you can.
    ///
    /// Order WITHIN each band is untouched: the caller has already
    /// established recency, and a stable partition keeps it.
    public static func quietRowsLast(_ rows: [SessionRow]) -> [SessionRow] {
        func band(_ row: SessionRow) -> Int {
            // A row the user switched off is ALIVE — `switchedOffCopy()`
            // hands it `lamp: .running`, and `AppDelegate+Grid` refuses to
            // file a `.unlit` row at all, so this band and the dead one are
            // disjoint by construction. It therefore sits ABOVE the dead,
            // under the same sentence the doc comment opens with: you can
            // still speak to it, and `.unlit` you cannot.
            //
            // REVERSED 29 Aug, on Robert's screenshot of a session he had
            // just switched off sitting at the very bottom of Past Agents,
            // under eight dead ones: "idle sessions should show at the top,
            // turned-off sessions should be below the idle sessions."
            //
            // The rule it replaces was not cosmetic when it was written —
            // it said so: "the grid is a prefix of this array, so 'last' is
            // what makes `gridRowsShown` able to exclude filed rows by a
            // count instead of a predicate." That constraint is gone.
            // `gridRows` and `shownCount` both filter on `!switchedOff`
            // now, and `StatusHUD.pastAgents` is a set difference rather
            // than a `dropFirst` — the same migration from length to
            // predicate its own comment records. Nothing downstream reads a
            // prefix of this array any more, so the only thing the old rank
            // still did was rank a live session below a dead one on the one
            // face built to show it.
            if row.switchedOff { return 2 }
            switch row.lamp {
            // LIT, and ranked TOGETHER. Split in two for one afternoon (14
            // Sep, #428: unread green above read green, so a remote agent
            // enumerated last could win a slot) and reversed the same day on
            // Robert's report: "right now Read is all at the top, but then if
            // you read something it moves in the order and it's hard to find
            // again ... just order green by recency, whether or not they're
            // read or unread." Hearing a row must not move it. Read-state
            // bolds a row and drives the announcer; it does not order the
            // grid. The bands above have already put every lit row in recency
            // order, and a stable partition keeps it.
            //
            // The remote-agent placement that motivated the split is a real
            // gap and is still open: the fifth band arrives last by
            // construction, so it needs a recency field of its own to join
            // this order, not a read-state tiebreak that reshuffles the local
            // rows every time one is heard.
            case .ready, .working, .fault: return 0
            case .running: return 1
            case .unlit: return 3
            }
        }
        // **The lit band orders by recency** (#454), which is the field the
        // comment above says it was waiting for.
        //
        // The local bands already arrive in recency order, so for them this is
        // a no-op that happens to be explicit. What it adds is the fifth band:
        // a remote agent is enumerated last by construction, and without a
        // timestamp of its own it could never join the order however recently
        // it had spoken. Measured before this landed: 0 of 12 panel rows were
        // remote, and the crobot row was not in the grid at all.
        //
        // Read-state is deliberately not consulted. Hearing a row must not
        // move it — that is the rule this replaces a read-state tiebreak with,
        // not a rule it overturns.
        //
        // A row whose band could not say when keeps its arrival position at
        // the end of the lit band rather than sorting to 1970: "I don't know"
        // is not "never".
        // One pass. `sorted(by:)` is not stable in Swift, so the arrival index
        // is the tiebreak — otherwise rows with equal timestamps, or none at
        // all, would shuffle between repaints.
        func byRecency(_ lit: [SessionRow]) -> [SessionRow] {
            lit.enumerated().sorted { a, b in
                switch (a.element.lastActivity, b.element.lastActivity) {
                case let (x?, y?): return x == y ? a.offset < b.offset : x > y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.offset < b.offset
                }
            }.map(\.element)
        }
        return (0...3).flatMap { rank -> [SessionRow] in
            let inBand = rows.filter { band($0) == rank }
            return rank == 0 ? byRecency(inBand) : inBand
        }
    }

    /// A session id in the shape of a commit hash: the leading eight,
    /// which is what every log line, every trace and `tbase discover`
    /// already print, so a row on screen and a line in the log name the
    /// same thing the same way. The leading group rather than the
    /// trailing one for exactly that reason — GitHub shows a commit's
    /// first seven, and this codebase has been printing
    /// `sessionId.prefix(8)` since before the panel had a grid.
    public static func shortId(_ sessionId: String) -> String { String(sessionId.prefix(8)) }

    public static func displayName(liveName: String? = nil, callsign: String?,
                                   fallback: String) -> String {
        if let liveName, !liveName.isEmpty { return liveName }
        if let callsign, !callsign.isEmpty { return callsign }
        return fallback
    }

    // MARK: - The grid's own membership (StatusHUD's gridRows/gridRowsShown,
    // pure half — App-lane P6)

    /// Which rows the grid draws, in order — every LIT session, then
    /// alive-but-quiet, then dead, prefixed to however many slots the
    /// panel is worth. `capacity` and `floor` are plain counts computed
    /// app-side from the screen (`StatusHUD.gridRowCapacity(screen:)`),
    /// deliberately not asked for here: this function has no opinion about
    /// AppKit, only about which rows win once told how many slots there are.
    ///
    /// Split from `shownCount` because that number is GEOMETRY — how tall
    /// the panel is worth being, which is why it may exceed the rows that
    /// exist and why the floor holds on a quiet machine. Folding
    /// membership into it collapsed the floor and shipped a regression
    /// earlier the same evening (18 Aug).
    public static func gridRows(_ rows: [SessionRow], capacity: Int, floor: Int) -> [SessionRow] {
        let eligible = rows.filter { !$0.switchedOff }
        let lit = eligible.filter { $0.lamp.isLit }
        let alive = eligible.filter { $0.lamp == .running }
        let dead = eligible.filter { $0.lamp == .unlit }
        return Array((lit + alive + dead).prefix(shownCount(rows, capacity: capacity, floor: floor)))
    }

    /// How many row-slots the panel is worth: every LIT session, or the
    /// floor, whichever is larger — clamped to capacity.
    ///
    /// RE-RULED 18 Aug, reversing the entitlement half of `27a49fd` on
    /// Robert's instruction and his screenshot: *"Why is there an idle
    /// fucking lamp? A turned-off lamp? In the goddamn grid. The grid. Is
    /// for lit. Fucking lamps. Idle lamps going past agents."* Row
    /// `0f2ea0d4` was drawn on the grid with an unlit socket; the process
    /// agreed it was idle.
    ///
    /// That earlier rule made ALIVENESS the entitlement, to stop live
    /// sessions being sent to page two while slots stood empty. Its case
    /// survives intact and is why the reversal is narrow: the sessions it
    /// was protecting were working or blocked, and both are LIT, so they
    /// still hold their rows. The only rows this takes back are the ones
    /// that are alive with nothing in flight — which is precisely the
    /// state the user's own switch produces, and it would be incoherent
    /// for the panel to file a session away when he turns its lamp off
    /// and keep it when it goes out by itself.
    ///
    /// So the grid is the instrument for NOW, in one sentence: it draws
    /// lit lamps. Everything else — idle, switched off, exited — is the
    /// list.
    public static func shownCount(_ rows: [SessionRow], capacity: Int, floor: Int) -> Int {
        let lit = rows.filter { $0.lamp.isLit && !$0.switchedOff }.count
        return min(capacity, max(floor, lit))
    }
}


// MARK: - Names the event stream uses

public extension Lamp {
    /// The lamp as a vocabulary word for `agent_lamp_changed`.
    var trackName: String {
        switch self {
        case .ready: return "ready"
        case .working: return "working"
        case .running: return "running"
        case .fault: return "fault"
        case .unlit: return "unlit"
        }
    }
}

public extension ReadState {
    var trackName: String {
        switch self {
        case .unread: return "unread"
        case .opened: return "opened"
        case .none: return "none"
        }
    }
}
