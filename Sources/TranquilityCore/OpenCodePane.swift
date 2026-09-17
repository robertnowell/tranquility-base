import Foundation

/// The screen of a served OpenCode agent: its own TUI, attached to its
/// session on our server, living in a detached tmux session on this app's
/// socket from the moment the agent exists.
///
/// Why a pane and not a window per tap. OpenCode's TUI shows a permission
/// only if it was attached BEFORE the ask (measured 17 Sep against 1.18.31:
/// a TUI attached after `permission.asked` never draws it, and
/// `/tui/select-session` and `/tui/publish` cannot surface it). So the door
/// Go to Agent opens cannot be "run `opencode attach` now": by the time the
/// lamp is amber, the ask has happened and the fresh window is blind. The
/// TUI has to be there already, in a pane nobody is looking at, and Go to
/// Agent raises the one window on that pane or attaches one. That is the
/// local rows' door, with the pane named instead of looked up. Robert,
/// 17 Sep 8:50 AM: "it attaches a new window and you don't see the prompt
/// ... it doesn't end the old window ... this cannot work."
///
/// One pane per session, named after it. Created at `start` and at
/// adoption, recreated at every seed (the served port changes per launch, so
/// a pane from the last launch is attached to a server that is gone), killed
/// on forget. `remain-on-exit` stays on so an attach that dies leaves its
/// last screen, and the reason, where the next Go to Agent will show it.
public enum OpenCodePane {
    /// "tb-oc-" + the session's own id, which is already in tmux's safe
    /// charset (`ses_` and base62). Anything else is refused, not mangled.
    public static func name(for raw: String) -> String? {
        let name = "tb-oc-\(raw)"
        guard name.count <= 64,
              name.unicodeScalars.allSatisfy({ TerminalTabFocus.sessionNameCharset.contains($0) })
        else { return nil }
        return name
    }

    /// Kill any pane of this name and create one running `command` in
    /// `directory`. Best effort: a pane that cannot be made leaves the row
    /// with its `shell` door, which is the old (blind) attach.
    @discardableResult
    public static func host(raw: String, command: String, directory: String) -> String? {
        guard let name = name(for: raw) else { return nil }
        _ = Tmux.run(["kill-session", "-t", name], socket: Tmux.socketName, timeout: 5)
        let path = ([ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
                    + ["/usr/local/bin", "/opt/homebrew/bin"]).joined(separator: ":")
        switch Tmux.run([
            "new-session", "-d", "-s", name,
            "-x", "\(TerminalTabFocus.humanAttachColumns)", "-y", "\(TerminalTabFocus.humanAttachRows)",
            "-c", directory, "-e", "PATH=\(path)", "-e", "LANG=en_US.UTF-8",
            "/bin/zsh", "-c", SessionLauncher.paneCommand(path: path, directory: directory, command: command),
            ";", "set", "-t", name, "remain-on-exit", "on",
        ], socket: Tmux.socketName, timeout: 10) {
        case .success: return name
        case .failure: return nil
        }
    }

    public static func kill(raw: String) {
        guard let name = name(for: raw) else { return }
        _ = Tmux.run(["kill-session", "-t", name], socket: Tmux.socketName, timeout: 5)
    }

    /// Is the pane there, and its process alive? A dead pane (attach
    /// exited) reads as false, so a seed recreates it.
    public static func isLive(raw: String) -> Bool {
        guard let name = name(for: raw) else { return false }
        guard case .success(let out) = Tmux.run(
            ["display-message", "-p", "-t", name, "#{pane_dead}"], socket: Tmux.socketName, timeout: 5)
        else { return false }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }
}
