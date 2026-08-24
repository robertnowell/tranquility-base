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
    /// in its own directory.
    ///
    /// NOT simply "the lamp is unlit". It requires POSITIVE evidence the
    /// process is gone, plus a directory that still exists. A probe that
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

    public init(id: String, name: String, aux: String, lamp: Lamp,
               revivable: Bool = false, read: ReadState = .none,
               switchedOff: Bool = false, detail: String? = nil) {
        self.id = id
        self.name = name
        self.aux = aux
        self.lamp = lamp
        self.revivable = revivable
        self.read = read
        self.switchedOff = switchedOff
        self.detail = detail
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
                   detail: detail)
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
        case goToAgent
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
        case .fault: return .goToAgent
        case .ready, .working, .running: return .announce
        case .unlit: return row.revivable ? .revive : .none
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
        case .announce, .goToAgent: return true
        case .revive, .none: return false
        }
    }

    /// Three bands now, not two. Sessions doing something, then sessions
    /// merely alive, then sessions that have exited — which sink below
    /// both, because a row you cannot speak to must never sit between two
    /// you can.
    ///
    /// Order WITHIN each band is untouched: the caller has already
    /// established recency, and a stable partition keeps it.
    public static func quietRowsLast(_ rows: [SessionRow]) -> [SessionRow] {
        func band(_ row: SessionRow) -> Int {
            // A session the user switched off sinks below even the dead
            // ones, and the ORDER is load-bearing rather than cosmetic:
            // the grid is a prefix of this array, so "last" is what makes
            // `gridRowsShown` able to exclude filed rows by a count
            // instead of a predicate, and keeps the floor free to pad with
            // rows that are merely quiet.
            if row.switchedOff { return 3 }
            switch row.lamp {
            case .ready, .working, .fault: return 0
            case .running: return 1
            case .unlit: return 2
            }
        }
        return (0...3).flatMap { rank in rows.filter { band($0) == rank } }
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
