import XCTest
@testable import TranquilityCore

/// What the grid ACTUALLY draws, from this machine's real config, real
/// credentials and real servers, through the same band the app calls.
///
/// Guarded on TB_LIVE_GRID so it is inert in CI, which has none of the three.
final class LiveGridProbe: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TB_LIVE_GRID"] == nil,
                      "set TB_LIVE_GRID=1")
    }

    func testTheRowsTheGridWouldDraw() async throws {
        // Exactly what the app builds at launch.
        let registry = AgentProviders.registry()
        let configured = registry.configured()
        print("LIVE providers: \(configured.map(\.id).joined(separator: ", "))")

        let poller = AgentPoller(registry: registry)
        poller.trace = { print("LIVE trace: \($0)") }
        poller.start()
        defer { poller.stop() }

        // Let the seed and the first poll land.
        for _ in 0..<60 where poller.snapshot.agents.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 2_500_000_000)

        let snapshot = poller.snapshot
        print("LIVE snapshot: \(snapshot.agents.count) agent(s), "
            + "\(snapshot.requests.count) pending, "
            + "unreachable: \(snapshot.unreachable.keys.sorted())")

        // THE REAL LOCAL ROWS TOO. The first version of this probe passed
        // empty arrays here, so the only rows were remote and it "showed" four
        // scratch sessions filling the panel. That was a fixture describing
        // itself, not the grid: the real panel carries about twenty local
        // agents and the remote ones sort beneath them.
        let store = try QueueStore()
        let waiting = (try? store.waitingSessions()) ?? []
        let known = (try? store.allKnownSessions()) ?? []
        let discovered = SessionDiscovery.discoverIfScanned()?.sessions ?? []
        let live = Dictionary((ClaudeAgentsCLI().sessions() ?? []).map { ($0.sessionId, $0) },
                              uniquingKeysWith: { a, _ in a })
        print("LIVE local: \(waiting.count) waiting, \(known.count) known, "
            + "\(discovered.count) discovered, \(live.count) live")

        let verdict = GridAssembler.rows(GridAssembler.RowInputs(
            waiting: waiting, known: known, discovered: discovered,
            liveById: live, boundaries: (try? store.latestTurnBoundaries()) ?? [:],
            switchedOff: LampSwitch.load(), switchedOn: LampSwitch.loadOn(),
            evidence: { _, _ in nil }, isHeadless: { _ in false },
            family: { [$0] }, supersedesWaiting: { _, _ in false },
            isInFlight: { _ in false },
            remote: .init(agents: snapshot.agents, requests: snapshot.requests,
                          unread: [], unreachable: snapshot.unreachable)))

        print("LIVE grid: \(verdict.rows.count) row(s)")
        for row in verdict.rows.prefix(30) {
            print("  \(String(describing: row.lamp).padding(toLength: 9, withPad: " ", startingAt: 0))"
                + "\(row.name.prefix(44).padding(toLength: 46, withPad: " ", startingAt: 0))"
                + "\(row.aux.prefix(40))")
        }

        // Who still wears the retired quiet lamp?
        for row in verdict.rows where row.lamp == .running {
            print("LIVE quiet lamp still worn by: \(row.name.prefix(40)) "
                + "harness=\(row.harness ?? "nil") aux=\(row.aux.prefix(30))")
        }
        // ORDERING: what the panel would show if lit rows sorted live-first,
        // then newest-first, instead of by band order.
        let liveOrRemote = Set(live.keys).union(snapshot.agents.map(\.id))
        let lit = verdict.rows.filter { $0.lamp.isLit && !$0.switchedOff }
        print("LIVE lit rows: \(lit.count); lit AND live: "
            + "\(lit.filter { liveOrRemote.contains($0.id) }.count)")
        let reordered = lit.sorted {
            let a = liveOrRemote.contains($0.id), b = liveOrRemote.contains($1.id)
            return a == b ? false : a
        }
        let wouldShow = Array(reordered.prefix(12))
        let remoteSet = Set(snapshot.agents.map(\.id))
        print("LIVE under live-first ordering the panel would show "
            + "\(wouldShow.filter { remoteSet.contains($0.id) }.count) remote of 12:")
        for row in wouldShow {
            print("    \(remoteSet.contains(row.id) ? "REMOTE" : "local ") \(row.name.prefix(42))")
        }

        // Are the green rows actually ALIVE? The ruling says a killed agent
        // is grey, so a green row whose process is gone is a lie.
        let liveIDs = Set(live.keys)
        let greenRows = verdict.rows.filter { $0.lamp == .ready }
        let greenLive = greenRows.filter { liveIDs.contains($0.id) }.count
        print("LIVE green rows: \(greenRows.count), of which alive: \(greenLive), "
            + "dead-or-unknown: \(greenRows.count - greenLive)")
        print("LIVE first 12 by panel order, with liveness:")
        for row in SessionRow.gridRows(verdict.rows, capacity: 12, floor: 4) {
            print("    \(liveIDs.contains(row.id) ? "ALIVE" : "gone ") "
                + "\(String(describing: row.lamp).padding(toLength: 8, withPad: " ", startingAt: 0))"
                + "\(row.name.prefix(40))")
        }

        // The lamp histogram: what the three-lamp ruling (14 Sep) costs.
        var hist: [String: Int] = [:]
        for row in verdict.rows { hist[String(describing: row.lamp), default: 0] += 1 }
        print("LIVE lamps: " + hist.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        print("LIVE lit rows: \(verdict.rows.filter { $0.lamp.isLit && !$0.switchedOff }.count)")
        let alive = verdict.rows.filter { $0.lamp != .unlit }
        print("LIVE alive rows (lamp on): \(alive.count); of those, "
            + "quiet=\(alive.filter { $0.lamp == .running }.count) "
            + "green=\(alive.filter { $0.lamp == .ready }.count) "
            + "blue=\(alive.filter { $0.lamp == .working }.count) "
            + "amber=\(alive.filter { $0.lamp == .fault }.count)")

        let remoteIDs = Set(snapshot.agents.map(\.id))
        let remoteRows = verdict.rows.filter { remoteIDs.contains($0.id) }
        print("LIVE remote rows in the assembled grid: \(remoteRows.count) of \(verdict.rows.count)")

        // And what the PANEL shows, which caps and orders them.
        let shown = SessionRow.gridRows(verdict.rows, capacity: 12, floor: 4)
        let remoteShown = shown.filter { remoteIDs.contains($0.id) }
        print("LIVE panel shows \(shown.count) row(s), of which \(remoteShown.count) are remote")
        for row in shown.prefix(14) {
            let tag = remoteIDs.contains(row.id) ? "REMOTE" : "local "
            print("  \(tag) \(String(describing: row.lamp).padding(toLength: 9, withPad: " ", startingAt: 0))\(row.name.prefix(46))")
        }
        if let at = verdict.rows.firstIndex(where: { $0.harness == "crobot" }) {
            let row = verdict.rows[at]
            let lit = verdict.rows.filter { $0.lamp.isLit && !$0.switchedOff }
            let litAt = lit.firstIndex(where: { $0.harness == "crobot" })
            print("LIVE crobot position: row \(at + 1) of \(verdict.rows.count), "
                + "lit rank \((litAt ?? -1) + 1) of \(lit.count), "
                + "lastActivity \(row.lastActivity.map { "\($0)" } ?? "nil")")
        } else {
            let remote = verdict.rows.filter { remoteIDs.contains($0.id) }
            var byHarness: [String: Int] = [:]
            for r in remote { byHarness[r.harness ?? "nil", default: 0] += 1 }
            print("LIVE remote rows by harness: \(byHarness)")
            print("LIVE snapshot providers: "
                + "\(Set(snapshot.agents.map(\.provider)).sorted())")
            for r in remote where r.harness == nil {
                let agent = snapshot.agents.first { $0.id == r.id }
                print("   nil-harness row \(r.id.prefix(10)) lamp=\(r.lamp) "
                    + "door=\(r.door) provider=\(agent?.provider ?? "?") "
                    + "name=\(r.name.prefix(38))")
                print("     in waiting=\(waiting.contains { $0.sessionId == r.id }) "
                    + "known=\(known.contains { $0.sessionId == r.id }) "
                    + "discovered=\(discovered.contains { $0.sessionId == r.id })")
            }
        }
        let crobot = verdict.rows.first { $0.harness == "crobot" }
        print("LIVE crobot row: \(crobot.map { "\($0.lamp) \($0.name.prefix(46))" } ?? "NOT IN THE GRID")")
    }
}
