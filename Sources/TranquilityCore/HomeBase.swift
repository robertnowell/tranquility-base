import Foundation

/// One page per agent: what it is doing, where it stands, and everything it has
/// made — the address an artifact is a child of.
///
/// It exists because the footer solves correlation from one end only. A page
/// carries a link back to its agent, which works for the pages that got a
/// footer — a judgment call, made per file, that will sometimes say no. The
/// home base solves it from the other end and needs no judgment at all: the
/// agent has an address, and a missing footer stops mattering.
///
/// **Nothing here is narrated.** The obvious design is to remind the agent each
/// turn to append its own key updates, and it is wrong twice: it spends context
/// on every turn to restate what was just said, and it puts the page's accuracy
/// at the mercy of the thing being described. Every turn ALREADY produces a
/// brief — topic, what happened, what is next, the open question — generated
/// for the voice and stored in `brief`, whose schema was written to be the
/// retention layer's seed. So the page is a projection of a table that fills
/// itself, and it is complete the moment the turn ends.
///
/// **Length is a hard constraint, not a preference.** A session log that grows
/// without bound is a log; this has to stay a briefing you can read in a
/// sitting. So: newest first, one block per turn, and a cap. What falls off the
/// end is not lost — it is in the transcript, which is what the deep link is
/// for.
public enum HomeBase {

    public struct Turn: Sendable {
        public let at: Date
        public let topic: String
        public let happened: String
        public let nextStep: String?
        public let question: String?
        public let risk: String?

        public init(at: Date, topic: String, happened: String,
                    nextStep: String? = nil, question: String? = nil,
                    risk: String? = nil) {
            self.at = at; self.topic = topic; self.happened = happened
            self.nextStep = nextStep; self.question = question; self.risk = risk
        }
    }

    public struct Model: Sendable {
        public let sessionId: String
        /// What Claude Code calls this conversation — the tab, and the grid row.
        public let title: String?
        /// What Tranquility Base calls it out loud. A different thing, always.
        public let callsign: String?
        public let cwd: String?
        /// What the session set out to do, from its earliest brief rather than
        /// its latest — the goal is the one field that must not drift with the
        /// work.
        public let goal: String?
        public let turns: [Turn]
        public let artifact: String?

        public init(sessionId: String, title: String?, callsign: String?,
                    cwd: String?, goal: String?, turns: [Turn], artifact: String?) {
            self.sessionId = sessionId; self.title = title; self.callsign = callsign
            self.cwd = cwd; self.goal = goal; self.turns = turns
            self.artifact = artifact
        }
    }

    /// Turns kept on the page. Twenty briefs of ~40 words is roughly 1,500
    /// words — a fifteen-minute read with room for the header, and about a
    /// twentieth of Common Sense.
    public static let turnLimit = 20

    public static func slug(for model: Model) -> String {
        let name = model.callsign ?? model.title ?? "session"
        let words = name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(4)
            .joined(separator: "-")
        let short = model.sessionId.split(separator: "-").first.map(String.init)
            ?? model.sessionId
        return words.isEmpty ? short : "\(words)-\(short)"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    public static func render(_ model: Model, now: Date = Date()) -> String {
        let e = escape
        let name = model.title ?? model.callsign ?? "Session \(model.sessionId.prefix(8))"
        let shown = model.turns.prefix(turnLimit)
        let dropped = max(0, model.turns.count - shown.count)

        var rows = ""
        for turn in shown {
            var detail = "<p class=\"h\">\(e(turn.happened))</p>"
            if let next = turn.nextStep, !next.isEmpty {
                detail += "<p class=\"n\"><span>next</span> \(e(next))</p>"
            }
            if let question = turn.question, !question.isEmpty {
                detail += "<p class=\"q\"><span>asked</span> \(e(question))</p>"
            }
            if let risk = turn.risk, !risk.isEmpty {
                detail += "<p class=\"r\"><span>risk</span> \(e(risk))</p>"
            }
            rows += """
                <li><div class="when">\(e(stamp.string(from: turn.at)))</div>
                <div class="what"><h3>\(e(turn.topic))</h3>\(detail)</div></li>

                """
        }
        if shown.isEmpty {
            rows = "<li><div class=\"when\">—</div><div class=\"what\">"
                + "<p class=\"h\">Nothing summarized yet. This page fills in as the "
                + "agent finishes turns.</p></div></li>"
        }

        let artifactBlock = model.artifact.map { path in
            """
            <a class="page" href="file://\(e(path))">\(e((path as NSString).lastPathComponent))</a>
            <span class="dim">most recent page</span>
            """
        } ?? "<span class=\"dim\">no pages yet</span>"

        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(e(name)) — agent home base</title>
        <meta name="intranet:type" content="session">
        <meta name="intranet:visibility" content="local">
        <style>
          :root { --bg:#fbfaf8; --fg:#16150f; --dim:#6b675c; --faint:#a29c8d;
                  --accent:#1f4f8f; --rule:#ddd8cc; --card:#f2efe8; }
          @media (prefers-color-scheme: dark) {
            :root { --bg:#131310; --fg:#eceae2; --dim:#8f8a7c; --faint:#6a6558;
                    --accent:#7fb0e8; --rule:#2e2c26; --card:#1e1d19; }
          }
          *{box-sizing:border-box} html{background:var(--bg)}
          body{margin:0;background:var(--bg);color:var(--fg);
               font:16px/1.6 ui-sans-serif,-apple-system,sans-serif;
               -webkit-font-smoothing:antialiased}
          .wrap{max-width:760px;margin:0 auto;padding:64px 26px 48px}
          .eyebrow{font:600 11.5px/1 ui-monospace,Menlo,monospace;letter-spacing:.14em;
                   text-transform:uppercase;color:var(--faint);margin:0 0 14px}
          h1{font-size:31px;line-height:1.15;letter-spacing:-.02em;margin:0 0 10px;font-weight:640}
          .goal{font-size:17.5px;color:var(--dim);margin:0 0 4px;max-width:62ch}
          .meta{margin:26px 0 0;display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));
                gap:1px;background:var(--rule);border:1px solid var(--rule);border-radius:10px;
                overflow:hidden}
          .meta div{background:var(--bg);padding:12px 14px;
                    font:12.5px/1.45 ui-monospace,Menlo,monospace;color:var(--dim)}
          .meta b{display:block;color:var(--fg);font-weight:600;font-size:13px;
                  margin-bottom:2px;word-break:break-word}
          .doors{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin:22px 0 0;
                 font:12.5px/1 ui-monospace,Menlo,monospace}
          .doors a{text-decoration:none;color:var(--bg);background:var(--accent);
                   padding:9px 15px;border-radius:7px;font-weight:640;letter-spacing:.04em}
          .doors a.page{background:transparent;color:var(--accent);
                        border:1px solid currentColor}
          .doors .dim{color:var(--faint)}
          h2{font:600 11.5px/1 ui-monospace,Menlo,monospace;letter-spacing:.14em;
             text-transform:uppercase;color:var(--accent);margin:52px 0 4px}
          .sub{color:var(--faint);font-size:13.5px;margin:0 0 8px}
          ol{list-style:none;padding:0;margin:14px 0 0}
          ol li{display:flex;gap:18px;padding:16px 0;border-top:1px solid var(--rule)}
          .when{flex:0 0 96px;font:12px/1.7 ui-monospace,Menlo,monospace;color:var(--faint)}
          .what{flex:1;min-width:0}
          .what h3{margin:0 0 5px;font-size:15.5px;letter-spacing:-.01em}
          .what p{margin:0 0 5px;font-size:14.5px}
          .what .h{color:var(--fg)}
          .what .n,.what .q,.what .r{color:var(--dim);font-size:13.5px}
          .what span{font:600 10.5px/1 ui-monospace,Menlo,monospace;letter-spacing:.1em;
                     text-transform:uppercase;color:var(--faint);margin-right:6px}
          footer{margin-top:56px;padding-top:18px;border-top:1px solid var(--rule);
                 font:12.5px/1.5 ui-monospace,Menlo,monospace;color:var(--faint)}
        </style></head><body><div class="wrap">

        <p class="eyebrow">Agent home base</p>
        <h1>\(e(name))</h1>
        \(model.goal.map { "<p class=\"goal\">\(e($0))</p>" } ?? "")

        <div class="meta">
          <div><b>\(e(model.callsign ?? "—"))</b>callsign</div>
          <div><b>\(e(model.sessionId.prefix(8).description))</b>session</div>
          <div><b>\(e((model.cwd as NSString?)?.lastPathComponent ?? "—"))</b>directory</div>
          <div><b>\(shown.count)\(dropped > 0 ? " of \(model.turns.count)" : "")</b>turns summarized</div>
        </div>

        <div class="doors">
          <a href="tranquilitybase://discuss?session=\(e(model.sessionId))">Discuss with agent</a>
          \(artifactBlock)
        </div>

        <h2>What has happened</h2>
        <p class="sub">Newest first, one block per finished turn.\(dropped > 0 ? " Older turns (\(dropped)) are in the transcript." : "")</p>
        <ol>
        \(rows)</ol>

        <footer>
          \(e(model.title ?? "—")) &middot; callsign \(e(model.callsign ?? "—"))
          &middot; session \(e(model.sessionId))<br>
          Generated by Tranquility Base, \(e(stamp.string(from: now)))
        </footer>
        </div></body></html>
        """
    }
}

public extension HomeBase {
    /// Where the pages live. Outside the app's support directory on purpose:
    /// these are for reading and browsing, and a folder nobody can find in
    /// Finder is a folder nobody reads.
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/agents", isDirectory: true)
    }
}

public extension HomeBase {
    /// Assemble and write one session's page. Shared by the CLI and the app so
    /// the two cannot drift — a page generated by hand and a page generated
    /// after a turn have to be the same page.
    ///
    /// Returns nil when the session has no briefs yet: a page whose whole
    /// content is "nothing summarized yet" is a file to clean up later, not a
    /// home base.
    @discardableResult
    static func write(sessionId: String, store: QueueStore,
                      live: [LiveSession] = []) throws -> URL? {
        let briefs = try store.briefs(for: sessionId)
        guard !briefs.isEmpty else { return nil }
        let latest = try store.latestStop(for: sessionId)
        let here = live.first { $0.sessionId == sessionId }
        let title = (latest?.transcriptPath).flatMap {
            TranscriptTitles.shared.latestTitle(transcriptPath: $0)
        }
        let model = Model(
            sessionId: sessionId,
            title: title,
            callsign: briefs.first?.callsign ?? latest?.callsign,
            cwd: latest?.cwd ?? here?.cwd,
            goal: briefs.last?.goal,
            turns: briefs.map {
                Turn(at: Date(timeIntervalSince1970: Double($0.atMs) / 1000),
                     topic: $0.topic, happened: $0.happened,
                     nextStep: $0.nextStep, question: $0.question, risk: $0.risk)
            },
            artifact: ArtifactStore.latest(for: sessionId,
                                           root: QueueStore.supportDirectory.path))
        let dir = root.appendingPathComponent(slug(for: model))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.html")
        try render(model).write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
