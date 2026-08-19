import Foundation

/// The pull request for a branch, asked of GitHub.
///
/// Ruled 18 Aug, after two wrong mechanisms in one day. The first asked the
/// summariser to copy a PR URL out of the turn's text: safe, and it filled two
/// briefs in 1,299, because assistants write "PR #117" and paste the URL once.
/// The second read `PR #117` with a regex and took the repository from the
/// working directory: it filed a PR every time a turn MENTIONED one (172 rows
/// for 107 distinct pull requests, the same one filed twelve times), and it
/// assembled `robertnowell/tranquility-base/pull/2318` out of a sentence about
/// somebody else's repository — a link to a pull request that has never
/// existed.
///
/// The mechanism was wrong both times, and Kanban Code had the right one:
/// **key on the branch and ask GitHub.** Nothing is parsed out of prose,
/// nothing is assembled, and a branch has one newest pull request, so the
/// "mentioned six times" failure cannot occur by construction.
///
/// ## About the old ban on lookups
///
/// `SessionBrief` used to forbid exactly this, on the strength of one
/// incident: a lookup from the branch announced "pull request 2023 is merged"
/// for a PR merged months earlier whose branch was still checked out. That was
/// a real failure and the wrong lesson. What was missing was the ORDERING —
/// take the newest pull request for the branch, not any pull request that ever
/// matched it. Kanban Code's query says so in one clause
/// (`first: 1, orderBy: {field: CREATED_AT, direction: DESC}`), and `gh pr
/// list --limit 1` is the same thing.
///
/// ## And about state
///
/// The old design refused to show open/merged/closed, arguing a badge on a
/// page rewritten at every visit goes stale. True of a badge copied out of
/// text; false of one read from GitHub at render. State is the reason the page
/// is opened — "open, two approvals" is the answer to "can I merge this" — so
/// it is shown.
public enum GitHubPullRequests {

    public struct PR: Sendable, Equatable, Codable {
        public let number: Int
        public let title: String
        /// OPEN, MERGED, CLOSED — GitHub's own word, lowercased for display.
        public let state: String
        public let url: String
        public let approvals: Int
        /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil.
        public let reviewDecision: String?

        /// What the hub prints beside the number: the state, and the review
        /// position when there is one worth knowing. An unreviewed open PR
        /// says "open" and stops, because "open · review required" is the same
        /// sentence twice.
        public var status: String {
            var parts = [state.lowercased()]
            if state.uppercased() == "OPEN" {
                if approvals > 0 {
                    parts.append(approvals == 1 ? "1 approval" : "\(approvals) approvals")
                } else if reviewDecision == "CHANGES_REQUESTED" {
                    parts.append("changes requested")
                }
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - The snapshot

    /// The branch's pull request, from a snapshot at most 90 seconds old.
    ///
    /// **Never blocks.** A cold key returns nil and starts one refresh off the
    /// calling thread; the page renders without the row and the next render
    /// has it. The hub is written from the main actor when the card's door is
    /// tapped, and a subprocess there is the frozen-frame class this codebase
    /// has already paid for twice.
    public static func cached(repo: String, branch: String) -> PR? {
        cache.value(repo: repo, branch: branch)
    }

    /// Blocking. For callers already off the main thread — the hub write that
    /// follows every announcement runs detached, and warming the snapshot
    /// there is what makes the tapped-door render instant.
    @discardableResult
    public static func prime(repo: String, branch: String) -> PR? {
        cache.refreshNow(repo: repo, branch: branch)
    }

    /// The state of a pull request we already KNOW is ours, from its receipt.
    ///
    /// `gh pr view <url>` rather than `pr list --head <branch>`: there is
    /// nothing to discover here, only to read. Same snapshot rules — never
    /// blocks the render.
    public static func cachedByURL(_ url: String) -> PR? {
        cache.value(repo: "", branch: url)
    }

    @discardableResult
    public static func primeByURL(_ url: String) -> PR? {
        cache.refreshNow(repo: "", branch: url)
    }

    static let cache = Cache()

    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private let maxAge: TimeInterval
        /// The value is optional twice on purpose: no entry means never asked,
        /// an entry holding nil means asked and this branch has no pull
        /// request. Collapsing them would re-ask GitHub about every branch
        /// that never had one, on every render.
        private var entries: [String: (pr: PR?, at: Date)] = [:]
        private var inFlight: Set<String> = []
        var fetch: @Sendable (String, String) -> PR? = { repo, key in
            repo.isEmpty ? GitHubPullRequests.view(url: key)
                         : GitHubPullRequests.run(repo: repo, branch: key)
        }

        init(maxAge: TimeInterval = 90) { self.maxAge = maxAge }

        func value(repo: String, branch: String) -> PR? {
            let key = "\(repo)\t\(branch)"
            lock.lock()
            let entry = entries[key]
            let fresh = entry.map { Date().timeIntervalSince($0.at) <= maxAge } ?? false
            let claimed = !fresh && !inFlight.contains(key)
            if claimed { inFlight.insert(key) }
            lock.unlock()
            if claimed {
                DispatchQueue.global(qos: .utility).async { [self] in
                    let found = fetch(repo, branch)
                    lock.lock()
                    entries[key] = (found, Date()); inFlight.remove(key)
                    lock.unlock()
                }
            }
            return entry?.pr
        }

        @discardableResult
        func refreshNow(repo: String, branch: String) -> PR? {
            let found = fetch(repo, branch)
            lock.lock()
            entries["\(repo)\t\(branch)"] = (found, Date())
            lock.unlock()
            return found
        }

        func reset() {
            lock.lock(); entries = [:]; inFlight = []; lock.unlock()
        }
    }

    // MARK: - The query

    /// `gh pr list --head <branch> --limit 1`, which is Kanban Code's GraphQL
    /// in CLI form: the newest pull request whose head ref is this branch, in
    /// any state. `gh` carries the operator's own credentials, so nothing here
    /// stores a token.
    static func run(repo: String, branch: String) -> PR? {
        guard let gh = executable,
              !repo.isEmpty, !branch.isEmpty,
              // A branch name reaches this from a git command, but it ends up
              // in an argument list, so it is checked rather than trusted.
              branch.allSatisfy({ !$0.isWhitespace }), !branch.hasPrefix("-"),
              isAskable(branch)
        else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: gh)
        task.arguments = ["pr", "list", "--repo", repo, "--head", branch,
                          "--state", "all", "--limit", "1",
                          "--json", "number,title,state,url,reviewDecision,reviews"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    /// Branch names it is not worth asking about, and one it is dangerous to.
    ///
    /// "HEAD" is what a detached worktree reports, and it is not a branch — a
    /// third of the backfilled briefs carry it. `main` and `master` are worse
    /// than useless: a session sitting on the default branch has no feature
    /// branch and therefore no pull request of its own, but `--head main` can
    /// still match somebody's PR *from* main and put a stranger's work on the
    /// page. Silence is the correct answer for all three.
    static func isAskable(_ branch: String) -> Bool {
        !["HEAD", "main", "master", "trunk"].contains(branch)
    }

    /// One pull request by URL. The receipt already said which one; this only
    /// asks how it is doing.
    static func view(url: String) -> PR? {
        guard let gh = executable, PullRequestStore.isPullRequestURL(url) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: gh)
        task.arguments = ["pr", "view", url,
                          "--json", "number,title,state,url,reviewDecision,reviews"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        // `pr view` returns an object where `pr list` returns an array.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(try! JSONSerialization.data(withJSONObject: [obj]))
    }

    static func parse(_ data: Data) -> PR? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first,
              let number = row["number"] as? Int,
              let url = row["url"] as? String,
              let state = row["state"] as? String
        else { return nil }
        let reviews = (row["reviews"] as? [[String: Any]]) ?? []
        let approvals = reviews.filter { ($0["state"] as? String) == "APPROVED" }.count
        let decision = (row["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PR(number: number, title: (row["title"] as? String) ?? "",
                  state: state, url: url, approvals: approvals, reviewDecision: decision)
    }

    /// Homebrew's two prefixes, then the PATH. Resolved once — the app is not
    /// launched from a shell, so `gh` is not on its PATH by default and the
    /// bare name would fail.
    static let executable: String? = {
        for path in ["/usr/local/bin/gh", "/opt/homebrew/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }()
}

/// `owner/repo` for a checkout, from its `origin` remote.
///
/// The one thing the working directory is allowed to say about a pull request.
/// It does not decide WHICH pull request — the branch does that, through
/// GitHub — it only says which repository the branch belongs to, and a
/// checkout's remote is a fact on disk.
public enum GitRemote {

    /// The branch a checkout is on right now, or nil when it is detached or
    /// not a checkout at all.
    ///
    /// Read at the END OF A TURN, which is when the hook fires, so it is the
    /// branch that turn was on rather than a guess about history. It exists
    /// because the transcript's `gitBranch` is only as good as the session's
    /// own cwd: a session started from `~/Projects` — which is not a
    /// repository — records "HEAD" on all 954 of its entries while doing every
    /// piece of its work inside worktrees that are each on a real branch. That
    /// session opened six pull requests and its hub could show none of them,
    /// which is the failure this fixes.
    public static func currentBranch(cwd: String) -> String? {
        guard let out = run(["-C", cwd, "branch", "--show-current"], cwd: cwd) else { return nil }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // `--show-current` prints nothing on a detached HEAD, which is the
        // honest answer: a detached worktree is not on a branch, so it has no
        // pull request to find.
        return name.isEmpty ? nil : name
    }

    public static func slug(cwd: String) -> String? {
        cacheLock.lock()
        if let hit = cache[cwd] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let resolved = readRemote(cwd).flatMap(parseSlug)
        cacheLock.lock(); cache[cwd] = resolved; cacheLock.unlock()
        return resolved
    }

    private nonisolated(unsafe) static var cache: [String: String?] = [:]
    private static let cacheLock = NSLock()

    static func parseSlug(_ remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.contains("@"), !s.hasPrefix("http"),
           let colon = s.range(of: ":", options: .backwards) {
            s = String(s[colon.upperBound...])                  // scp form
        } else if let scheme = s.range(of: "://") {
            let after = String(s[scheme.upperBound...])
            guard let slash = after.firstIndex(of: "/") else { return nil }
            s = String(after[after.index(after: slash)...])
        }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
    }

    private static func readRemote(_ cwd: String) -> String? {
        run(["-C", cwd, "remote", "get-url", "origin"], cwd: cwd)
    }

    static func run(_ arguments: [String], cwd: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = arguments
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
