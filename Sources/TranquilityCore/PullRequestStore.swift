import Foundation

/// The pull requests a session actually opened, recorded from the receipt.
///
/// Fourth mechanism, and the first that does not guess. The three before it all
/// tried to work out a pull request from something ADJACENT to the act:
///
///   1. the summariser copying a URL out of the turn's prose — 2 briefs in 1,299,
///      because assistants write "PR #117" and paste the URL once;
///   2. a regex over that prose with the repository taken from the cwd — filed
///      a pull request every time a turn MENTIONED one, and assembled a link to
///      a pull request that had never existed;
///   3. asking GitHub which pull request the BRANCH has — correct, and useless
///      for the sessions that need it most. A session whose turns touch the main
///      checkout and three worktrees has no single branch, and the branch it
///      records is wherever its last shell command happened to leave it. Measured
///      on this repo's own session: the turn that opened `fix/the-cli-primes-the-hub`
///      recorded `main`, because the last command in it was a `cd` to poll a log.
///
/// The act itself is unambiguous. `gh pr create` prints the URL of the pull
/// request it just made, and the hook that sees every Bash call sees that
/// output. No inference, no cwd, no branch, no repeat when a later turn talks
/// about it — one line, written once, by the command that did the thing.
///
/// Deliberately the same shape as `ArtifactStore`: one small append-only file
/// per agent, `epochMs<TAB>url`, outside the events table for exactly the
/// reasons recorded there — a receipt is not a turn, and a new event kind read
/// by an older build would be filed as a finished turn and SPOKEN.
public enum PullRequestStore {

    public static func directory(root: String) -> String {
        (root as NSString).appendingPathComponent("pullrequests")
    }

    @discardableResult
    public static func record(_ url: String, session: String, root: String,
                              at: Date = Date()) -> Bool {
        guard ArtifactStore.isPlausibleSession(session), isPullRequestURL(url) else { return false }
        let dir = directory(root: root)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let target = (dir as NSString).appendingPathComponent(session)
        let line = "\(Int(at.timeIntervalSince1970 * 1000))\t\(url)\n"
        guard let data = line.data(using: .utf8) else { return false }
        let fd = open(target, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
    }

    public struct Receipt: Sendable, Equatable {
        public let url: String
        public let at: Date
        public var number: Int? {
            let parts = url.split(separator: "/")
            guard let i = parts.lastIndex(where: { $0 == "pull" || $0 == "pulls" }),
                  i + 1 < parts.count else { return nil }
            return Int(parts[i + 1].prefix { $0.isNumber })
        }
    }

    /// Everything this agent opened, oldest first, one entry per pull request.
    /// A URL recorded twice (a retried command, a re-run) is one receipt, and
    /// the FIRST stamp is kept — the moment it came into existence.
    public static func history(for session: String, root: String) -> [Receipt] {
        guard ArtifactStore.isPlausibleSession(session) else { return [] }
        let target = (directory(root: root) as NSString).appendingPathComponent(session)
        guard let text = try? String(contentsOfFile: target, encoding: .utf8) else { return [] }
        var seen: [String: Date] = [:]
        var order: [String] = []
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let ms = Double(parts[0]) else { continue }
            let url = String(parts[1])
            guard isPullRequestURL(url) else { continue }
            let at = Date(timeIntervalSince1970: ms / 1000)
            if seen[url] == nil { order.append(url); seen[url] = at }
        }
        return order.map { Receipt(url: $0, at: seen[$0]!) }
    }

    /// `https://<host>/<owner>/<repo>/pull/<number>`. Checked because the URL
    /// arrives from a hook parsing command output, and a receipt store that
    /// accepts anything is a text scraper with extra steps.
    public static func isPullRequestURL(_ url: String) -> Bool {
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return false }
        let parts = url.split(separator: "/")
        guard let i = parts.lastIndex(where: { $0 == "pull" || $0 == "pulls" }),
              i + 1 < parts.count, i >= 3 else { return false }
        let number = parts[i + 1].prefix { $0.isNumber }
        return !number.isEmpty && parts[i + 1].count == number.count
    }
}
