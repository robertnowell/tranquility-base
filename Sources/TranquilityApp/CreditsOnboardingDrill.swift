import AppKit
import TranquilityCore

/// The actual Setup renderer and readiness callback, without AppDelegate,
/// browser pairing, real keys, provider calls, microphone, or a live-app relaunch.
@MainActor
enum CreditsOnboardingDrill {
    private struct Gateway: GatewayTransport {
        func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
            let balance = #"{"availableMicros":"10000000","reservedMicros":"0","ledgerSequence":"1"}"#
            if method == "POST", path == "/v1/account" {
                return (200, Data((#"{"version":"1","accountId":"7f3c2a10-1111-4222-8333-444455556666","currency":"USD","balance":B}"#
                    .replacingOccurrences(of: "B}", with: balance + "}")).utf8))
            }
            if method == "GET", path.hasSuffix("/balance") { return (200, Data(balance.utf8)) }
            throw ScriptError(message: "unexpected request in no-spend UI drill")
        }
    }
    private static func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    static func run() async -> Bool {
        // This drill writes synthetic credentials through the REAL adoption
        // path. Refuse unless the wrapper provided an isolated temporary store.
        let support = QueueStore.supportDirectory.resolvingSymlinksInPath().path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard ProcessInfo.processInfo.environment["VOICE_DISPATCH_SUPPORT_DIR"] != nil,
              support.hasPrefix(temporary.hasSuffix("/") ? temporary : temporary + "/") else {
            print("FAIL credits UI requires an isolated temporary support directory")
            return false
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credits-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity: ManagedCreditSession.IdentitySource = {
            Secrets.read(.hubToken).map { .init(hub: URL(string: "https://fixture.invalid")!, token: $0) }
        }
        let session = ManagedCreditSession(identity: identity, outboxURL: directory.appendingPathComponent("outbox.sqlite"),
                                          connect: { _, _ in .init(transport: Gateway()) })
        let observer = ManagedCredits.observeIdentityChanges(session)
        defer { NotificationCenter.default.removeObserver(observer) }
        let probes = Prerequisites.Probes(tmuxPath: { "/fixture/tmux" }, hooksProblem: { _ in nil },
            hasSecret: { _ in false }, harnesses: { [] },
            hubStatus: { .init(connected: identity() != nil, detail: "fixture sign-in") },
            creditStanding: { CreditStanding.current })
        let view = SetupChecklistView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), probes: probes)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var ready = false
        view.onReadiness = { ready = $0 }
        view.refresh()
        var checks: [(String, Bool)] = []
        let scanned = await until { view.hasScannedForSelfTest }
        checks.append(("unconnected setup is not ready", scanned && !ready))
        do {
            try HubPairing.adopt(token: "fixture-A", base: URL(string: "https://fixture.invalid")!,
                                 config: directory.appendingPathComponent("hq.json"))
        } catch { print("FAIL fixture pairing adoption: \(error)"); return false }
        let connected = await until { ready && view.rowTextForSelfTest.contains("$10.00 at last balance check") }
        checks.append(("existing checklist reacts to completed sign-in", connected))
        checks.append(("personal key is explicitly optional", view.rowTextForSelfTest.contains("not required for credits")))
        do { try Secrets.write(.hubToken, value: "") }
        catch { print("FAIL fixture sign-out: \(error)"); return false }
        let disconnected = await until { !ready && !view.rowTextForSelfTest.contains("$10.00") }
        checks.append(("sign-out removes readiness and previous balance", disconnected))
        do {
            try HubPairing.adopt(token: "fixture-B", base: URL(string: "https://fixture.invalid")!,
                                 config: directory.appendingPathComponent("hq.json"))
        } catch { print("FAIL fixture second pairing: \(error)"); return false }
        checks.append(("same checklist becomes ready for next sign-in", await until { ready }))
        window.layoutIfNeeded()
        for (name, passed) in checks { print("\(passed ? "PASS" : "FAIL") \(name)") }
        print("Credits onboarding UI: \(checks.filter { $0.1 }.count)/\(checks.count)")
        return checks.allSatisfy(\.1)
    }
}
