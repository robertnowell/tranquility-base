import Foundation

/// Everything in an agent's own directory, made whole at turn end.
///
/// THE PROBLEM THIS REPLACES. A page is written and the hook has to work out
/// WHICH file that was, because the payload usually does not say: measured
/// 02 Sep across the 25 most recent transcripts, 225 pages were written by a
/// shell heredoc against 38 by the Write tool, and Codex is 100% of the first
/// group by construction — its only tool is `exec`. So the hook globs, filters
/// by mtime, and picks. Every footer failure this archive has had is that guess
/// going wrong in a new way: one page claimed by four hubs (16 Aug), pages
/// recorded nowhere (21 Aug), Codex pages unstamped (01 Sep), the archive's own
/// index recorded as an agent's work (02 Sep), a report resolved to the hub
/// beside it (02 Sep). Fourteen of 182 pages on disk had never been recorded at
/// all.
///
/// WHY THIS IS NOT A GUESS. A page at `agents/<slug>/<name>.html` states its
/// author in its own path. The hub is rewritten at every turn end by the thing
/// that knows the session, and it reads that directory anyway. Ownership is
/// read, not inferred; there is no recency contest to lose and no way to pick
/// the wrong agent.
///
/// The hook keeps doing its job — it stamps immediately, which is what makes a
/// page complete the moment it is written. It stops being the only chance.
public enum HubReconcile {

    /// What a reconciliation did, so a caller can log it and a test can assert it.
    public struct Result: Sendable, Equatable {
        public var recorded = 0
        public var footers = 0
        public var sessions = 0
        public var scanned = 0
        /// Pages in this directory that name a different agent — misfiles,
        /// left where they are rather than claimed.
        public var foreign = 0
    }

    /// Bring every page in `dir` up to the contract: recorded, attributed,
    /// footed. Never throws — a hub write must not fail over a provenance field.
    @discardableResult
    public static func run(sessionId: String,
                           title: String?,
                           dir: URL,
                           turns: [HomeBase.Turn] = [],
                           root: String = QueueStore.supportDirectory.path,
                           now: Date = Date()) -> Result {
        var result = Result()
        let short = String(sessionId.prefix(8))
        guard ArtifactStore.isPlausibleSession(sessionId) else { return result }
        // BOTH LEVELS, like the hook's own glob. A page sits at
        // agents/<slug>/<name>.html; a research report sits at
        // agents/<slug>/<date-slug>/index.html, which is the canonical layout
        // and where 452 of them live. The hub itself — index.html at the top
        // level — is the index over these and never one of them.
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var files = entries.filter {
            $0.pathExtension.lowercased() == "html" && $0.lastPathComponent != "index.html"
        }
        for sub in entries where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory == true {
            let report = sub.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: report.path) { files.append(report) }
        }
        guard !files.isEmpty else { return result }

        let known = Set(ArtifactStore.history(for: sessionId, root: root).map(\.path))
        for file in files.sorted(by: { $0.path < $1.path }) {
            result.scanned += 1
            let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now

            // 0. SOMEBODY ELSE'S PAGE, sitting in this directory.
            //
            //    A page that already names a different agent was written by
            //    that agent into the wrong place (02 Sep: 95d165f8 put two of
            //    its reports in 4394c0ec's directory). Claiming it here would
            //    do exactly what the old path rule did — assert the wrong
            //    author, and put the page on two hubs. It is left alone and
            //    reported by `tbase doctor` instead.
            if !ArtifactStore.belongs(page: file.path, to: short) {
                result.foreign += 1
                continue
            }

            // 1. The record. Keyed by the SLUG, because that is what the path
            //    carries and what `history` reads back for a hub.
            if !known.contains(ArtifactStore.canonical(file.path)),
               ArtifactStore.record(file.path, session: short, root: root, at: at) {
                result.recorded += 1
            }

            // 2. The stamps. Each one is declared-beats-inferred and preserves
            //    the file's mtime, for the reason the artifact hook does: a
            //    refreshed mtime makes a page look just-written to the next hook
            //    run, which re-attributes it to whichever session last ran a
            //    shell command (16 Aug).
            guard var html = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let original = html
            if html.range(of: #"<meta\s+name="intranet:session""#,
                          options: .regularExpression) == nil {
                html = insertInHead("<meta name=\"intranet:session\" content=\"\(short)\">",
                                    into: html)
                result.sessions += 1
            }
            if html.range(of: "data-tb-agent") == nil {
                html = appendFooter(to: html, session: sessionId, short: short,
                                    title: title, path: file.path, now: now)
                result.footers += 1
            }
            if html != original { write(html, to: file) }

            // 3. The turn, through the one rule that decides ownership.
            if let owner = HomeBase.turnOwner(of: at, in: turns),
               owner < HomeBase.fullTurns + HomeBase.lineTurns {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                HomeBase.stamp(page: file, turn: iso.string(from: turns[owner].at))
            }
        }
        return result
    }

    /// The agent a page says wrote it, if it says.
    public static func declaredSession(in file: URL) -> String? {
        guard let html = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return declaredSession(inHTML: html)
    }

    static func declaredSession(inHTML html: String) -> String? {
        guard let r = html.range(of: #"<meta\s+name="intranet:session"\s+content="[^"]*""#,
                                 options: .regularExpression),
              let q = html[r].range(of: "content=\"")
        else { return nil }
        let value = html[q.upperBound...].prefix { $0 != "\"" }
        return value.isEmpty ? nil : String(value)
    }

    // MARK: - The page's own furniture

    /// THE FOOTER MARKUP LIVES IN TWO PLACES and that is a known cost, recorded
    /// here rather than discovered later. `hooks/artifact-hook.sh` carries its
    /// own copy because a hook must be standalone: it runs inside a real turn,
    /// must never fail, and cannot depend on a Swift binary being on PATH — the
    /// exact assumption that left an invoicing cron never having run once.
    ///
    /// The contract, not the styling, is what has to match: `data-tb-agent`
    /// marks the block as ours, "Open hub" reaches the agent's page list, and
    /// the discuss link carries the FULL session id (a slug there is what made
    /// the link dead on 107 pages — issue #251). A test pins those three.
    static func appendFooter(to html: String, session: String, short: String,
                             title: String?, path: String, now: Date) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "dd MMM yyyy"
        let day = stamp.string(from: now)
        let who = (title?.isEmpty == false)
            ? "Created by <b>\(escape(title!))</b> &middot; session \(short) &middot; \(day)"
            : "Created by session \(short) &middot; \(day)"
        let hub = NSString(string: "~/Documents/agents/\(short)/index.html").expandingTildeInPath
        let footer = """
        <footer data-tb-agent="\(short)" style="box-sizing:border-box;\
        max-width:860px;margin:64px auto 0;padding:20px 0 0;\
        border-top:1px solid rgba(128,128,128,.42);\
        font:12.5px/1.5 ui-monospace,Menlo,monospace;color:inherit;\
        display:flex;flex-wrap:wrap;gap:10px;align-items:center">
          <div style="flex:1;min-width:220px">\(who)</div>
          <a href="file://\(hub)" \
        style="text-decoration:none;color:inherit;border:1px solid rgba(128,128,128,.5);\
        padding:7px 13px;border-radius:7px;font-weight:640">Open hub</a>
          <a href="tranquilitybase://discuss?session=\(session)&amp;ref=\(path)" \
        style="text-decoration:none;background:#1f4f8f;color:#fbfaf8;padding:8px 14px;\
        border-radius:7px;font-weight:640">Discuss with agent</a>
        </footer>
        """
        if let body = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            return html.replacingCharacters(in: body, with: footer + "\n</body>")
        }
        return html + "\n" + footer + "\n"
    }

    static func insertInHead(_ tag: String, into html: String) -> String {
        if let head = html.range(of: "<head", options: .caseInsensitive),
           let close = html.range(of: ">", range: head.upperBound..<html.endIndex) {
            return html.replacingCharacters(in: close, with: ">\n" + tag)
        }
        if let title = html.range(of: "</title>", options: .caseInsensitive) {
            return html.replacingCharacters(in: title, with: "</title>\n" + tag)
        }
        return tag + "\n" + html
    }

    static func write(_ html: String, to file: URL) {
        let before = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard (try? html.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        if let mtime = before?[.modificationDate] as? Date {
            try? FileManager.default.setAttributes([.modificationDate: mtime],
                                                   ofItemAtPath: file.path)
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
