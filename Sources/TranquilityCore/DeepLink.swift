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
///    out of the subject the page names, which arrives from the URL. It is
///    interpolated through AppleScript INTO a shell, so two quoting layers have
///    to hold at once. `subject(from:exists:)` refuses anything that could make
///    either of them slip.
///
/// A subject is one of exactly two things, and the difference is where the page
/// came from. A LOCAL page names a file, and that file must already exist on
/// this disk — which alone kills the injection class, since an attacker's
/// string has to name something you already have. A HOSTED page cannot name a
/// local file (it lives on someone else's machine, and its own footer has been
/// stripped of any path by the publisher), so it names its own https URL. That
/// cannot be checked for existence, so it is constrained by shape instead:
/// https only, no credentials, no forbidden characters, and a length cap.
public enum DeepLink {

    public enum Action: Equatable {
        /// The action a generated page carries: put me in front of the agent
        /// that wrote this. `ref` is the page itself.
        case discuss(session: String?, ref: String?)
        /// The agent's own page: everything it has done, and everything it has
        /// made. `ref` rides along so a session this Mac has never seen still
        /// gets the invitation rather than silence.
        case home(session: String?, ref: String?)
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
        case "home":    return .home(session: value("session"), ref: value("ref"))
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

    /// What a page is about: a file on this disk, or the page's own address.
    public enum Subject: Equatable {
        /// An absolute path that exists on this Mac. The local case.
        case file(String)
        /// An https URL. The hosted case — a page someone else published, whose
        /// footer carries no session and no path because the publisher removed
        /// them. A fresh agent can still read it, which is the whole point.
        case page(String)

        /// What the invitation calls it.
        public var name: String {
            switch self {
            case .file(let path): return (path as NSString).lastPathComponent
            case .page(let url):
                return URL(string: url)?.host.map { host in
                    let tail = URL(string: url)?.lastPathComponent ?? ""
                    return tail.isEmpty || tail == "/" ? host : "\(host)/\(tail)"
                } ?? url
            }
        }

        /// Where a session about it should start. A hosted page belongs to no
        /// directory here, so it opens at home rather than wherever the app
        /// happened to be launched from.
        public var directory: String {
            switch self {
            case .file(let path): return (path as NSString).deletingLastPathComponent
            case .page: return NSHomeDirectory()
            }
        }

        public var reference: String {
            switch self { case .file(let s): return s; case .page(let s): return s }
        }
    }

    /// The longest URL the invitation will carry. Well past any real page URL,
    /// and short enough that a command line cannot be padded out with one.
    static let maxURLLength = 2048

    /// The subject a page names — or nil, which is a complete answer.
    ///
    /// `exists` is injected so this stays a pure function under test. In the app
    /// it is `FileManager.fileExists`, and for the local case it is the
    /// load-bearing check: a page can put any string in a URL, but it cannot put
    /// a file on your disk.
    public static func subject(from ref: String?,
                               home: String = NSHomeDirectory(),
                               exists: (String) -> Bool) -> Subject? {
        guard let ref, !ref.isEmpty, ref.count <= maxURLLength else { return nil }
        // Control characters first: a newline would end the shell command and
        // begin another one, and it is the only forbidden character that can
        // arrive invisibly.
        guard !ref.contains(where: { $0.unicodeScalars.contains { CharacterSet
            .controlCharacters.contains($0) } }) else { return nil }
        guard !ref.contains(where: { forbidden.contains($0) }) else { return nil }

        if ref.lowercased().hasPrefix("https://") {
            // Shape, since existence cannot be checked. A host is required —
            // "https:///etc" names nothing — and credentials are refused
            // outright: a URL carrying a password is not something to put in a
            // card, a command line, or the clipboard.
            guard let url = URL(string: ref), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return nil }
            return .page(ref)
        }
        // Anything else that looks like a scheme is refused by name rather than
        // by omission: http (plaintext), file, javascript, data — a page gets
        // to name a local path or its own secure address, and nothing else.
        guard !ref.contains("://") else { return nil }

        let path = ref.hasPrefix("~") ? home + String(ref.dropFirst()) : ref
        // Relative paths have no meaning here: the app's working directory is
        // wherever it was launched from, which is not where the page lives.
        guard path.hasPrefix("/"), exists(path) else { return nil }
        return .file(path)
    }

    /// What the new session opens holding. Built from a path that has already
    /// passed `artifact(from:exists:)`; passing anything else is a programming
    /// error, so this asserts rather than sanitizing twice.
    public static func openingPrompt(for subject: Subject) -> String {
        "Read \(subject.reference) — I want to talk about it. "
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
