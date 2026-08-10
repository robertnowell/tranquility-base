import Foundation

/// What a page is allowed to ask this app to do, and on what terms.
///
/// A deep link is the one control surface this app exposes to the open web:
/// ANY page in a browser can fire one, and the only thing standing in front of
/// it is the browser's own "open Tranquility Base?" sheet. So the rules are
/// stricter here than anywhere else in the app, and they are HERE — in Core,
/// as pure functions over strings — rather than inside the AppKit handler,
/// because the handler needs a window server and cannot be tested, while this
/// is the part that has to be right.
///
/// Two standing rules, and everything below enforces one of them:
///
/// 1. **No deep link may record, send, or type.** Speaking and raising a panel
///    are safe: you can hear what happened and you can see who asked. Opening a
///    microphone from a URL is a page deciding you had something to say. This
///    is why `discuss` — the action a generated page carries — resolves to
///    speech, and never to capture.
/// 2. **A page's strings never reach a shell.** The invitation builds a command
///    out of the artifact's own path, which arrives from the URL. That path is
///    interpolated through AppleScript INTO a shell, so two quoting layers have
///    to hold at once. `artifact(from:exists:)` refuses anything that could
///    make either of them slip, and refuses anything that is not already a file
///    on this disk — which alone kills the whole class, since an attacker's
///    string has to name something you already have.
public enum DeepLink {

    public enum Action: Equatable {
        /// The action a generated page carries: put me in front of the agent
        /// that wrote this. `ref` is the page itself.
        case discuss(session: String?, ref: String?)
        case hear(session: String?)
        case reply(session: String?)
        case show
        case unknown(String)
    }

    /// The scheme is deliberately not inspected. `tranquilitybase` is the app's
    /// name and `voicedispatch` is what it used to be called; both are
    /// registered, both mean the same thing, and a page written a month ago
    /// must not stop working because the app was renamed.
    public static func parse(_ url: URL) -> Action {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        func value(_ name: String) -> String? {
            let raw = items?.first(where: { $0.name == name })?.value
            return (raw?.isEmpty ?? true) ? nil : raw
        }
        switch url.host ?? "" {
        case "discuss": return .discuss(session: value("session"), ref: value("ref"))
        case "hear":    return .hear(session: value("session"))
        case "reply":   return .reply(session: value("session"))
        case "show":    return .show
        case let other: return .unknown(other)
        }
    }

    /// Characters that cannot appear in an artifact path the invitation is
    /// willing to build a command from.
    ///
    /// The quote pair is the obvious one: the path lands inside single quotes
    /// in a shell command, which itself lands inside a double-quoted AppleScript
    /// literal. A backslash is AppleScript's own escape and would corrupt the
    /// literal before the shell ever sees it. A backtick and a dollar are
    /// inert inside single quotes today — and are refused anyway, because the
    /// cost of refusing is one clipboard fallback and the cost of being wrong
    /// is a command someone else wrote.
    static let forbidden: Set<Character> = ["'", "\"", "\\", "`", "$"]

    /// The artifact a page names — or nil, which is a complete answer.
    ///
    /// `exists` is injected so this stays a pure function under test. In the app
    /// it is `FileManager.fileExists`, and it is the load-bearing check: a page
    /// can put any string in a URL, but it cannot put a file on your disk.
    public static func artifact(from ref: String?,
                                home: String = NSHomeDirectory(),
                                exists: (String) -> Bool) -> String? {
        guard let ref, !ref.isEmpty else { return nil }
        // Control characters first: a newline would end the shell command and
        // begin another one, and it is the only forbidden character that can
        // arrive invisibly.
        guard !ref.contains(where: { $0.unicodeScalars.contains { CharacterSet
            .controlCharacters.contains($0) } }) else { return nil }
        guard !ref.contains(where: { forbidden.contains($0) }) else { return nil }
        let path = ref.hasPrefix("~")
            ? home + String(ref.dropFirst())
            : ref
        // Relative paths have no meaning here: the app's working directory is
        // wherever it was launched from, which is not where the page lives.
        guard path.hasPrefix("/") else { return nil }
        guard exists(path) else { return nil }
        return path
    }

    /// What the new session opens holding. Built from a path that has already
    /// passed `artifact(from:exists:)`; passing anything else is a programming
    /// error, so this asserts rather than sanitizing twice.
    public static func openingPrompt(for path: String) -> String {
        "Read \(path) — I want to talk about it. "
        + "Start by telling me what it is and where it stands."
    }

    /// The launch command, single-quoted for the shell. Nil is not a failure:
    /// it means the session should start blank with the prompt on the
    /// clipboard, which is a small loss next to a window of shell errors being
    /// the first thing a new user sees.
    public static func openingCommand(base: String, prompt: String) -> String? {
        guard !prompt.contains(where: { forbidden.contains($0) }) else { return nil }
        return "\(base) '\(prompt)'"
    }
}
