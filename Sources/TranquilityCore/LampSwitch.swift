import Foundation

/// The sessions the user has switched OFF, and the rule for when one comes back.
///
/// Ruled 18 Aug. The lamp is the grid's membership control, and it has exactly
/// two ways to lose you a row — Robert: *"a session goes to the second page for
/// one of two reasons: I click the lamp and turn it off, or it gets booted out
/// because there are more than fit on my screen."* The second reason is
/// `StatusHUD.gridRowsShown`, which counts. This is the first, which remembers.
///
/// It has to be remembered ACROSS launches. A decision the user made with a
/// click, silently undone by the next restart, is worse than no switch at all:
/// the panel would come back full of rows they had already dealt with, and the
/// gesture would read as broken rather than forgotten.
///
/// **Deliberately not the read cursor, and not `dismiss`.** Those are about a
/// TURN — one message, heard or not — and they already exist; `onClearLamp` has
/// called `dismiss` since 06 Aug and should keep doing it, because switching a
/// GREEN lamp off means both things at once (stop asking me, and take the row).
/// This is about a SESSION's place on the panel. It outlives any particular
/// turn, and conflating the two would mean the next thing an agent happened to
/// say put the row back on the grid.
///
/// **Turning a lamp off is not killing anything.** The process keeps running,
/// the session keeps its transcript, and it keeps its row in Past Agents. The
/// only thing that changes is which of the two faces draws it. Terminate is a
/// different verb on a different gesture (right-click) and always has been.
public enum LampSwitch {

    /// Where the sets live. One file each, rewritten whole: they are a handful
    /// of uuids, they are written on a click and read on a repaint, and
    /// anything cleverer would be a database for a set that fits in a tweet.
    public static var url: URL {
        QueueStore.supportDirectory.appendingPathComponent("lamp-off.json")
    }

    /// The sessions the user has switched ON — the other half of the switch,
    /// added 19 Aug because it had been missing since the switch was ruled.
    ///
    /// The 18 Aug ruling described a two-way control: *"if I'm on past agents
    /// and I click the lamp and it's idle, it goes back into the grid, takes
    /// the lamp colour whatever the state is."* Only one direction was ever
    /// stored. Turning a lamp ON did nothing but erase an OFF, so a session
    /// that was in the list because it had simply gone quiet — the common case,
    /// and every case since 18 Aug made quiet mean page two — could not be
    /// brought back at all: the click erased a switch that was not there and
    /// the row stayed exactly where it was.
    ///
    /// Robert, 19 Aug, clicking one: *"when I click on an idle agent … it
    /// should turn the lamp on, open the agent card. Because it's alive,
    /// clicking on it obviously means I want it to be alive. Now it's in the
    /// grid."* So ON is a fact the user states, exactly like OFF, and it is
    /// kept the same way.
    public static var onURL: URL {
        QueueStore.supportDirectory.appendingPathComponent("lamp-on.json")
    }

    // MARK: - The rule

    /// Whether this session sits in the list rather than on the grid.
    ///
    /// The one exception is the whole of the policy, so it is stated here
    /// rather than in a call site: **a waiting turn turns the lamp back on.**
    ///
    /// Green is the needs-you channel. A session that is waiting on the user is,
    /// by definition, the thing the panel exists to show them, and a panel that
    /// hides it because they filed the session an hour ago has lost their work
    /// on their behalf. The switch is not overridden so much as spent: the user
    /// switched off the session as it was, the session has since asked for
    /// something new, and one click switches it off again.
    ///
    /// Blue and amber deliberately do NOT override it. An agent working, or
    /// stuck on a usage limit, is news — it is not a request — and "I do not
    /// need to watch this one" has to survive the session continuing to do
    /// things, or the switch would be undone within seconds by the very work
    /// the user just said they did not want to watch.
    public static func isOff(_ sessionId: String, waiting: Bool,
                             switchedOff: Set<String>) -> Bool {
        guard switchedOff.contains(sessionId) else { return false }
        return !waiting
    }

    /// Whether the user has picked this session up.
    ///
    /// The mirror of `isOff` and deliberately simpler: OFF needs its exception
    /// because a filed session can start asking for you, and the panel must not
    /// hide a request. ON has no such case — a session the user switched on and
    /// which then starts working, or asks a question, is lit anyway and by a
    /// better rule than this one. This only decides the rows nothing else lights.
    public static func isOn(_ sessionId: String, switchedOn: Set<String>) -> Bool {
        switchedOn.contains(sessionId)
    }

    // MARK: - The set

    /// The sessions the user has picked up. Its own reader so call sites say
    /// which half of the switch they mean, rather than passing a url.
    public static func loadOn(from url: URL = LampSwitch.onURL) -> Set<String> {
        load(from: url)
    }

    public static func load(from url: URL = LampSwitch.url) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    /// Sorted on the way out so the file is stable across writes — a set's
    /// iteration order is not, and a file that reshuffles itself on every click
    /// is unreadable in a diff and unhelpful in a bug report.
    public static func save(_ ids: Set<String>, to url: URL = LampSwitch.url) {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        try? PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
        try? data.write(to: url)
        PrivateStorage.protect(url)
    }

    /// A session is in at most ONE of the two sets, and both writes say so.
    /// Anything else is a switch that remembers being pressed in both
    /// directions, which is not a switch.
    @discardableResult
    public static func turnOff(_ sessionId: String,
                               at url: URL = LampSwitch.url,
                               onAt onUrl: URL = LampSwitch.onURL) -> Set<String> {
        var on = load(from: onUrl)
        if on.remove(sessionId) != nil { save(on, to: onUrl) }
        var ids = load(from: url)
        ids.insert(sessionId)
        save(ids, to: url)
        return ids
    }

    @discardableResult
    public static func turnOn(_ sessionId: String,
                              at url: URL = LampSwitch.url,
                              onAt onUrl: URL = LampSwitch.onURL) -> Set<String> {
        var ids = load(from: url)
        ids.remove(sessionId)
        save(ids, to: url)
        var on = load(from: onUrl)
        on.insert(sessionId)
        save(on, to: onUrl)
        return on
    }

    /// Drop ids for sessions that no longer exist anywhere.
    ///
    /// Without this the file grows for the life of the install, and every entry
    /// in it is a row the grid has to ask about on every repaint. Called with
    /// the ids the panel can currently see; anything else is a session whose
    /// transcript has aged out, and a switch on a session you can no longer
    /// reach is not a preference, it is litter.
    ///
    /// Deliberately NOT called on the repaint path itself. Pruning against a
    /// row set that is momentarily short — a scan that has not finished, a
    /// discovery that failed open — would throw away switches for sessions that
    /// are about to come back, and the user would find rows they had filed
    /// sitting on the grid again with no explanation.
    @discardableResult
    public static func prune(keeping known: Set<String>,
                             at url: URL = LampSwitch.url,
                             onAt onUrl: URL = LampSwitch.onURL) -> Set<String> {
        let keptOn = load(from: onUrl).intersection(known)
        save(keptOn, to: onUrl)
        let kept = load(from: url).intersection(known)
        save(kept, to: url)
        return kept
    }
}
