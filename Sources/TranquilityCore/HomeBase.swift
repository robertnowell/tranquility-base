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
        /// The written header (v11): the headline names the finding, the deck
        /// names what is left. Nil on turns from before the field existed, or
        /// when the summariser judged the turn pure plumbing; the derived
        /// header is the floor.
        public let headline: String?
        public let deck: String?
        /// The ⌃⌃ ladder, already generated for the voice and already stored:
        /// what the work turned up, the shape of what is proposed, and why.
        /// The newest turn prints all three, because the question a hub is
        /// opened to answer is "what just happened", and the fields that
        /// answer it were being written and thrown away (ruled 16 Aug).
        public let findings: String?
        public let solution: String?
        public let rationale: String?

        public init(at: Date, topic: String, happened: String,
                    nextStep: String? = nil, question: String? = nil,
                    risk: String? = nil, headline: String? = nil,
                    deck: String? = nil, findings: String? = nil,
                    solution: String? = nil, rationale: String? = nil) {
            self.at = at; self.topic = topic; self.happened = happened
            self.nextStep = nextStep; self.question = question; self.risk = risk
            self.headline = headline; self.deck = deck
            self.findings = findings; self.solution = solution
            self.rationale = rationale
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

    /// Drop the segment that repeats at the same end of two or more titles.
    ///
    /// Site furniture is invisible in one title and obvious in a list: it is
    /// the part that does not change. Position is not the signal — this house
    /// writes "Site — Page" and the wider web writes "Page — Site" — so the
    /// repeated segment is stripped from whichever end it holds. A title left
    /// with nothing keeps its original, because a blank name is worse than a
    /// repeated one.
    static let titleSeparators = [" — ", " – ", " | ", " · ", " » ", " > "]

    static func strippingSharedAffix(_ titles: [String?]) -> [String?] {
        let present = titles.compactMap { $0 }
        guard present.count >= 2 else { return titles }

        func split(_ title: String) -> (head: String, tail: String)? {
            for separator in titleSeparators {
                if let range = title.range(of: separator) {
                    return (String(title[..<range.lowerBound]),
                            String(title[range.upperBound...]))
                }
            }
            return nil
        }

        let parts = present.compactMap(split)
        guard parts.count >= 2 else { return titles }
        let heads = Dictionary(grouping: parts, by: \.head).filter { $0.value.count >= 2 }
        let tails = Dictionary(grouping: parts, by: \.tail).filter { $0.value.count >= 2 }
        let sharedHead = heads.keys.sorted().first
        let sharedTail = tails.keys.sorted().first

        return titles.map { title -> String? in
            guard let title, let (head, tail) = split(title) else { return title }
            if let sharedHead, head == sharedHead, !tail.isEmpty { return tail }
            if let sharedTail, tail == sharedTail, !head.isEmpty { return head }
            return title
        }
    }

    /// The page's palette and nameplate, chosen by the project the agent is
    /// working in — the same discipline the share-as-page skill applies to a
    /// document: a brand with RECORDED tokens gets its colours, everything
    /// else gets the house editorial default, and nothing is ever invented to
    /// make a page feel branded.
    ///
    /// Structure never varies. The masthead rule, the tracked eyebrow, the
    /// serif headline over a dek, the hairline byline and the short accent
    /// rule above each section are the house's own engineering-notes layout
    /// (adopted 16 Aug from the App Store brief). Only the inks move.
    public struct Theme: Sendable, Equatable {
        public let id: String
        /// What the eyebrow says before the project name.
        public let nameplate: String
        public let bg: String
        public let paper: String
        public let ink: String
        public let heading: String
        public let muted: String
        public let faint: String
        public let line: String
        public let accent: String
        /// Structural ink: nameplate, masthead rule, headings.
        public let brand: String
        /// Amber is the risk tag and nothing else, in every theme.
        public let amber: String
        /// The brand's own faces, and the local stylesheet that carries them.
        /// A hub that only takes the palette is not the brand, it is the
        /// brand's colours on somebody else's type (ruled 16 Aug). Hubs are
        /// local-only by design, so the faces are referenced from one file on
        /// disk rather than embedded per page — one copy, not 400KB a hub.
        public let serif: String
        public let sans: String
        public let fontSheet: String?
        /// Whether a dark palette is offered. Brand light-stock designs say no
        /// on purpose: their tokens are specified for paper, and a machine-
        /// darkened brand colour is an invented one.
        public let hasDark: Bool

        /// House editorial. Rung 5 in the skill's ladder: a deliberate
        /// unbranded look, never a guess at somebody's identity.
        public static let editorial = Theme(
            id: "editorial", nameplate: "Tranquility Base",
            bg: "#fcfbf8", paper: "#f4f2ec", ink: "#1f1e1c", heading: "#141312",
            muted: "#57534c", faint: "#6e6a63", line: "#ddd9cf",
            accent: "#a32c28", brand: "#1a1a1a", amber: "#a8762a",
            serif: "'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif",
            sans: "ui-sans-serif,-apple-system,'Helvetica Neue',sans-serif",
            fontSheet: nil, hasDark: true)

        /// Kopi, "The Press": navy carries structure, orange only punctuates.
        /// Tokens rung 2, references/brands.md. The brand's own faces
        /// (Bricolage Grotesque, Plus Jakarta Sans) are NOT here: naming a
        /// font without embedding it renders system sans and quietly claims an
        /// identity the page does not carry, and a page rewritten every turn
        /// cannot afford 400KB of embedded faces.
        public static let kopi = Theme(
            id: "kopi", nameplate: "Kopi",
            bg: "#fcfbf8", paper: "#f4f2ec", ink: "#1f1e1c", heading: "#1e3a52",
            muted: "#57534c", faint: "#6e6a63", line: "#ddd9cf",
            accent: "#ff6b4a", brand: "#1e3a52", amber: "#a8762a",
            // The Press sets in Bricolage Grotesque over Plus Jakarta Sans,
            // and a page claiming Kopi in system serif was claiming an
            // identity it did not carry.
            serif: "'Bricolage Grotesque',ui-sans-serif,-apple-system,sans-serif",
            sans: "'Plus Jakarta Sans',ui-sans-serif,-apple-system,sans-serif",
            fontSheet: "kopi.css", hasDark: false)

        /// Mirai. Only two tokens are recorded (#F57C00 on #F0F8FF, from the
        /// brand record via Kopi's get_context), so only those two move; the
        /// neutrals stay editorial rather than being invented around them.
        public static let mirai = Theme(
            id: "mirai", nameplate: "Mirai",
            bg: "#f0f8ff", paper: "#e6f1fb", ink: "#1f1e1c", heading: "#14304a",
            muted: "#4f5b66", faint: "#69737d", line: "#cddeee",
            accent: "#f57c00", brand: "#14304a", amber: "#a8762a",
            // Mirai's faces (Abril Fatface, DM Sans) are recorded but not yet
            // on disk here; naming them without the file renders system sans
            // and claims what the page has not got, so the stack stays honest
            // until someone drops the woff2 into hq-fonts.
            serif: "'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif",
            sans: "ui-sans-serif,-apple-system,'Helvetica Neue',sans-serif",
            fontSheet: nil, hasDark: false)

        /// THE PAGE DECLARES ITS BRAND, and the directory is only the guess
        /// of last resort.
        ///
        /// A directory says where a terminal happens to sit, not what the work
        /// is about: a session fixing Tranquility Base from a promotions
        /// checkout was themed as Kopi and titled "KOPI · PROMOTIONS" while
        /// every page it wrote declared Tranquility Base (measured 16 Aug).
        /// Every HQ page carries `intranet:brand` because share-as-page
        /// requires it, so the agent's own artifacts are the honest signal —
        /// they are the thing the brand is FOR.
        public static func forBrand(_ name: String?) -> Theme? {
            guard let key = name?.lowercased() else { return nil }
            if key.contains("mirai") { return .mirai }
            if key.contains("kopi") { return .kopi }
            if key.contains("tranquility") { return .editorial }
            return nil
        }

        /// The project decides only when nothing has been written yet.
        public static func forProject(cwd: String?) -> Theme {
            let path = (cwd ?? "").lowercased()
            if path.contains("mirai") { return .mirai }
            if path.contains("kopi") || path.contains("promotions") { return .kopi }
            return .editorial
        }

        /// Every agent gets its own ink.
        ///
        /// Twenty hubs in the house style are twenty pages a reader cannot
        /// tell apart at a glance, and "which agent am I looking at" is the
        /// question the page exists to answer (ruled 16 Aug). One colour moves
        /// and nothing else, so the house style stays the house style.
        ///
        /// Derived from the session id, never assigned: the same agent is the
        /// same colour forever, on every page it writes, with no state to keep
        /// and nothing to collide over. The palette is chosen, not computed —
        /// eight inks that all hold their weight as a hairline on warm paper,
        /// which a hue rotation does not.
        ///
        /// A BRAND theme keeps its own accent. Kopi's orange is the identity
        /// and an agent is not one; there, the mark of the agent is its
        /// nameplate and byline.
        static let agentInks = [
            "#a32c28",  // house red
            "#1f4f8f",  // ink blue
            "#3d7048",  // field green
            "#8a5a2b",  // umber
            "#6b4a8f",  // aubergine
            "#1f6f6b",  // teal
            "#96432c",  // rust
            "#4a5a2b",  // olive
        ]

        public func forAgent(sessionId: String) -> Theme {
            guard id == Theme.editorial.id else { return self }
            // FNV-1a over the id: stable across machines and launches, which a
            // hashValue is explicitly not.
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in sessionId.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
            let ink = Theme.agentInks[Int(hash % UInt64(Theme.agentInks.count))]
            return Theme(id: id, nameplate: nameplate, bg: bg, paper: paper, ink: self.ink,
                         heading: heading, muted: muted, faint: faint, line: line,
                         accent: ink, brand: brand, amber: amber,
                         serif: serif, sans: sans, fontSheet: fontSheet,
                         hasDark: hasDark)
        }
    }

    /// "Kopi · promotions", but never "Tranquility Base · tranquility-base".
    /// A nameplate that says the same thing twice reads as a template that
    /// forgot to fill itself in.
    static func nameplate(brand: String, project: String?) -> String {
        func key(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        guard var project, !project.isEmpty else { return brand }
        let brandKey = key(brand)
        // "kopi-promotions" under the Kopi plate is "promotions": a directory
        // named after its brand says the brand twice, and the second half is
        // the part that identifies the work.
        while key(project).hasPrefix(brandKey), key(project) != brandKey {
            guard let cut = project.firstIndex(where: { $0 == "-" || $0 == "_" || $0 == " " })
            else { break }
            project = String(project[project.index(after: cut)...])
        }
        guard key(project) != brandKey, !project.isEmpty else { return brand }
        return "\(brand) · \(project)"
    }

    /// Slug → public URL, for the pages that have been published.
    ///
    /// A hosted page is the version other people can actually open, and the
    /// hub knew nothing about it: a report could be live on the web while its
    /// own agent's page linked only to a file:// path (ruled 16 Aug). The
    /// publisher already records the answer in the HQ catalogue, so this reads
    /// it rather than deriving a URL — a derived one would be a guess that
    /// looks like a fact, and would keep looking like one after the host
    /// changes.
    ///
    /// Missing or unreadable catalogue is not a fault; the hub simply shows
    /// the local page, exactly as before.
    /// The brand an agent's own pages declare, newest first. Reading the meta
    /// tag rather than trusting a directory is what makes the theme follow the
    /// work instead of the terminal.
    static func declaredBrand(pages: [ArtifactStore.Page]) -> String? {
        for page in pages.sorted(by: { $0.at > $1.at }) {
            guard let head = try? String(contentsOfFile: page.path, encoding: .utf8)
                .prefix(4_000) else { continue }
            if let range = head.range(
                of: #"<meta[^>]+name=["']intranet:brand["'][^>]+content=["']([^"']+)["']"#,
                options: .regularExpression) {
                let tag = String(head[range])
                if let value = tag.range(of: #"content=["']([^"']+)["']"#,
                                         options: .regularExpression) {
                    return String(tag[value])
                        .replacingOccurrences(of: "content=", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }
        return nil
    }

    /// Where brand faces live, shared by every local page rather than
    /// embedded in each one.
    public static var fontSheetRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hq-fonts", isDirectory: true)
    }

    public static var catalogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/intranet/catalog.json")
    }

    static func publishedURLs(catalog: URL = catalogURL) -> [String: String] {
        guard let data = try? Data(contentsOf: catalog),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var map: [String: String] = [:]
        for item in items where (item["visibility"] as? String) == "hosted" {
            if let slug = item["slug"] as? String, let url = item["url"] as? String {
                map[slug] = url
            }
        }
        return map
    }

    /// One `<li>` per page: the document's own title, its day, and a hover
    /// blurb. Shared by the inline list under a turn and the shelf at the
    /// bottom, so a page looks the same wherever it is filed.
    static func pageItems(_ pages: [ArtifactStore.Page],
                          e: (String) -> String,
                          published: [String: String] = publishedURLs()) -> String {
        let newestFirst = pages.sorted { $0.at > $1.at }
        let summaries = newestFirst.map { ArtifactStore.summarize(path: $0.path) }
        // The siblings name the brand. A single title cannot say which of
        // "Tranquility Base — roadmap ahead" is furniture and which is the
        // subject; a LIST can, because furniture is what repeats.
        let names = strippingSharedAffix(summaries.map(\.title))
        return zip(newestFirst, zip(names, summaries)).map { page, pair -> String in
            let (stripped, summary) = pair
            let name = stripped ?? summary.title ?? page.label
            let blurb = summary.blurb.map { " data-blurb=\"\(e($0))\"" } ?? ""
            // No stamp survived anywhere (log undated, file unreadable): say
            // nothing. A page dated "31 Dec" of 1969 is worse than an undated
            // one — a wrong fact where a missing one was honest.
            let on = page.at > Date(timeIntervalSince1970: 0)
                ? "<span class=\"on\">\(e(dayStamp.string(from: page.at)))</span>" : ""
            // A new tab, deliberately: the hub is the reader's index and stays
            // open while its artifacts are visited (ruled 15 Aug).
            // Published pages say so, and link to the copy other people can
            // open. The local file stays the primary link: it is the one that
            // works with no network and is always current.
            let slug = (page.path as NSString).deletingLastPathComponent
            let live = published[(slug as NSString).lastPathComponent].map {
                "<a class=\"live\" href=\"\(e($0))\" target=\"_blank\" rel=\"noopener\">published</a>"
            } ?? ""
            return "<li><a class=\"page\" href=\"file://\(e(page.path))\""
                + " target=\"_blank\" rel=\"noopener\"\(blurb)>"
                + "\(e(name))</a>\(live)\(on)</li>"
        }.joined()
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
        let name = model.title ?? "Agent \(model.sessionId.prefix(8))"
        let newest = model.turns.first          // turns arrive newest-first
        let ordered = model.turns
        // The pages say what this work is; the directory only guesses.
        let theme = (Theme.forBrand(declaredBrand(pages: model.pages))
                     ?? Theme.forProject(cwd: model.cwd))
            .forAgent(sessionId: model.sessionId)

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
            // The written header wins when the summariser supplied one: the
            // headline names the finding, the deck names what is left
            // (A/B'd 11 Aug; shipped 15 Aug). The derived join is the floor.
            let deck = n.deck.map(e)
                ?? n.question.map { "\(e(sentence(n.happened))) \(e($0))" }
                ?? (n.nextStep.map { "\(e(sentence(n.happened))) Proposing: \(e($0))" }
                    ?? e(n.happened))
            // WHO WROTE THIS, above the fold, in the two names a reader can
            // act on: the session's title — the string the grid and the
            // terminal tab both show — and the id, which is what survives when
            // the title changes and what every log, path and deep link uses.
            //
            // The callsign used to sit here and was the only identity on the
            // page: "Agent home contamination" names nothing a reader has ever
            // seen (ruled 16 Aug). It is a SPOKEN name, minted to be said out
            // loud once in an announcement, and on a page it read as a third
            // identity competing with the two real ones.
            var byline = "\(e(model.title ?? "Untitled session")) · session "
                + "\(e(String(model.sessionId.prefix(8))))"
            if let dir = (model.cwd as NSString?)?.lastPathComponent, !dir.isEmpty {
                byline += " · in \(e(dir))"
            }
            if let last = model.lastActive {
                byline += " · last moved \(e(stamp.string(from: last)))"
            }
            // The masthead: a thick rule, the nameplate tracked in sans on the
            // left, the date on the right — the engineering-notes shape this
            // house already uses for its briefs. Then the accent kicker, the
            // serif headline, the dek, and the byline between hairlines.
            let project = (model.cwd as NSString?)?.lastPathComponent
            let plate = nameplate(brand: theme.nameplate, project: project)
            let dateline = model.lastActive.map { dayStamp.string(from: $0) } ?? ""
            head = """
                <header class="plate"><span>\(e(plate))</span><span>\(e(dateline))</span></header>
                <p class="kicker">Agent</p>
                <h1>\(e(n.headline ?? n.topic))</h1>
                <p class="deck">\(deck)</p>
                <p class="byline">\(byline)</p>
                """
        }

        // ---- the pages, filed under the turn that made them ------------------
        //
        // A page belongs to the turn it was written during: newer than the
        // turn before it, no newer than the turn itself. Filing them this way
        // is the whole point — a turn that produced a report should SHOW the
        // report, not leave it in a separate list above the work (ruled
        // 16 Aug: "what it has made shows first, and that's not the most
        // recent turn"). Anything that lands under no shown turn falls to the
        // shelf at the bottom of the page.
        var pagesByTurn: [Int: [ArtifactStore.Page]] = [:]
        var shelved: [ArtifactStore.Page] = []
        for page in model.pages {
            // `ordered` is newest-first, so the first turn at or after the
            // page's stamp is the turn that was running when it was written.
            let owner = ordered.indices.last { index in
                // The newest turn's window has no ceiling: a page written
                // after the last brief belongs to the work in flight, not to
                // a shelf underneath older turns.
                (index == 0 || page.at <= ordered[index].at)
                    && (index + 1 >= ordered.count || page.at > ordered[index + 1].at)
            }
            if let owner, owner < fullTurns + lineTurns {
                pagesByTurn[owner, default: []].append(page)
            } else {
                shelved.append(page)
            }
        }

        // ---- the stack, downsampled by age ----------------------------------
        var rows = ""
        for (i, turn) in ordered.enumerated() {
            var body = "<p class=\"h\">\(e(turn.happened))</p>"
            var cls = "line"
            if i < fullTurns {
                cls = "full"
                // The newest turn prints the whole ladder, because "what just
                // happened" is the question the page is opened to answer.
                if i == 0 {
                    for (label, text) in [("found", turn.findings),
                                          ("proposes", turn.solution),
                                          ("why", turn.rationale)] {
                        if let text, !text.isEmpty {
                            body += "<p class=\"m\"><span>\(label)</span> \(e(text))</p>"
                        }
                    }
                }
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
            // The turn's own work, under the turn: a made thing reads as a
            // result here and as an orphan in a list somewhere else.
            if let made = pagesByTurn[i], !made.isEmpty {
                body += "<ul class=\"made\">" + pageItems(made, e: e) + "</ul>"
            }
            rows += """
                <li class="\(cls)"><div class="when">\(e(stamp.string(from: turn.at)))</div>
                <div class="what"><h3>\(e(turn.headline ?? turn.topic))</h3>\(body)</div></li>
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

        // ---- the shelf: pages no shown turn accounts for --------------------
        //
        // Everything a shown turn made is printed with that turn. What is left
        // is older work, and older work belongs BELOW the stack, not above it
        // (ruled 16 Aug). An agent whose every page is inline has no shelf at
        // all, which is the healthy case.
        var pages = ""
        if !shelved.isEmpty {
            pages = """
                <h2>Earlier pages</h2>
                <ul class="pages">\(pageItems(shelved, e: e))</ul>
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
          /* PROVENANCE — theme \(theme.id). Editorial tokens are rung 5, the
             house default; Kopi is rung 2 (share-as-page references/brands.md);
             Mirai's two recorded tokens are rung 3 (the brand record), and its
             neutrals stay editorial rather than being invented around them.
             Type is the system serif/sans stack, NOT the brands' own faces:
             naming a face without embedding it renders system sans and claims
             an identity the page has not got, and a page rewritten every turn
             cannot carry embedded fonts. */
          :root{--bg:\(theme.bg);--fg:\(theme.ink);--dim:\(theme.muted);--faint:\(theme.faint);
                --rule:\(theme.line);--amber:\(theme.amber);--card:\(theme.paper);
                --accent:\(theme.accent);--brand:\(theme.brand);
                --serif:\(theme.serif);--sans:\(theme.sans)}
          \(theme.hasDark ? """
          @media(prefers-color-scheme:dark){:root{--bg:#131310;--fg:#eceae2;--dim:#a5a196;
                --faint:#6a6558;--rule:#2e2c26;--amber:#d9a441;--card:#1e1d19;
                --accent:#e0645f;--brand:#eceae2}}
          """ : "/* light stock only: this brand's tokens are specified for paper. */")
          *{box-sizing:border-box}html{background:var(--bg)}
          body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--serif);
               font-size:18px;line-height:1.62;-webkit-font-smoothing:antialiased}
          /* 66 characters is Bringhurst's ideal; 45–75 the acceptable band. */
          .wrap{max-width:660px;margin:0 auto;padding:0 26px 56px}
          /* The masthead: a thick rule the width of the measure, the nameplate
             tracked in sans on the left, the dateline on the right. It is the
             one place caps belong on this page, because a nameplate is a
             label and not prose. */
          .plate{display:flex;justify-content:space-between;align-items:baseline;gap:16px;
                 margin-top:44px;padding:14px 0 12px;border-top:3px solid var(--brand);
                 border-bottom:1px solid var(--rule);
                 font-family:var(--sans);font-size:12px;font-weight:600;
                 letter-spacing:.12em;text-transform:uppercase;color:var(--brand)}
          .plate span:last-child{color:var(--faint);font-weight:500;white-space:nowrap}
          .kicker{font-family:var(--sans);font-size:12px;font-weight:700;letter-spacing:.12em;
                  text-transform:uppercase;color:var(--accent);margin:34px 0 10px}
          h1{font-size:44px;line-height:1.06;letter-spacing:-.022em;font-weight:600;
             margin:0 0 18px;max-width:17ch;color:var(--brand)}
          .deck{font-size:20px;line-height:1.5;color:var(--dim);margin:0 0 22px;max-width:60ch}
          .byline{font-family:var(--sans);font-size:12.5px;line-height:1.55;color:var(--faint);
                  letter-spacing:.02em;
                  margin:0 0 44px;padding:16px 0 0;border-top:1px solid var(--rule)}
          /* A short accent rule over each section: the second ink's whole job,
             rationed to a hairline so it punctuates rather than fills. */
          h2{font-size:26px;line-height:1.2;letter-spacing:-.015em;font-weight:600;
             margin:52px 0 6px;padding-top:14px;position:relative;color:var(--brand)}
          h2::before{content:"";position:absolute;top:0;left:0;width:46px;height:3px;
                     background:var(--accent)}
          .sub{font-family:var(--sans);font-size:13px;color:var(--faint);margin:0 0 14px}
          /* The list carries the gap its deleted subline used to hold, so the
             first rule does not crowd the heading. */
          ul.pages{list-style:none;padding:0;margin:14px 0 0}
          /* A page made by a turn, printed under it: indented off the accent
             so it reads as this turn's output rather than a sibling claim. */
          ul.made{list-style:none;padding:0 0 0 13px;margin:10px 0 2px;
                  border-left:2px solid var(--accent)}
          ul.made li{padding:4px 0}
          ul.made .page{color:var(--fg);text-decoration:none;font-size:16px;
                        border-bottom:1px solid var(--rule)}
          ul.made .page:hover{color:var(--accent)}
          ul.made .on{display:none}
          ul.pages li{display:flex;align-items:baseline;gap:14px;padding:12px 0;
                      border-top:1px solid var(--rule)}
          ul.pages .page{color:var(--fg);text-decoration:none;font-size:18px;flex:1;
                         line-height:1.4}
          ul.pages .page:hover{color:var(--accent)}
          ul.pages .on{font-family:var(--sans);font-size:12.5px;color:var(--faint);
                       white-space:nowrap}
          /* "published" — the copy other people can open. Quiet, in the
             agent's own ink, because it is a fact about the page rather than
             a second name for it. */
          .live{font-family:var(--sans);font-size:11px;font-weight:700;
                letter-spacing:.08em;text-transform:uppercase;color:var(--accent);
                text-decoration:none;white-space:nowrap;margin-left:2px}
          .live:hover{text-decoration:underline}
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
        <h2>What it has done</h2>
        <p class="sub">Newest first. Older turns lose resolution, never their links.</p>
        <ol>\(rows)</ol>
        \(digest)\(empty)
        \(pages)
        <footer>Created by <b>\(e(model.title ?? "—"))</b> &middot;
        session \(e(String(model.sessionId.prefix(8))))
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
                     nextStep: $0.nextStep, question: $0.question, risk: $0.risk,
                     headline: $0.headline, deck: $0.deck,
                     findings: $0.findings, solution: $0.solution,
                     rationale: $0.rationale)
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
