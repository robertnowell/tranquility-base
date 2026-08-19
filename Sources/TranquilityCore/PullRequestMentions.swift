import Foundation

/// The pull requests a turn's own text names, read out of that text.
///
/// **Deterministic, never written by the model** — the same standing as
/// `branch`, and for the reason the first attempt got wrong.
///
/// Ruled 18 Aug: "the PR should absolutely be in the Hub." The first
/// implementation asked the summariser to copy any PR URL the message printed
/// and kept only URLs that appeared verbatim. That was safe and nearly inert:
/// two briefs in 1,299 carried a PR. The reason is embarrassing and worth
/// keeping written down — the evidence it was built on said sessions "named
/// the PR correctly, 7 for 7", and NAMING a PR is not PRINTING ITS URL.
/// Assistants write "PR #117". They paste the URL once, in the turn that opens
/// it, and never again. So the field fired on the one turn in a session that
/// least needed it and stayed empty for every turn where you actually want the
/// link — the ones about merging it.
///
/// What is still forbidden is unchanged and is the whole of the old rule: no
/// LOOKUP. Nothing here asks GitHub anything, and nothing infers WHICH pull
/// request from a branch — that is the mistake that announced "pull request
/// 2023 is merged" about a PR merged months earlier. The number comes from the
/// session's own sentence; only the repository comes from the working
/// directory, and a checkout's remote is a fact on disk, not a guess.
public enum PullRequestMentions {

    /// Every PR the text names, oldest mention first, deduplicated.
    ///
    /// Two shapes, and deliberately only two:
    ///
    /// 1. A full pull request URL, taken verbatim.
    /// 2. `PR #117` or `pull request #117`, turned into a URL with the repo
    ///    from `cwd`.
    ///
    /// A BARE `#117` is not enough, on purpose: it is also how issues, tickets,
    /// and ranked lists are written, and a hub that links "#3" from "the #3
    /// candidate" is worse than a hub that links nothing. The cue word is the
    /// evidence that the session meant a pull request.
    public static func found(in text: String, cwd: String?,
                             slug: (String) -> String? = repoSlug) -> [String] {
        var out: [String] = []
        func add(_ url: String) { if !out.contains(url) { out.append(url) } }

        for match in text.matches(of: urlPattern) {
            add(String(text[match.range]))
        }
        if let cwd, let repo = slug(cwd) {
            for match in text.matches(of: numberPattern) {
                let number = String(text[match.range]).drop { !$0.isNumber }
                guard !number.isEmpty else { continue }
                add("https://github.com/\(repo)/pull/\(number)")
            }
        }
        return out
    }

    /// `https://<host>/<owner>/<repo>/pull/<n>`, with the trailing punctuation
    /// a sentence wraps it in left behind.
    static var urlPattern: Regex<Substring> { /https?:\/\/[A-Za-z0-9.\-]+\/[A-Za-z0-9._\-]+\/[A-Za-z0-9._\-]+\/pulls?\/[0-9]+/ }

    /// `PR #117`, `pr#117`, `pull request #117`. The `#` is required: "PR 117"
    /// is how a sentence says "117 pull requests" as often as it names one.
    static var numberPattern: Regex<Substring> { /(?i)\b(?:pr|pull request)\s*#[0-9]+/ }

    // MARK: - The repository, from the checkout

    /// `owner/repo` for a working directory, from its `origin` remote.
    ///
    /// Cached per directory for the process's life: a checkout's remote does
    /// not change under it, and this is called once per finished turn on a
    /// machine running ten sessions.
    public static func repoSlug(cwd: String) -> String? {
        cacheLock.lock()
        if let hit = cache[cwd] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let resolved = readRemote(cwd).flatMap(parseSlug)
        cacheLock.lock(); cache[cwd] = resolved; cacheLock.unlock()
        return resolved
    }

    private nonisolated(unsafe) static var cache: [String: String?] = [:]
    private static let cacheLock = NSLock()

    /// `git@github.com:owner/repo.git` and `https://github.com/owner/repo`
    /// both reduce to `owner/repo`.
    static func parseSlug(_ remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let range = s.range(of: ":", options: .backwards),
           !s.hasPrefix("http"), s.contains("@") {
            s = String(s[range.upperBound...])                 // scp form
        } else if let range = s.range(of: "://") {
            let afterScheme = String(s[range.upperBound...])
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            s = String(afterScheme[afterScheme.index(after: slash)...])
        }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }

    private static func readRemote(_ cwd: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", cwd, "remote", "get-url", "origin"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
