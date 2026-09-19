import AppKit
import TranquilityCore

/// A real list and window with controlled query completions. This runs before
/// the application delegate exists, so it cannot take the microphone or hotkey.
@MainActor
enum PastAgentsSearchDrill {
    private actor Queries {
        var pending: [String: CheckedContinuation<[SessionKeywordIndex.Match], Error>] = [:]
        func search(_ query: String) async throws -> [SessionKeywordIndex.Match] {
            try await withCheckedThrowingContinuation { pending[query] = $0 }
        }
        func has(_ query: String) -> Bool { pending[query] != nil }
        func finish(_ query: String, id: String) {
            pending.removeValue(forKey: query)?.resume(returning: [.init(id: id, excerpt: query)])
        }
    }

    private static func until(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    static func run() async -> Bool {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ value: Bool) { checks.append((name, value)) }
        func item(_ id: String, _ name: String) -> PastAgentsList.Item {
            .init(row: SessionRow(id: id, name: name, aux: id, lamp: .unlit, revivable: true),
                  revivable: true, haystack: name)
        }
        let items = [item("safari", "Safari compatibility and keyboard shortcuts"),
                     item("audio", "Audio watchdog")]
        let list = PastAgentsList(width: 520, height: 240)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 270),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = list
        defer { window.orderOut(nil) }
        list.archiveRead = false
        list.apply(items: [])
        let opening = list.openingGeneration
        list.filterForTesting("loses focus")
        list.finishArchive(items: items, opening: opening)
        check("cold query waits for complete index", list.shownIDsForTesting.isEmpty)
        let index = SessionKeywordIndex()
        do {
            try await index.replace(documents: [
                .init(id: "safari", title: items[0].row.name, activity: Date(),
                      userText: "It loses focus after every keystroke."),
                .init(id: "audio", title: items[1].row.name, activity: Date(),
                      assistantText: "It loses focus during audio playback.")])
            list.installSearch({ try await index.search($0) }, opening: opening)
            let ready = await until { list.searchPublications == 1 }
            check("one ranked publication", ready && list.shownIDsForTesting == ["safari", "audio"])
            check("real rendered rows keep rank", list.rowsForTesting.map(\.id) == ["safari", "audio"])
            check("every rendered row retains lamp action", list.lampTargetsForTesting == ["safari", "audio"])
            check("matched words explain the result", list.toolTipsForTesting.contains { $0.contains("loses focus") })
        } catch { check("index builds", false) }

        let queries = Queries()
        list.filterForTesting("")
        list.installSearch({ try await queries.search($0) }, opening: opening)
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
        list.installSearch({ try await index.search($0) }, opening: opening)
        await queries.finish("closed", id: "audio")
        try? await Task.sleep(for: .milliseconds(30))
        check("old opening cannot change new list", list.shownIDsForTesting == ["safari"])
        list.filterForTesting("audio")
        check("old preparation cannot install on reopen", list.summary == "Preparing search…")
        list.installSearch({ _ in throw NSError(domain: "search-drill", code: 1) },
                           opening: list.openingGeneration)
        check("failure is explicit", await until { list.summary.contains("unavailable") })
        list.filterForTesting("")
        check("clearing after failure restores browsing", list.shownIDsForTesting == ["safari"])

        window.layoutIfNeeded()
        for (name, passed) in checks { print("\(passed ? "PASS" : "FAIL") \(name)") }
        print("Past Agents search UI: \(checks.filter { $0.1 }.count)/\(checks.count)")
        return checks.allSatisfy(\.1)
    }
}
