import AppKit
import TranquilityCore

/// A real list and window, a real index over real log files, and controlled
/// query completions. This runs before the application delegate exists, so it
/// cannot take the microphone or hotkey.
@MainActor
enum PastAgentsSearchDrill {
    private actor Queries {
        var pending: [String: CheckedContinuation<[SessionKeywordIndex.Match], Error>] = [:]
        func search(_ query: String) async throws -> [SessionKeywordIndex.Match] {
            try await withCheckedThrowingContinuation { pending[query] = $0 }
        }
        func has(_ query: String) -> Bool { pending[query] != nil }
        func finish(_ query: String, id: String) {
            pending.removeValue(forKey: query)?.resume(returning: [
                .init(id: id, role: .user, at: Date(), excerpt: query, count: 1)])
        }
    }

    private static func until(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// One session's log, written the way a harness writes it.
    private static func source(_ id: String, _ title: String, in folder: URL,
                               _ lines: [(role: String, text: String, at: Date)]) throws
        -> SessionKeywordIndex.Source {
        let log = folder.appendingPathComponent("\(id).jsonl")
        let stamp = ISO8601DateFormatter()
        let text = try lines.map { line -> String in
            let row: [String: Any] = ["type": line.role, "timestamp": stamp.string(from: line.at),
                                      "message": ["content": line.text]]
            return String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(to: log, atomically: true, encoding: .utf8)
        return .init(id: id, title: title, activity: lines.map(\.at).max() ?? Date(),
                     transcripts: [log])
    }

    static func run() async -> Bool {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ value: Bool) { checks.append((name, value)) }
        func item(_ id: String, _ name: String, folder: String? = nil) -> PastAgentsList.Item {
            .init(row: SessionRow(id: id, name: name, aux: id, lamp: .unlit, revivable: true),
                  revivable: true, haystack: name, folder: folder)
        }
        // The drill picks an order, and the order is a stored preference of
        // the person whose machine this is. Put it back whatever happens.
        let storedOrder = ProductDefaults.shared.string(forKey: PastAgentsList.orderKey)
        defer {
            if let storedOrder {
                ProductDefaults.shared.set(storedOrder, forKey: PastAgentsList.orderKey)
            } else { ProductDefaults.shared.removeObject(forKey: PastAgentsList.orderKey) }
        }

        let items = [item("safari", "Safari compatibility and keyboard shortcuts", folder: "Kopi"),
                     item("audio", "Audio watchdog")]
        // On the grid, or older than the list's thirty days: not in the list,
        // and a search still answers with it.
        let outside = item("grid", "Onboarding checklist polish")
        let bulk = (0..<60).map { item("bulk-\($0)", "Bulk agent \($0)") }

        let list = PastAgentsList(width: 520, height: 420)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(white: 0.09, alpha: 1)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 470))
        // The panel's own ground, so a picture of the list reads as it does there.
        holder.wantsLayer = true
        holder.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        holder.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 20),
            list.topAnchor.constraint(equalTo: holder.topAnchor, constant: 8),
        ])
        window.contentView = holder
        defer { window.orderOut(nil) }

        list.apply(items: items)
        var opening = list.openingGeneration
        list.filterForTesting("loses focus")
        check("an opening with no search says so, and never Preparing",
              list.summary == "Search is not ready")
        list.filterForTesting("")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-past-search-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let index = SessionKeywordIndex(cacheURL: folder.appendingPathComponent("index.sqlite"))
        do {
            var sources = [
                try source("safari", items[0].row.name, in: folder, [
                    ("user", "In Safari the reply field loses focus after every keystroke, so I cannot type a full sentence.",
                     now.addingTimeInterval(-3 * 86_400)),
                    ("assistant", "The panel guessed wrongly whether the line was being edited.",
                     now.addingTimeInterval(-3 * 86_400 + 60))]),
                try source("audio", items[1].row.name, in: folder, [
                    ("assistant", "The relay loses focus during audio playback, and the watchdog restarts it within two seconds.",
                     now.addingTimeInterval(-3_600)),
                    ("assistant", "After the restart the window no longer loses focus.",
                     now.addingTimeInterval(-7_200))]),
                try source("grid", outside.row.name, in: folder, [
                    ("assistant", "The checklist row loses focus when the grid repaints under it.",
                     now.addingTimeInterval(-40 * 86_400))])]
            for (n, agent) in bulk.enumerated() {
                sources.append(try source(agent.row.id, agent.row.name, in: folder, [
                    ("assistant", "bulkword number \(n)", now.addingTimeInterval(-Double(n) * 60))]))
            }
            let built = try await index.refresh(sources: sources)
            check("the index reads every log once", built.filesRead == sources.count)
            let again = try await index.refresh(sources: sources)
            check("a second pass reads nothing", again.filesRead == 0 && again.messagesAdded == 0)

            list.installSearch({ query, order, every in
                try index.search(query, order: order, excerpts: every ? .max : PastAgentsList.resultPage)
            }, opening: opening)
            list.setSearchable(items + [outside] + bulk, opening: opening)
            list.setOrderForTesting(.recent)
            list.filterForTesting("loses focus")
            let ready = await until { list.searchPublications == 1 }
            window.layoutIfNeeded()
            check("recent puts the newest matching message first",
                  ready && list.shownIDsForTesting == ["audio", "safari", "grid"])
            check("a search reaches an agent that is not in the list",
                  list.shownIDsForTesting.contains("grid"))
            check("every row shows the passage that matched",
                  list.excerptsForTesting.count == 3
                  && list.excerptsForTesting.allSatisfy { $0.contains("loses focus") })
            check("the passage says who said it and how many more matched",
                  list.excerptsForTesting.first?.hasPrefix("AGENT") == true
                  && list.excerptsForTesting.first?.contains("+1 more") == true
                  && list.excerptsForTesting.dropFirst().first?.hasPrefix("YOU") == true)
            check("result rows share one taller height",
                  list.rowHeightsForTesting.allSatisfy { $0 == PastRowView.resultHeight })
            check("a result keeps its folder chip",
                  list.chipsForTesting.contains { $0 == "KOPI" })
            check("every rendered row retains lamp action",
                  list.lampTargetsForTesting == ["audio", "safari", "grid"])
            check("the summary names the order", list.summary == "3 agents · newest first")
            snapshot(holder, named: "recent")

            list.setOrderForTesting(.relevant)
            let reordered = await until { list.searchPublications == 2 }
            check("relevant puts your own words first",
                  reordered && list.shownIDsForTesting.first == "safari"
                  && list.summary == "3 agents · best match first")
            check("the chosen order is remembered", PastAgentsList.storedOrder == .relevant)
            snapshot(holder, named: "relevant")

            list.filterForTesting("bulkword")
            let paged = await until { list.searchPublications == 3 }
            window.layoutIfNeeded()
            check("a long answer draws one page and offers the rest",
                  paged && list.shownIDsForTesting.count == PastAgentsList.resultPage
                  && list.showAllTitleForTesting?.contains("60") == true
                  && list.summary.hasPrefix("50 of 60 agents"))
            list.showAllForTesting()
            let everything = await until { list.shownIDsForTesting.count == 60 }
            window.layoutIfNeeded()
            check("show all draws every result, each with its passage",
                  everything && list.showAllTitleForTesting == nil
                  && list.excerptsForTesting.count == 60
                  && list.excerptsForTesting.allSatisfy { $0.contains("bulkword") })

            list.indexProgress((120, 791))
            check("a first build says how far it is, and still answers",
                  list.summary.hasPrefix("Indexing 120 of 791 · ") && !list.shownIDsForTesting.isEmpty)
            list.indexProgress(nil)

            list.filterForTesting("")
            window.layoutIfNeeded()
            check("clearing restores the list, at its own height",
                  list.shownIDsForTesting == ["safari", "audio"]
                  && list.rowHeightsForTesting.allSatisfy { $0 == GridRowView.height }
                  && list.excerptsForTesting.isEmpty)
        } catch { check("index builds (\(error))", false) }

        let queries = Queries()
        list.filterForTesting("")
        list.installSearch({ query, _, _ in try await queries.search(query) }, opening: opening)
        list.filterForTesting("old")
        check("old query starts", await until { await queries.has("old") })
        list.filterForTesting("new")
        check("new query starts", await until { await queries.has("new") })
        let before = list.searchPublications
        await queries.finish("new", id: "safari")
        check("new answer renders", await until { list.searchPublications == before + 1 })
        await queries.finish("old", id: "audio")
        try? await Task.sleep(for: .milliseconds(30))
        check("late old answer cannot replace it", list.shownIDsForTesting == ["safari"]
              && list.searchPublications == before + 1)

        list.filterForTesting("cleared")
        check("cleared query starts", await until { await queries.has("cleared") })
        list.filterForTesting("")
        await queries.finish("cleared", id: "audio")
        try? await Task.sleep(for: .milliseconds(30))
        check("clearing restores complete list", list.shownIDsForTesting == ["safari", "audio"])

        list.filterForTesting("closed")
        check("closed query starts", await until { await queries.has("closed") })
        list.cancelSearch()
        list.apply(items: [items[0]])
        list.installSearch({ query, order, _ in try index.search(query, order: order) }, opening: opening)
        await queries.finish("closed", id: "audio")
        try? await Task.sleep(for: .milliseconds(30))
        check("old opening cannot change new list", list.shownIDsForTesting == ["safari"])
        list.filterForTesting("audio")
        check("old opening cannot install its search on a new one",
              list.summary == "Search is not ready")
        opening = list.openingGeneration
        list.installSearch({ _, _, _ in throw NSError(domain: "search-drill", code: 1) },
                           opening: opening)
        check("failure is explicit", await until { list.summary.contains("unavailable") })
        list.filterForTesting("")
        check("clearing after failure restores browsing", list.shownIDsForTesting == ["safari"])

        window.layoutIfNeeded()
        for (name, passed) in checks { print("\(passed ? "PASS" : "FAIL") \(name)") }
        print("Past Agents search UI: \(checks.filter { $0.1 }.count)/\(checks.count)")
        return checks.allSatisfy(\.1)
    }

    /// A picture of the real list, when asked for one. The panel's evidence
    /// is what it draws, and this drill is the only place the list is drawn
    /// without a live app around it. `TB_PAST_SEARCH_SNAPSHOT` names a folder.
    private static func snapshot(_ view: NSView, named name: String) {
        guard let folder = ProcessInfo.processInfo.environment["TB_PAST_SEARCH_SNAPSHOT"],
              !folder.isEmpty else { return }
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("past-search-\(name).png")
        try? image.representation(using: .png, properties: [:])?.write(to: url)
    }
}
