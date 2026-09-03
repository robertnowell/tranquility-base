import Foundation

/// Does the archive actually say what the design says it says?
///
/// Every hub failure this month was the same shape and none of them were
/// caught by a test: a page written by the "wrong" tool never reached its hub;
/// a page copied from an exemplar carried a footer naming a stranger's
/// session; a hook fired on one tool while the manifest said three; a byline
/// named a callsign nobody recognised. Unit tests could not see any of it,
/// because each bug lived in the seam between a hook, a log, a file on disk
/// and a rendered page — and every piece was individually correct.
///
/// So this checks the SEAM, against real data, and it is cheap enough to run
/// on every deploy. It asserts what a reader would assert:
///
///   1. A page this session made appears on this session's hub.
///   2. A page carries exactly one agent footer — not zero, not two.
///   3. A hub says which session wrote it, above the fold.
///
/// It reports rather than repairs. A check that silently fixes things teaches
/// you nothing about why they broke, and the repair path already exists.
public enum HubIntegrity {

    public struct Problem: Sendable, Equatable {
        public let session: String
        public let detail: String
    }

    /// The research corpus, asked for rather than compiled in.
    ///
    /// This value used to be one of twenty-odd independent declarations of the
    /// same path, two of which disagreed. It now reads `~/.claude/hq.json`,
    /// preferring `roots.legacy` and accepting the older `hq_root` so a config
    /// written before this change still resolves.
    ///
    /// The compiled path stays as the fallback and is deliberately the SAME
    /// default the Python resolver ships. A fallback that differs from the one
    /// it backs up is not a fallback, it is a second opinion waiting for a
    /// machine with no config.
    public static var hqRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fallback = home.appendingPathComponent("Documents/deep-research",
                                                   isDirectory: true)
        guard let data = try? Data(contentsOf: home
                .appendingPathComponent(".claude/hq.json")),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return fallback }
        let declared = ((obj["roots"] as? [String: Any])?["legacy"] as? String)
            ?? (obj["hq_root"] as? String)
        guard var path = declared, !path.isEmpty else { return fallback }
        if path.hasPrefix("~") { path = home.path + String(path.dropFirst()) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Sessions that have recorded at least one page, newest logs first.
    static func recordedSessions(root: String) -> [String] {
        let dir = ArtifactStore.directory(root: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { ArtifactStore.isPlausibleSession($0) }
    }

    /// `pageExists` is injectable for the same reason `ArtifactStore.history`
    /// takes it: the check is about the RELATIONSHIP between a log and a page,
    /// and a test should be able to state that relationship without a
    /// filesystem — especially since every temp directory is (correctly)
    /// excluded from ever being an artifact.
    public static func check(
        artifactRoot: String = QueueStore.supportDirectory.path,
        hubRoot: URL = HomeBase.root,
        pageExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [Problem] {
        var problems: [Problem] = []

        for session in recordedSessions(root: artifactRoot) {
            let pages = ArtifactStore.history(for: session, root: artifactRoot,
                                              exists: pageExists)
            guard !pages.isEmpty else { continue }
            let slug = HomeBase.slug(forSessionId: session)
            let hubURL = hubRoot.appendingPathComponent(slug)
                .appendingPathComponent("index.html")
            guard let hub = try? String(contentsOf: hubURL, encoding: .utf8) else {
                // No hub yet is not a fault: a session with pages but no brief
                // has nothing to render. A hub that exists must be right.
                continue
            }

            // 1. Every page it made is on its page.
            for page in pages where !hub.contains(page.path) {
                problems.append(Problem(
                    session: slug,
                    detail: "made \(page.path) but the hub does not list it"))
            }

            // 3. The hub names its session where a reader looks first.
            if !hub.contains("session \(slug)") {
                problems.append(Problem(
                    session: slug, detail: "hub byline does not name the session"))
            }
        }

        // 3. A page in the wrong agent's directory.
        //
        //    The page says who wrote it; the directory says whose hub it is on.
        //    When they disagree somebody wrote a report into another agent's
        //    hub, and the archive is asserting the wrong author to anyone who
        //    opens it. Reported rather than repaired: moving a file is not a
        //    check's job, and the fix is one `mv`.
        let agentsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/agents", isDirectory: true)
        for dir in (try? FileManager.default.contentsOfDirectory(
            at: agentsRoot, includingPropertiesForKeys: nil)) ?? [] {
            let slug = dir.lastPathComponent
            guard slug.count == 8, !slug.hasPrefix("_") else { continue }
            for page in (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            where page.pathExtension == "html" && page.lastPathComponent != "index.html" {
                if !ArtifactStore.belongs(page: page.path, to: slug),
                   let declared = ArtifactStore.declaredAgent(of: page.path) {
                    problems.append(Problem(
                        session: slug,
                        detail: "\(page.lastPathComponent) says \(declared) wrote it "
                              + "— it is in the wrong agent's directory"))
                }
            }
        }

        // 2. One footer per page, over the whole archive rather than per
        //    session: a duplicate is usually inherited from somebody else.
        let pages = (try? FileManager.default.contentsOfDirectory(
            at: hqRoot, includingPropertiesForKeys: nil)) ?? []
        for directory in pages {
            let page = directory.appendingPathComponent("index.html")
            guard let html = try? String(contentsOf: page, encoding: .utf8) else { continue }
            // Count FOOTERS, not mentions of the marker.
            //
            // The string test flagged four pages on 02 Sep and every one of
            // them was clean: they are pages ABOUT the footer, so they quote
            // `data-tb-agent` in their prose and carry exactly one real footer.
            // A checker that fires on a page for describing the thing it checks
            // teaches the reader to ignore it, which costs more than the check
            // is worth. Same shape as the hook's own cleanup regex, which has
            // always matched the element rather than the attribute name.
            let stamped = Self.stampedFooters(in: html)
            if stamped > 1 {
                problems.append(Problem(
                    session: directory.lastPathComponent,
                    detail: "carries \(stamped) agent footers"))
            }
        }
        return problems
    }

    /// A `<footer>` whose OPENING TAG carries the stamp.
    ///
    /// Narrower than the hook's cleanup regex on purpose, and the difference is
    /// the whole point of this check. The hook also matches a footer carrying a
    /// discuss link, because when it is about to write a fresh stamp it wants to
    /// clear anything footer-shaped. This is asking a different question — how
    /// many agents claim to own this page — and only `data-tb-agent` answers it.
    /// The wider pattern flagged the hub-replay prototype, which renders twenty
    /// sample hubs with twenty discuss links and is owned by exactly one agent.
    /// How many agents claim to own this page. Exposed so the rule can be
    /// tested against a page rather than only against a directory of them.
    public static func stampedFooters(in html: String) -> Int {
        agentFooter.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html))
    }

    private static let agentFooter = try! NSRegularExpression(
        pattern: "<footer\\b[^>]*\\bdata-tb-agent=", options: [])
}
