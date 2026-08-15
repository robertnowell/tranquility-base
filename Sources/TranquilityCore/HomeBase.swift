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
/// **Caps are the instrument voice, and this page is prose.** The panel's
/// letterspaced small caps mark placards and controls — AGENTS, NEW AGENT,
/// GO TO AGENT — and ui-pass-7 rules on exactly why: caps at 10.5/+1.3 "matches
/// the grid's placard voice… so the button reads as an instrument control
/// rather than prose". That convention works there because it is sparse and
/// because everything wearing it is a control. Applied to a document's section
/// headings it says the opposite of what it means, and applied four times a
/// screen it stops marking anything at all — the page below the fold turns into
/// a wall of small caps with no hierarchy left to read.
///
/// So on this page caps survive in exactly two places, both of them real
/// labels: the eyebrow, and the field tags on a turn (next / asked / risk).
/// Structure is carried by type — size, weight, and the serif — never by case.
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
        /// When this agent last moved. The byline's "as of", and the only
        /// timestamp the top of the page carries.
        public let lastActive: Date?
        /// Everything this agent has made. The hub summarises; these hold the
        /// detail, and a count without them is a dead end — a reader who cannot
        /// act on a label stops following the trail.
        public let pages: [ArtifactStore.Page]

        public init(sessionId: String, title: String?, callsign: String?,
                    cwd: String?, goal: String?, turns: [Turn],
                    pages: [ArtifactStore.Page], lastActive: Date? = nil) {
            self.sessionId = sessionId; self.title = title; self.callsign = callsign
            self.cwd = cwd; self.goal = goal; self.turns = turns
            self.pages = pages; self.lastActive = lastActive ?? turns.first?.at
        }
    }

    /// Resolution tiers, in turns back from the newest — the knob the height
    /// budget actually turns. Borrowed from time-series downsampling rather
    /// than from any rule about prose: recent turns keep full resolution, older
    /// ones lose detail, and the tail becomes one digest. Nothing is deleted,
    /// because the detail never lived here — it is in the pages and the
    /// transcript.
    ///
    /// Measured on a real 71-turn agent: 4/6 put the page at 3,540px of a
    /// 4,000px budget with an editorial header, so the header is paid for by
    /// dropping one full turn.
    public static let fullTurns = 3
    public static let lineTurns = 6

    /// The directory name, and therefore the URL.
    ///
    /// Keyed on the agent's id ALONE, deliberately. The obvious version put the
    /// callsign in front — readable, and wrong: a callsign is minted at the
    /// agent's first summary, so a hub written before that gets one name and
    /// every hub after it gets another, and every link into the first one rots.
    /// "After the creation date, putting any information in the name is asking
    /// for trouble one way or another" (Berners-Lee). The name goes ON the page,
    /// where it can change freely.
    public static func slug(for model: Model) -> String {
        slug(forSessionId: model.sessionId)
    }

    public static func slug(forSessionId id: String) -> String {
        id.split(separator: "-").first.map(String.init) ?? id
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

    static let dayStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()

    public static func render(_ model: Model, now: Date = Date()) -> String {
        let e = escape
        let name = model.title ?? model.callsign ?? "Agent \(model.sessionId.prefix(8))"
        let newest = model.turns.first          // turns arrive newest-first
        let ordered = model.turns

        // ---- the top of the page --------------------------------------------
        // What sits here is decided by subtraction. The eyebrow is gone: a
        // tracked uppercase label above a headline borrows editorial authority
        // it has not earned, and Butterick bounds caps to "less than one line"
        // in any case. The metadata strip is gone too — "71 turns · 5 pages" is
        // a dateline in all but name, and the Times abolished that pattern in
        // 2023 after finding readers misread it, replacing it with plain
        // language folded into the byline. Counts live over the things they
        // count, where the list already proves them.
        //
        // What replaces four decorative devices is one free distinction the
        // newspapers have always used: the SERIF carries the story, the SANS
        // carries facts about the story. A reader separates them before reading
        // a word.
        var head = ""
        if let n = newest {
            // The deck joins two sentences the brief stored separately, and a
            // brief's `happened` often arrives without terminal punctuation —
            // joined bare it read "…merged to production Proceed with the
            // review?" (seen 15 Aug). The join supplies the full stop the
            // field is missing; one that already ends a sentence keeps it.
            let sentence = { (s: String) -> String in
                guard let last = s.last, !".!?…".contains(last) else { return s }
                return s + "."
            }
            let deck = n.question.map { "\(e(sentence(n.happened))) \(e($0))" }
                ?? (n.nextStep.map { "\(e(sentence(n.happened))) Proposing: \(e($0))" }
                    ?? e(n.happened))
            var byline = model.callsign.map { "Agent \(e($0))" } ?? "Agent \(e(String(model.sessionId.prefix(8))))"
            if let dir = (model.cwd as NSString?)?.lastPathComponent, !dir.isEmpty {
                byline += ", working in \(e(dir))"
            }
            if let last = model.lastActive {
                byline += " · last moved \(e(stamp.string(from: last)))"
            }
            head = """
                <h1>\(e(n.topic))</h1>
                <p class="deck">\(deck)</p>
                <p class="byline">\(byline)</p>
                """
        }

        // ---- the stack, downsampled by age ----------------------------------
        var rows = ""
        for (i, turn) in ordered.enumerated() {
            var body = "<p class=\"h\">\(e(turn.happened))</p>"
            var cls = "line"
            if i < fullTurns {
                cls = "full"
                if let next = turn.nextStep, !next.isEmpty {
                    body += "<p class=\"m\"><span>next</span> \(e(next))</p>"
                }
                if let q = turn.question, !q.isEmpty {
                    body += "<p class=\"m\"><span>asked</span> \(e(q))</p>"
                }
            } else if i >= fullTurns + lineTurns {
                continue
            }
            // A risk survives downsampling at every tier. An exception flattened
            // into a summary reads as "nothing here" and gets skipped, which is
            // the failure this page exists to prevent.
            if let risk = turn.risk, !risk.isEmpty {
                body += "<p class=\"m risky\"><span>risk</span> \(e(risk))</p>"
            }
            rows += """
                <li class="\(cls)"><div class="when">\(e(stamp.string(from: turn.at)))</div>
                <div class="what"><h3>\(e(turn.topic))</h3>\(body)</div></li>
                """
        }

        // ---- the tail: one digest, every proper noun kept --------------------
        var digest = ""
        let tail = ordered.count > fullTurns + lineTurns
            ? Array(ordered[(fullTurns + lineTurns)...]) : []
        if !tail.isEmpty {
            var topics: [String] = []
            for t in tail where !topics.contains(t.topic) { topics.append(t.topic) }
            let shown = topics.prefix(14).joined(separator: ", ")
            digest = "<div class=\"digest\"><b>Before that — \(tail.count) turns.</b> "
                + e(shown) + (topics.count > 14 ? "…" : ".") + "</div>"
        }

        // ---- what it made: the documents' own titles, not their filenames ----
        var pages = ""
        if !model.pages.isEmpty {
            let items = model.pages.reversed().map { page -> String in
                let summary = ArtifactStore.summarize(path: page.path)
                let name = summary.title ?? page.label
                let blurb = summary.blurb.map {
                    " data-blurb=\"\(e($0))\""
                } ?? ""
                // No stamp survived anywhere (log undated, file unreadable):
                // say nothing. A page dated "31 Dec" of 1969 is worse than an
                // undated one — a wrong fact where a missing one was honest.
                let on = page.at > Date(timeIntervalSince1970: 0)
                    ? "<span class=\"on\">\(e(dayStamp.string(from: page.at)))</span>" : ""
                // A new tab, deliberately: the hub is the reader's index and
                // stays open while its artifacts are visited (ruled 15 Aug).
                return "<li><a class=\"page\" href=\"file://\(e(page.path))\""
                    + " target=\"_blank\" rel=\"noopener\"\(blurb)>"
                    + "\(e(name))</a>\(on)</li>"
            }.joined()
            let count = model.pages.count
            pages = """
                <h2>What it has made</h2>
                <p class="sub">\(count) page\(count == 1 ? "" : "s"). This page summarises; those hold the detail.</p>
                <ul class="pages">\(items)</ul>
                """
        }

        let empty = ordered.isEmpty
            ? "<div class=\"digest\">Nothing summarized yet. This page fills in as the "
              + "agent finishes turns.</div>" : ""

        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(e(name)) — agent</title>
        <meta name="intranet:type" content="agent">
        <meta name="intranet:visibility" content="local">
        <style>
          /* Two families, one job each — the newspaper's own division of labour.
             The serif carries the story; the sans carries facts ABOUT the story
             (byline, dates, tags). A reader tells them apart before reading a
             word, which is one free distinction doing the work four decorative
             ones were doing badly. Colour is the weakest tool in Butterick's
             list — "position, size, font, and sometimes color" — so amber is
             spent in exactly one place: the risk tag. */
          :root{--bg:#fbfaf8;--fg:#16150f;--dim:#5d5a51;--faint:#94908a;--rule:#ddd8cc;
                --amber:#a8762a;--card:#f2efe8;--accent:#1f4f8f;
                --serif:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;
                --sans:ui-sans-serif,-apple-system,'Helvetica Neue',sans-serif}
          @media(prefers-color-scheme:dark){:root{--bg:#131310;--fg:#eceae2;--dim:#a5a196;
                --faint:#6a6558;--rule:#2e2c26;--amber:#d9a441;--card:#1e1d19;--accent:#7fb0e8}}
          *{box-sizing:border-box}html{background:var(--bg)}
          body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--serif);
               font-size:18px;line-height:1.62;-webkit-font-smoothing:antialiased}
          /* 66 characters is Bringhurst's ideal; 45–75 the acceptable band. */
          .wrap{max-width:660px;margin:0 auto;padding:78px 26px 56px}
          h1{font-size:40px;line-height:1.08;letter-spacing:-.02em;font-weight:600;
             margin:0 0 18px;max-width:17ch}
          .deck{font-size:20px;line-height:1.5;color:var(--dim);margin:0 0 22px;max-width:60ch}
          .byline{font-family:var(--sans);font-size:13.5px;line-height:1.5;color:var(--faint);
                  margin:0 0 42px;padding-bottom:22px;border-bottom:1px solid var(--rule)}
          h2{font-size:26px;line-height:1.2;letter-spacing:-.015em;font-weight:600;
             margin:48px 0 6px}
          .sub{font-family:var(--sans);font-size:13px;color:var(--faint);margin:0 0 14px}
          ul.pages{list-style:none;padding:0;margin:0}
          ul.pages li{display:flex;align-items:baseline;gap:14px;padding:12px 0;
                      border-top:1px solid var(--rule)}
          ul.pages .page{color:var(--fg);text-decoration:none;font-size:18px;flex:1;
                         line-height:1.4}
          ul.pages .page:hover{color:var(--accent)}
          ul.pages .on{font-family:var(--sans);font-size:12.5px;color:var(--faint);
                       white-space:nowrap}
          ol{list-style:none;padding:0;margin:0}
          ol li{display:flex;gap:20px;padding:16px 0;border-top:1px solid var(--rule)}
          .when{flex:0 0 84px;font-family:var(--sans);font-size:12.5px;line-height:1.9;
                color:var(--faint)}
          .what{flex:1;min-width:0}
          .what h3{margin:0 0 4px;font-size:20px;font-weight:600;letter-spacing:-.01em}
          .what p{margin:0 0 5px;font-size:16.5px;max-width:60ch}
          .what .m{font-size:15.5px;color:var(--dim)}
          /* The only caps left, and the only amber: a fragment marking a field. */
          .what span{font-family:var(--sans);font-size:11px;font-weight:600;
                     letter-spacing:.06em;text-transform:uppercase;color:var(--faint);
                     margin-right:7px}
          .what .risky span{color:var(--amber)}
          li.line .what h3{font-size:17px}
          li.line .what .h{color:var(--dim);font-size:15.5px}
          .digest{margin-top:18px;padding:16px 18px;background:var(--card);border-radius:10px;
                  font-size:16px;color:var(--dim);max-width:64ch}
          .digest b{color:var(--fg);font-weight:600}
          footer{margin-top:52px;padding-top:20px;border-top:1px solid var(--rule);
                 font-family:var(--sans);font-size:13px;color:var(--faint);
                 display:flex;flex-wrap:wrap;gap:14px;align-items:center}
          footer b{color:var(--dim);font-weight:600}
          footer .discuss{margin-left:auto;text-decoration:none;background:var(--accent);
                          color:var(--bg);padding:8px 14px;border-radius:7px;font-weight:600}
          /* Hover cards, only where hover means something. A tap fires hover and
             activation together, so on touch this whole affordance is absent
             rather than sticky. */
          #card{position:fixed;z-index:9;max-width:340px;padding:13px 15px;background:var(--card);
                border:1px solid var(--rule);border-radius:10px;font-family:var(--sans);
                font-size:13.5px;line-height:1.5;color:var(--dim);
                box-shadow:0 8px 26px rgba(0,0,0,.14);opacity:0;pointer-events:none;
                transition:opacity .2s}
          #card.on{opacity:1;pointer-events:auto}
          @media(hover:none),(pointer:coarse){#card{display:none}}
        </style></head><body><div class="wrap">
        \(head)
        \(pages)
        <h2>What it has done</h2>
        <p class="sub">Newest first. Older turns lose resolution, never their links.</p>
        <ol>\(rows)</ol>
        \(digest)\(empty)
        <footer>Created by <b>\(e(model.title ?? "—"))</b> &middot;
        callsign <b>\(e(model.callsign ?? "—"))</b> &middot; agent \(e(String(model.sessionId.prefix(8))))
        <a class="discuss" href="tranquilitybase://discuss?session=\(e(model.sessionId))">Discuss with agent</a>
        </footer></div>
        <div id="card" role="tooltip"></div>
        <script>
        // WCAG 1.4.13: the card must be dismissible (Escape), hoverable (the
        // pointer can move onto it), and persistent (it does not time out).
        // The 650ms delay is Wikipedia's, and their reason is worth keeping:
        // some readers hover over text while reading, so an instant preview
        // measures as intrusive rather than helpful.
        (function(){
          var card = document.getElementById('card'), timer = null, live = null;
          function hide(){ clearTimeout(timer); card.classList.remove('on'); live = null; }
          function show(a){
            var text = a.getAttribute('data-blurb'); if(!text) return;
            card.textContent = text; card.classList.add('on'); live = a;
            var r = a.getBoundingClientRect();
            var top = r.bottom + 10, left = Math.min(r.left, innerWidth - 360);
            if (top + card.offsetHeight > innerHeight - 12) top = r.top - card.offsetHeight - 10;
            card.style.top = Math.max(12, top) + 'px';
            card.style.left = Math.max(12, left) + 'px';
          }
          document.querySelectorAll('a.page[data-blurb]').forEach(function(a){
            a.addEventListener('mouseenter', function(){
              clearTimeout(timer); timer = setTimeout(function(){ show(a); }, 650);
            });
            a.addEventListener('mouseleave', function(){
              clearTimeout(timer);
              setTimeout(function(){ if(!card.matches(':hover')) hide(); }, 120);
            });
            a.addEventListener('focus', function(){ show(a); });
            a.addEventListener('blur', hide);
          });
          card.addEventListener('mouseleave', hide);
          document.addEventListener('keydown', function(e){ if(e.key === 'Escape') hide(); });
        })();
        </script></body></html>
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

    /// The page already on disk for a session, if any turn ever wrote one.
    /// An existence check and nothing more — cheap enough for the panel to ask
    /// on every render. Writing stays with the store; asking does not need it.
    static func existingPage(sessionId: String) -> String? {
        let path = root.appendingPathComponent(slug(forSessionId: sessionId))
            .appendingPathComponent("index.html").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
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
        // Agents that ran before the hook existed have pages the store never
        // saw. Cheap, idempotent, and only ever adds.
        if let transcript = latest?.transcriptPath {
            ArtifactStore.backfill(session: sessionId, transcriptPath: transcript,
                                   root: QueueStore.supportDirectory.path)
        }
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
            // `briefs(for:)` returns newest first, which is the order the page
            // renders in — the renderer never re-sorts, so a change to that
            // query cannot silently invert the page.
            turns: briefs.map {
                Turn(at: Date(timeIntervalSince1970: Double($0.atMs) / 1000),
                     topic: $0.topic, happened: $0.happened,
                     nextStep: $0.nextStep, question: $0.question, risk: $0.risk)
            },
            pages: ArtifactStore.history(for: sessionId,
                                         root: QueueStore.supportDirectory.path))
        let dir = root.appendingPathComponent(slug(for: model))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.html")
        try render(model).write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
