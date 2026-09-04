import Foundation

/// The most recent page a session made, so the panel can offer to open it.
///
/// This deliberately does NOT go through the spool and the events table. Two
/// reasons, and the second is the one that matters:
///
/// 1. There is nothing to announce. An artifact is not a turn; it has no
///    summary, no callsign line, no place in the waiting queue. Putting it in
///    `events` would mean teaching every query that reads that table to exclude
///    a row type it never wants.
/// 2. `SpoolRecord.toEvent()` maps an unknown `hookEvent` to `.stop`. A new
///    event kind written by a new hook and read by an older build would
///    therefore be filed as a finished turn and SPOKEN — the user hearing a
///    summary of a file write, from a hook they installed for a button. A
///    separate file cannot do that to anyone.
///
/// So: one small file per agent, appended to. It began as a single path
/// replaced by rename, which answered the panel button ("open the newest page")
/// and nothing else — and the hub then needed the LIST. An append-only log of
/// `epochMs<TAB>path` answers both: the last line is the newest page, the whole
/// file is the agent's body of work. A single small write with O_APPEND is
/// atomic, so concurrent turns cannot interleave, and a line without a tab is
/// read as a bare path so records written by the older hook still resolve.
public enum ArtifactStore {

    public static func directory(root: String) -> String {
        (root as NSString).appendingPathComponent("artifacts")
    }

    /// A session id is a UUID from the harness, but it arrives here from a hook
    /// payload and ends up in a path, so it is checked rather than trusted:
    /// anything but hex and dashes could escape the directory.
    public static func isPlausibleSession(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    @discardableResult
    /// `resolve` is injectable for the same reason `history`'s `exists` is: the
    /// behaviour under test is what gets WRITTEN, and every temp directory this
    /// repo can create is one `excluded` refuses by design.
    public static func record(_ path: String, session: String, root: String,
                              at: Date = Date(),
                              resolve: (String) -> String = canonical) -> Bool {
        guard isPlausibleSession(session), path.hasPrefix("/"),
              !excluded(path) else { return false }
        let dir = directory(root: root)
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let target = (dir as NSString).appendingPathComponent(session)
        // WHERE THE FILE IS, not the name it was reached by.
        //
        // The corpus moved under the agents tree and every old location became a
        // symlink, so a path recorded through one still opens. That is not
        // enough: the record is what a hub renders, so a hub kept pointing at
        // the address that was retired, and the symlinks could never be removed.
        //
        // Repointing the records fixed it for an hour. Then `backfill` re-mined
        // the transcripts, which name the paths that were true when they were
        // written, and put 209 of them back. A one-off repair cannot beat a
        // process that regenerates the thing being repaired, so the resolution
        // belongs here, where every writer passes.
        //
        // Only when the file exists: resolving a path that does not resolve
        // invents one, and a missing page should be recorded as it was named so
        // the miss is visible.
        let resolved = resolve(path)
        let line = "\(Int(at.timeIntervalSince1970 * 1000))\t\(resolved)\n"
        guard let data = line.data(using: .utf8) else { return false }
        let fd = open(target, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
    }

    /// Where the file is, when it is there.
    ///
    /// Only when it exists: resolving a path that does not resolve invents one,
    /// and a missing page should be recorded as it was named so the miss stays
    /// visible rather than being tidied into something that looks fine.
    public static func canonical(_ path: String) -> String {
        FileManager.default.fileExists(atPath: path)
            ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            : path
    }

    /// One recorded page.
    public struct Page: Sendable, Equatable {
        public let path: String
        public let at: Date
        public var name: String { (path as NSString).lastPathComponent }
        /// The directory a page lives in usually names it better than
        /// "index.html" does.
        public var label: String {
            let dir = (path as NSString).deletingLastPathComponent
            let leaf = (dir as NSString).lastPathComponent
            return name == "index.html" && !leaf.isEmpty ? leaf : name
        }
    }

    /// Everything this agent has made, oldest first, deduplicated by path with
    /// the FIRST write kept — a page rewritten eight times in one turn is one
    /// page, and the moment it first appeared is the moment worth showing.
    public static func history(for session: String, root: String,
                               exists: (String) -> Bool = {
                                   FileManager.default.fileExists(atPath: $0)
                               }) -> [Page] {
        guard isPlausibleSession(session) else { return [] }
        // TWO record files, merged: the full session id, and the SLUG.
        //
        // A report at agents/<slug>/<name>.html carries only the slug — that is
        // all a path has room for — so the hook keys those records by slug while
        // everything else is keyed by the full id. Reading both is what lets a
        // page name its own author in its own path and still be found by the hub
        // that owns it. The slug is derived from the id, never stored, so the two
        // cannot drift.
        let dir = directory(root: root) as NSString
        let slug = HomeBase.slug(forSessionId: session)
        var targets = [dir.appendingPathComponent(session)]
        let slugTarget = dir.appendingPathComponent(slug)
        if slugTarget != targets[0] { targets.append(slugTarget) }
        let text = targets
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .joined(separator: "\n")
        guard !text.isEmpty else { return [] }
        var seen: [String: Date] = [:]
        var order: [String] = []
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "\t", maxSplits: 1)
            let recorded = String(parts.count == 2 ? parts[1] : parts[0])
            guard recorded.hasPrefix("/"), !excluded(recorded) else { continue }
            // Resolved to what renders, not to what was written. A recorded
            // fragment becomes the finished page beside it; one with no finished
            // page yet is still mid-build and has nothing faithful to show.
            //
            // Resolution BEFORE dedup on purpose: a project whose body and
            // index.html were both recorded collapses to one entry, which is
            // right — they are one report, and listing both is how the same work
            // came to appear twice with one copy unstyled.
            guard let path = faithfulRendering(of: recorded) else { continue }
            // THE PAGE HAS A VOTE. A record is a claim; the page itself is
            // evidence, and when a page names a different agent the claim is
            // false — somebody wrote a report into another agent's directory
            // and the hook of the day recorded it here (02 Sep: two reports
            // listed on two hubs at once). Filtering at read time rather than
            // rewriting the log keeps this out of a hot append path, and makes
            // the hub and `tbase doctor` agree by construction: they both come
            // through here.
            if !belongs(page: path, to: slug) { continue }
            let ms = parts.count == 2 ? Double(parts[0]) ?? 0 : 0
            // A line with no stamp (the hook wrote path-only lines for a
            // while) is not "31 Dec 1969" — epoch zero rendered as a date is
            // the page claiming knowledge it does not have. The file's own
            // mtime is the honest substitute; only when the file cannot answer
            // either does the page get no date at all.
            let at = ms > 0 ? Date(timeIntervalSince1970: ms / 1000)
                : (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                    as? Date ?? .distantPast
            // LATEST wins. Keeping the first sighting pinned a page to the turn
            // that started it, so a report worked on across three turns stayed
            // filed under the oldest one and never appeared beside the work
            // that finished it (measured 16 Aug on a research page rewritten
            // twice). A page's date is when it last became what it is.
            if let already = seen[path] { seen[path] = max(already, at) }
            else { seen[path] = at; order.append(path) }
        }
        return order.filter(exists).map { Page(path: $0, at: seen[$0] ?? .distantPast) }
    }

    /// The page to offer, or nil — and nil is the common case, so every caller
    /// must render without it.
    ///
    /// The existence check is not defensive tidiness: pages get regenerated,
    /// moved into HQ, and deleted, and a button that opens a file that is gone
    /// is worse than no button, because it spends a click to say nothing.
    public static func latest(for session: String, root: String,
                              exists: (String) -> Bool = {
                                  FileManager.default.fileExists(atPath: $0)
                              }) -> String? {
        guard isPlausibleSession(session) else { return nil }
        let target = (directory(root: root) as NSString)
            .appendingPathComponent(session)
        guard let contents = try? String(contentsOfFile: target, encoding: .utf8)
        else { return nil }
        // The newest page is the last line that still names something on disk —
        // not simply the last line, because the file a turn wrote can be moved
        // or deleted before anyone clicks.
        for raw in contents.split(separator: "\n").reversed() {
            let parts = raw.split(separator: "\t", maxSplits: 1)
            let path = String(parts.count == 2 ? parts[1] : parts[0])
            if path.hasPrefix("/"), exists(path) { return path }
        }
        return nil
    }
}

public extension ArtifactStore {

    /// Recover an agent's pages from its transcript.
    ///
    /// The hook only started recording when it was installed, so every agent
    /// that ran before then shows no pages at all — which is worse than wrong,
    /// because a hub that says "0 pages" about an agent with six of them
    /// teaches the reader not to trust the number. The transcript has been
    /// recording the same fact all along: every Write of an .html file, with a
    /// timestamp. This reads it once and fills the log in.
    ///
    /// Deliberately additive and idempotent: it appends only paths the log does
    /// not already carry, so running it twice is a no-op and a live agent's
    /// newer records are never disturbed.
    @discardableResult
    static func backfill(session: String, transcriptPath: String, root: String) -> Int {
        guard isPlausibleSession(session),
              let handle = FileHandle(forReadingAtPath: transcriptPath),
              let data = try? handle.readToEnd() else { return 0 }
        try? handle.close()
        let known = Set(history(for: session, root: root, exists: { _ in true })
            .map(\.path))
        var added = 0
        var seen = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count > 2,
                  let text = String(data: Data(line), encoding: .utf8),
                  text.contains(".html"), text.contains("tool_use"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any] else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(Self.iso8601) ?? Date()
            let message = object["message"] as? [String: Any]
            for block in (message?["content"] as? [[String: Any]]) ?? [] {
                guard block["type"] as? String == "tool_use",
                      let tool = block["name"] as? String,
                      let input = block["input"] as? [String: Any] else { continue }
                var paths: [String] = []
                if ["Write", "Edit", "NotebookEdit"].contains(tool),
                   let path = input["file_path"] as? String {
                    paths = [path]
                } else if tool == "Bash", let command = input["command"] as? String,
                          command.contains(".html"), Self.writesAFile(command) {
                    // Pages born in a heredoc or a cp are pages too. A session
                    // that writes its report via Bash left no file_path for
                    // the hook, and its hub listed nothing (measured 15 Aug:
                    // a post-mortem written by heredoc, invisible on the
                    // hub). Mine the command text for absolute .html paths,
                    // and let the existence check below keep out the noise a
                    // command line can carry.
                    paths = Self.htmlPaths(in: command)
                }
                for path in paths {
                    guard path.hasSuffix(".html"), path.hasPrefix("/"),
                          !known.contains(path), !seen.contains(path),
                          tool != "Bash"
                            || FileManager.default.fileExists(atPath: path)
                    else { continue }
                    seen.insert(path)
                    if record(path, session: session, root: root, at: stamp) { added += 1 }
                }
            }
        }
        return added
    }

    /// Paths that are never artifacts, wherever they were seen: render probes
    /// in a session scratchpad (wiped, and a probe by definition), anything in
    /// the system temp trees, and the harness's own library (~/.claude skills,
    /// templates, plugins — editing a template fired the hook and put the
    /// blank template on a hub as "page.html"; measured 15 Aug). One choke
    /// point, applied on write AND on read, so logs that already carry these
    /// heal without a rewrite.
    /// Is this page this agent's?
    ///
    /// ONE predicate, three callers: the hub's page list, the turn-end pass,
    /// and `tbase doctor`. It was written twice before — Robert, 03 Sep, on the
    /// layers that followed a misfile: "let's collapse the 4th rule". A rule
    /// that decides ownership in more than one place drifts in all but one of
    /// them, which is the failure that produced the misfile in the first place.
    ///
    /// A page with NO stamp belongs to whoever holds it: most of the archive
    /// predates the stamp and must not vanish from its hub.
    public static func belongs(page path: String, to slug: String) -> Bool {
        guard let declared = declaredAgent(of: path) else { return true }
        return declared == slug
    }

    /// The agent a page names in its own head, if it names one.
    ///
    /// Only the head is read — the stamp is written there by the hook and by
    /// the turn-end pass, and a page can be megabytes of embedded font.
    public static func declaredAgent(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192) else { return nil }
        let head = String(decoding: data, as: UTF8.self)
        guard let r = head.range(of: #"<meta\s+name="intranet:session"\s+content="[^"]*""#,
                                 options: .regularExpression),
              let q = head[r].range(of: "content=\"") else { return nil }
        let value = head[q.upperBound...].prefix { $0 != "\"" }
        return value.isEmpty ? nil : String(value)
    }

    static func excluded(_ path: String) -> Bool {
        path.contains("/scratchpad/")
            || path.hasPrefix("/tmp/")
            || path.hasPrefix("/private/tmp/")
            || path.hasPrefix("/var/folders/")
            || path.contains("/.claude/")
            // A HUB IS NOT AN ARTIFACT. It is the index over them, and it is
            // rewritten on every turn, so recording one makes the newest
            // "report" of any session that so much as regenerated a page the
            // hub of some OTHER agent — which is what the card's OPEN REPORT
            // opened on 15 Aug. Hubs are reached by the door and the footer,
            // never by the list.
            // The HUB is not an artifact -- it is the index over them, rewritten
            // every turn, and recording one made the newest "report" of any
            // session that regenerated a page the hub of some OTHER agent
            // (15 Aug). But that was written as "everything under agents/", and
            // the tree is now where reports LIVE: a report at
            // agents/<slug>/<name>.html names its own author in its own path, so
            // excluding the whole directory excluded exactly the pages that need
            // no attribution guess at all. Only index.html is the hub.
            //
            // And only at the TOP of an agent: agents/<slug>/index.html. A brief
            // at agents/<slug>/<date-slug>/index.html is a research report, and
            // matching on the filename alone excluded it along with the hub.
            || (path.contains("/Documents/agents/")
                && (path as NSString).lastPathComponent == "index.html"
                && ((path as NSString).deletingLastPathComponent as NSString)
                    .deletingLastPathComponent.hasSuffix("/Documents/agents"))
    }

    /// The agent a page belongs to, read off its own path.
    ///
    /// `agents/<slug>/<report>.html` needs no heuristic: the directory IS the
    /// session. That is the whole reason to put reports there. Everything else
    /// -- globbing likely directories, reading a transcript tail to see who
    /// named the file, hoping two simultaneous sessions do not both claim it --
    /// exists only because nothing was ever agreed about where pages go, and it
    /// is what put one page on four hubs (16 Aug).
    ///
    /// Returns nil for a path outside the tree, and for the hub itself.
    public static func agentSlug(forPageAt path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard let i = parts.lastIndex(of: "agents"), i + 2 < parts.count,
              parts[i - 1] == "Documents",
              parts[i + 2] != "index.html" || i + 3 < parts.count
        else { return nil }
        let slug = parts[i + 1]
        guard (path as NSString).lastPathComponent != "index.html" else { return nil }
        return slug.isEmpty ? nil : slug
    }

    // MARK: - The faithful rendering
    //
    // EVERY HTML A SESSION WRITES IS A REPORT, AND EVERY REPORT BELONGS ON THE
    // HUB. What the hub may not do is link something that renders unstyled.
    //
    // Those two facts together rule out the obvious fix. Excluding fragments
    // was tried first and is wrong: it answers "this would render badly" by
    // deleting the report, so the work disappears from the page instead of
    // appearing properly. The rule is not "which files do we skip" — there is
    // no list — it is one question asked of every recorded file: what is the
    // faithful rendering of this?
    //
    // A complete document renders as itself. A fragment renders as the finished
    // document it became, which is the `index.html` beside it: share-as-page
    // writes the bare <body> and the built page into the same project folder.
    // Measured over every fragment on this machine — all 16 under Projects/
    // resolve, and the 7 that do not are ClaudeWork build intermediates whose
    // finished form lives in its own folder and is recorded separately.
    //
    // Nothing here keys on a NAME, which is the point: the pipeline produced
    // four naming shapes in two days (body.html, body.snippet.html,
    // x.body.html, x-page-body.html) and a pattern written for one of them
    // shipped hours before the next two appeared.
    static func faithfulRendering(of path: String) -> String? {
        guard isBodyFragment(path) else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        // THE BUILT PAGE WITH THE SAME NAME, first.
        //
        // A fragment beside its finished page — mirai-september-import-visual
        // .fragment.html next to mirai-september-import-proof.html — is a build
        // input, and the thing to show is the page. Resolving to "index.html in
        // this folder" is share-as-page's shape and is wrong in an agent's own
        // directory, where index.html is the HUB: the hub would list itself.
        // On 03 Sep the hub linked the fragment and it rendered with no styling
        // at all, which is what Robert opened.
        if let built = builtSibling(of: path) { return built }
        let sibling = (dir as NSString).appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: sibling),
              !isAgentHub(sibling) else { return nil }
        return sibling
    }

    /// `x.fragment.html` -> `x.html`, when that exists and is a whole document.
    static func builtSibling(of path: String) -> String? {
        let ns = path as NSString
        var stem = ns.lastPathComponent
        guard stem.hasSuffix(".html") else { return nil }
        stem = String(stem.dropLast(5))
        for suffix in [".fragment", ".body", "-body", ".snippet"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            let candidate = (ns.deletingLastPathComponent as NSString)
                .appendingPathComponent(stem + ".html")
            // It has to be a whole document. `body.snippet.html` next to
            // `body.html` strips to another fragment, and swapping one build
            // input for another shows the reader the same unstyled page.
            guard FileManager.default.fileExists(atPath: candidate),
                  !isBodyFragment(candidate), isWholeDocument(candidate) else { return nil }
            return candidate
        }
        return nil
    }

    /// Does this file open like a page a browser will style?
    static func isWholeDocument(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512) else { return false }
        return String(decoding: data, as: UTF8.self)
            .range(of: "<!doctype|<html", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// agents/<slug>/index.html — the index over the pages, never one of them.
    static func isAgentHub(_ path: String) -> Bool {
        let ns = path as NSString
        guard ns.lastPathComponent == "index.html" else { return false }
        let parent = (ns.deletingLastPathComponent as NSString).deletingLastPathComponent
        return parent == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/agents").path
    }

    /// Is this file a build INPUT rather than something to show?
    ///
    /// Kept as a classifier, no longer as grounds for exclusion. A body fragment
    /// carries no doctype — that is the property a rename cannot change — but
    /// this side runs over records whose file may already be gone, so it reads
    /// the path. The hook tests the bytes; a name is the fallback, never the
    /// authority.
    static func isBodyFragment(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "body.html"
            || name.hasSuffix(".body.html")
            || name.hasSuffix("-body.html")
            || name.hasSuffix(".snippet.html")
            // Added 03 Sep: a `.fragment.html` was not on this list, so the hub
            // linked one and served a page with no styling.
            || name.hasSuffix(".fragment.html")
            || path.contains("-page-sources/")
    }

    /// Does this shell command WRITE a file, or merely mention one?
    ///
    /// The first version of the Bash miner asked only whether a command
    /// contained an .html path, so `grep`, `open`, and `ls` all filed pages as
    /// this session's work — including other agents' hubs, which is how the
    /// card's OPEN REPORT came to open a stranger's page (15 Aug). Reading is
    /// not authorship. This is a coarse allowlist of the ways a page is
    /// actually made in a shell; anything it misses is caught the moment a
    /// real file tool touches the page.
    /// A shell REDIRECT, not any greater-than sign.
    ///
    /// Testing for a bare ">" called every command containing an HTML-stripping
    /// regex a write — `re.sub(r'<[^>]+>', ...)` carries two — so three pages
    /// this session only read came back onto its hub minutes after being
    /// pruned (measured 16 Aug). A redirect's ">" follows whitespace (or a
    /// single fd digit after whitespace) and points at a destination, never at
    /// "&", which is a dup of an existing descriptor rather than a file.
    static func containsRedirect(_ command: String) -> Bool {
        let chars = Array(command)
        for (i, c) in chars.enumerated() where c == ">" {
            var before = i - 1
            if before >= 0, chars[before].isNumber { before -= 1 }   // 2> file
            let precededBySpace = before < 0 || chars[before].isWhitespace
                || chars[before] == ">"                              // >> append
            guard precededBySpace else { continue }
            let next = chars[(i + 1)...].drop(while: { $0 == ">" })
                .drop(while: { $0 == " " }).first
            if let next, next != "&" { return true }
        }
        return false
    }

    static func writesAFile(_ command: String) -> Bool {
        if containsRedirect(command) { return true }
        for verb in ["cp ", "mv ", "tee ", "install ", "rsync ", "curl -o",
                     "wget ", "sed -i"] {
            if command.contains(verb) { return true }
        }
        // Interpreters are deliberately absent. `python3 -c "open(page).read()"`
        // is a read, and admitting the interpreter filed three of another
        // agent's pages as this session's work (15 Aug). A script that really
        // writes almost always redirects or copies as well.
        return false
    }

    /// Absolute .html paths inside a shell command. Deliberately dumb: split on
    /// the characters that end a path in shell text, keep what parses as an
    /// absolute path to an .html file. Quoting and expansion games can hide a
    /// path from this; the transcript is mined best-effort, and a missed page
    /// surfaces the moment anything touches it through a real file tool.
    /// The pages a shell command WRITES: redirect targets, and the final
    /// argument of a copying verb. Nothing else.
    ///
    /// The previous rule took every .html path anywhere in a command that
    /// wrote anything, which is how a `grep -v '…agent-hub-design…' log > log`
    /// filed the very page it was pruning (measured 16 Aug — the prune
    /// command re-added its own argument). A path inside a pattern, a flag, or
    /// a grep is not authorship; only the destination is.
    static func htmlPaths(in command: String) -> [String] {
        // Shell text spells home three ways; the transcript keeps whichever
        // the session typed. All three normalize to the absolute form before
        // the prefix test, because "~/Documents/…" is exactly how the
        // measured miss (15 Aug) wrote its post-mortem.
        let home = NSHomeDirectory()
        func normalize(_ raw: String) -> String? {
            var t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;|&)("))
            if t.hasPrefix("~/") { t = home + t.dropFirst(1) }
            if t.hasPrefix("$HOME/") { t = home + t.dropFirst(5) }
            guard t.hasPrefix("/"), t.hasSuffix(".html") else { return nil }
            return t
        }

        var out: [String] = []
        func add(_ raw: String) {
            if let path = normalize(raw), !out.contains(path) { out.append(path) }
        }

        // Redirect targets: "> page", ">>page", "2> page". The operator may be
        // glued to its destination, which is why the tail is inspected too.
        let tokens = command.split(whereSeparator: { " \t\n".contains($0) }).map(String.init)
        for (i, token) in tokens.enumerated() {
            guard let opRange = token.range(of: ">", options: .backwards) else { continue }
            let head = String(token[..<opRange.lowerBound])
            // Skip a regex or an arrow: a redirect's operator is the token's
            // own tail, optionally behind one file-descriptor digit.
            guard head.isEmpty || head.allSatisfy({ $0 == ">" || $0.isNumber }) else { continue }
            let tail = String(token[opRange.upperBound...])
            if tail.isEmpty {
                if i + 1 < tokens.count { add(tokens[i + 1]) }
            } else if tail != "&1", tail != "&2" {
                add(tail)
            }
        }

        // Copying verbs write their LAST argument, and only that one.
        for verb in ["cp", "mv", "tee", "install", "rsync"] {
            guard let start = tokens.firstIndex(of: verb) else { continue }
            let segment = tokens[(start + 1)...].prefix { !$0.contains("&&") && !$0.contains(";") }
            if let destination = segment.last { add(destination) }
        }
        return out
    }

    /// Transcript stamps are UTC. Parsing them as local time put every page
    /// seven hours into the future during the prototype, which silently emptied
    /// the list it was meant to fill.
    private static func iso8601(_ text: String) -> Date? {
        RolloutClock.date(text)
    }
}

public extension ArtifactStore {

    /// What a page is actually called, and what it is about.
    ///
    /// A directory slug — "vd-grid-mock" — is a filename, not a title. The page
    /// itself has said what it is all along, in the same places every reader
    /// tool looks. The precedence below is Mozilla Readability's, trimmed to
    /// what a local file can offer: `og:title`, then `<title>` with any trailing
    /// " — Site" segment removed, then the first `<h1>`.
    ///
    /// Readability's most useful move is its fallback CONDITION rather than its
    /// order: a title under 15 or over 150 characters is treated as unusable and
    /// the `<h1>` is preferred instead. That single rule is what rescues pages
    /// whose title is a bare slug or an entire sentence.
    struct DocumentSummary: Sendable, Equatable {
        public let title: String?
        /// The opening line, for a hover card. Wikipedia's Page Previews show
        /// the first non-empty paragraph and clip it visually rather than at a
        /// character count; this keeps the text short enough that clipping is
        /// rarely needed.
        public let blurb: String?
        /// The subjects the page declares, from `<meta name="intranet:tags">`.
        /// Lowercased and de-duplicated; empty when the page never declared any.
        ///
        /// These are the only durable index this archive has. A title says what
        /// one page is called; a tag says what it is ABOUT, which is the
        /// question asked by somebody who remembers the subject and not the day
        /// — the whole reason the hub stopped being a list sorted by date.
        public let tags: [String]

        public init(title: String?, blurb: String?, tags: [String] = []) {
            self.title = title; self.blurb = blurb; self.tags = tags
        }
    }

    /// Only the head and the opening of the body are read — a rendered page can
    /// be a megabyte of inlined CSS, and the answer is always near the top.
    static func summarize(path: String, limit: Int = 24_000) -> DocumentSummary {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return DocumentSummary(title: nil, blurb: nil)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        // Lossy on purpose: a page with one bad byte still has a title, and
        // refusing the whole document over it is how pages went untitled.
        let html = String(decoding: data, as: UTF8.self)
        let og = firstMatch(in: html,
            #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#)
        let titleTag = firstMatch(in: html, #"(?s)<title[^>]*>(.*?)</title>"#)
            .map(trimSiteSuffix)
        let heading = firstMatch(in: html, #"(?s)<h1[^>]*>(.*?)</h1>"#).map(stripTags)
        // The headline the reader sees is the page's real name, so it wins
        // whenever it is specific enough to be one. A `<title>` is written for
        // a browser tab and carries site furniture; an `<h1>` is written for
        // the page. Falling back the other way produced a hub listing three
        // different documents as "Tranquility Base".
        let candidate = og ?? titleTag
        let title: String?
        if let heading, heading.count >= 15, heading.count <= 150 {
            title = heading
        } else if let candidate, candidate.count >= 15, candidate.count <= 150 {
            title = candidate
        } else {
            title = heading ?? candidate
        }
        // The page's OWN sentence about itself outranks anything derived. A
        // first paragraph is whatever the layout put first — a dateline, a
        // nav link, a pull quote — and it read as the summary on hubs for
        // weeks. `intranet:summary` is written to be this and nothing else.
        let declared = meta(html, "intranet:summary")
        let description = meta(html, "description")
        let paragraph = firstMatch(in: html, #"(?s)<p[^>]*>(.*?)</p>"#).map(stripTags)
        let blurb = (declared ?? description ?? paragraph).map { text -> String in
            text.count > 220 ? String(text.prefix(217)) + "…" : text
        }
        return DocumentSummary(title: title?.isEmpty == false ? title : nil,
                               blurb: blurb?.isEmpty == false ? blurb : nil,
                               tags: tags(html))
    }

    /// Is this page one the ARCHIVE generated, rather than one an agent wrote?
    ///
    /// The publisher stamps its own indexes on the first line
    /// (`<!-- research-hq-generated: index -->`), so this is a fact read off
    /// the file rather than a guess made from its path. It matters because a
    /// session that merely REBUILDS the index has a record for it, and the hub
    /// of hubs then appears on that agent's own hub as something it made —
    /// which is exactly the misattribution the archive keeps being fixed for.
    ///
    /// Only the head is read: the marker is on line one by construction, and a
    /// page that puts it anywhere else is not one of ours.
    public static func isGeneratedIndex(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 256)) ?? Data(), as: UTF8.self)
        return head.contains("research-hq-generated: index")
            || head.contains("intranet-generated: index")
    }

    /// One `<meta name="…" content="…">` value, in either attribute order.
    ///
    /// Both orders occur in this archive — hand-written pages put `name`
    /// first, pandoc puts `content` first — and a pattern that only knew one
    /// of them silently returned nothing for a third of the pages.
    static func meta(_ html: String, _ name: String) -> String? {
        let n = NSRegularExpression.escapedPattern(for: name)
        return firstMatch(in: html,
            #"<meta[^>]+name=["']"# + n + #"["'][^>]*?content=["']([^"']*)["']"#)
            ?? firstMatch(in: html,
                #"<meta[^>]+content=["']([^"']*)["'][^>]*?name=["']"# + n + #"["']"#)
    }

    /// The subjects a page declares, normalised the way the archive stores
    /// them: lowercase, trimmed, comma-separated, first occurrence wins.
    static func tags(_ html: String) -> [String] {
        guard let raw = meta(html, "intranet:tags") else { return [] }
        var seen: Set<String> = [], out: [String] = []
        for part in raw.split(separator: ",") {
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !tag.isEmpty, tag.count <= 40, seen.insert(tag).inserted else { continue }
            out.append(tag)
        }
        return out
    }

    /// "Plan — Tranquility Base" is one title with a site name stapled on. The
    /// separators are Readability's list.
    /// Drop the site name from a `<title>`, whichever END it sits on.
    ///
    /// The old rule always kept the HEAD, which is correct for "Page — Site"
    /// and exactly backwards for "Site — Page" — the convention this house
    /// actually writes. Four pages on one hub read "Tranquility Base",
    /// "Tranquility Base", "Tranquility Base" because the brand won every
    /// time (measured 15 Aug). Keep the more specific side instead: the
    /// longer segment, which is the one carrying the page's own subject.
    private static func trimSiteSuffix(_ text: String) -> String {
        let cleaned = stripTags(text)
        for separator in [" — ", " – ", " | ", " · ", " \\ ", " / ", " » ", " > "] {
            guard let range = cleaned.range(of: separator, options: .backwards)
            else { continue }
            let head = String(cleaned[..<range.lowerBound])
            let tail = String(cleaned[range.upperBound...])
            let keep = tail.count > head.count ? tail : head
            // Only when what remains is still a title rather than a word.
            if keep.count >= 15 { return keep }
        }
        return cleaned
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&middot;", with: "·")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(in text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
