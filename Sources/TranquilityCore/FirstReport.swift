import Foundation

/// The one report that is allowed to take the screen.
///
/// A person who has just connected a Mac does not know reports exist. They
/// have been told that their agents write things and that the things appear
/// somewhere, and the first one has to be SEEN or the sentence stays
/// abstract. Robert, 11 Sep: "let's continue hijacking the browser and just
/// switching tabs for now, it's a short-lived thing."
///
/// Short-lived is the whole design. This fires ONCE, for the first page a Mac
/// ever mirrors, and then never again: every later report is a toast, a climb
/// up the sidebar and a Dock badge, none of which take the screen from you.
/// A thing that steals focus twice is a thing people learn to resent, and the
/// second time teaches nothing the first did not.
///
/// The flag lives in defaults rather than in the mirror's own state file
/// because it is a preference, not a record of work: somebody who turns it
/// off wants it off, and somebody who deletes the mirror's state to force a
/// re-sync does not want their screen taken again.
public enum FirstReport {
    static let key = "hub.revealFirstReport"

    /// Injectable so a test never touches the machine's own defaults.
    public nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// True until it has fired, or somebody turned it off. Absent means on:
    /// the machine that has never thought about this is the new machine.
    public static var pending: Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// It happened. Nothing takes the screen after this.
    public static func spent() { defaults.set(false, forKey: key) }

    /// For a switch in Setup, and for the day the hub reports that it is
    /// installed as an app, where hijacking a tab is the wrong move entirely.
    public static func set(_ on: Bool) { defaults.set(on, forKey: key) }
}
