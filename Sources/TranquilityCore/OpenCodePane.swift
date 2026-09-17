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
/// One pane per session, named after it, hosted the first time THIS app
/// sends the session a turn (start, or send) and kept until End Agent. Not
/// at adoption: a TUI is a ~400 MB Bun process, and a session that finished
/// last week has nothing to ask; its row keeps the plain attach door until
/// it is spoken to. Panes whose attach has exited (their server was last
/// launch's) are swept at connect. `remain-on-exit` stays on so an attach
/// that dies leaves its last screen, and the reason, where the next Go to
/// Agent will show it.
public enum OpenCodePane {
    /// "tb-oc-<port>-" + the session's own id (already in tmux's safe
    /// charset: `ses_` and base62; anything else is refused, not mangled).
    /// The port is in the name because a TUI outlives its server (a blind
    /// one on a dead port ran for 16 h at 20% CPU, 17 Sep): last launch's
    /// pane must never read as this launch's, whatever tmux says.
    public static func name(for raw: String, port: Int) -> String? {
        let name = "tb-oc-\(port)-\(raw)"
        guard name.count <= 64,
              name.unicodeScalars.allSatisfy({ TerminalTabFocus.sessionNameCharset.contains($0) })
        else { return nil }
        return name
    }

    /// Kill any pane of this name and create one running `command` in
    /// `directory`. Best effort: a pane that cannot be made leaves the row
    /// with its `shell` door, which is the old (blind) attach.
    @discardableResult
    public static func host(raw: String, port: Int, command: String, directory: String) -> String? {
        guard let name = name(for: raw, port: port) else { return nil }
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

    /// The TUI has drawn something: it is connected and will see the next
    /// ask. Polled before the first prompt goes, bounded, so a send never
    /// waits on a pane that will not come.
    public static func hasDrawn(raw: String, port: Int) -> Bool {
        guard let name = name(for: raw, port: port),
              case .success(let out) = Tmux.run(["capture-pane", "-p", "-t", name],
                                                socket: Tmux.socketName, timeout: 5)
        else { return false }
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Kill every pane of ours on a port nobody serves any more (last
    /// launch's, dead or blind) or whose attach has exited. Another
    /// instance's live panes, on a port that answers, are left alone.
    public static func sweepStale(keeping port: Int, listening: (Int) -> Bool = isListening) {
        guard case .success(let out) = Tmux.run(
            ["list-sessions", "-F", "#{session_name} #{pane_dead}"], socket: Tmux.socketName, timeout: 5)
        else { return }
        for line in out.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2, let theirs = portInName(String(fields[0])) else { continue }
            let dead = fields[1] == "1"
            guard dead || (theirs != port && !listening(theirs)) else { continue }
            _ = Tmux.run(["kill-session", "-t", String(fields[0])], socket: Tmux.socketName, timeout: 5)
        }
    }

    static func portInName(_ name: String) -> Int? {
        guard name.hasPrefix("tb-oc-") else { return nil }
        let rest = name.dropFirst("tb-oc-".count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int(rest[..<dash])
    }

    /// Does anything answer on 127.0.0.1:port? A connect, not a request:
    /// the question is whether a server is there at all.
    public static func isListening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    public static func kill(raw: String, port: Int) {
        guard let name = name(for: raw, port: port) else { return }
        _ = Tmux.run(["kill-session", "-t", name], socket: Tmux.socketName, timeout: 5)
    }

    /// Is the pane there, and its process alive? A dead pane (attach
    /// exited) reads as false, so a seed recreates it.
    public static func isLive(raw: String, port: Int) -> Bool {
        guard let name = name(for: raw, port: port) else { return false }
        guard case .success(let out) = Tmux.run(
            ["display-message", "-p", "-t", name, "#{pane_dead}"], socket: Tmux.socketName, timeout: 5)
        else { return false }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }
}
