import XCTest
@testable import TranquilityCore

final class SavedAccountsTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-accounts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testNamesCanChangeWithoutMovingCredentials() throws {
        let file = root.appendingPathComponent("accounts.json")
        let store = SavedAccountStore(fileURL: file)
        var account = SavedAccount(label: "Work", configDirectory: root.appendingPathComponent("profile").path)
        try store.save(account)
        account.label = "Personal"
        try store.save(account)
        XCTAssertEqual(SavedAccountStore(fileURL: file).all(), [account])
        XCTAssertEqual(store.account(account.id)?.configDirectory, account.configDirectory)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testDuplicateRootAndDefaultRootCannotCreateAnotherCredentialIdentity() throws {
        let store = SavedAccountStore(fileURL: root.appendingPathComponent("accounts.json"))
        let profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try store.save(SavedAccount(label: "A", configDirectory: profile.path))
        XCTAssertThrowsError(try store.save(SavedAccount(label: "B", configDirectory: profile.path)))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: profile)
        XCTAssertThrowsError(try store.save(SavedAccount(label: "B", configDirectory: alias.path)))
        XCTAssertThrowsError(try store.save(SavedAccount(label: "Main", configDirectory: SavedAccountStore.defaultRoot.path)))
    }

    func testCorruptRegistryIsNotOverwritten() throws {
        let file = root.appendingPathComponent("accounts.json")
        try Data("not json".utf8).write(to: file)
        let store = SavedAccountStore(fileURL: file)
        XCTAssertThrowsError(try store.save(SavedAccount(label: "B", configDirectory: root.appendingPathComponent("B").path)))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
    }

    func testObservedIdentityMustMatchRouteRootAndPinnedAccount() throws {
        var account = SavedAccount(label: "A", configDirectory: root.path)
        account.email = "a@example.test"; account.organization = "org-a"
        var status: [String: Any] = ["loggedIn": true, "authMethod": "claude.ai", "configDirectory": root.path,
                                     "email": "a@example.test", "orgId": "org-a"]
        func decode() throws -> SavedAccountIdentity {
            try SavedAccountIdentity.decode(JSONSerialization.data(withJSONObject: status), account: account)
        }
        XCTAssertEqual(try decode().email, "a@example.test")
        status["authMethod"] = "oauth_token"; XCTAssertThrowsError(try decode())
        status["authMethod"] = "claude.ai"; status["email"] = "b@example.test"; XCTAssertThrowsError(try decode())
        status["email"] = "a@example.test"; status["orgId"] = "org-b"; XCTAssertThrowsError(try decode())
        status["orgId"] = "org-a"; status["configDirectory"] = root.appendingPathComponent("other").path
        XCTAssertThrowsError(try decode())
    }

    func testSessionBindingSurvivesRestartAndRefusesReassignment() throws {
        let file = root.appendingPathComponent("sessions.json")
        let store = SessionAccountStore(fileURL: file)
        try store.bind("session", targetID: "A", root: root.appendingPathComponent("A"))
        try store.bind("session", targetID: "A", root: root.appendingPathComponent("A"))
        XCTAssertThrowsError(try store.bind("session", targetID: "B", root: root.appendingPathComponent("B")))
        XCTAssertEqual(SessionAccountStore(fileURL: file).binding("session")?.targetID, "A")
    }

    func testTwoRegistryRootsAndAmbiguousID() throws {
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for profile in [a, b] { try FileManager.default.createDirectory(at: profile.appendingPathComponent("sessions"), withIntermediateDirectories: true) }
        func write(_ id: String, to profile: URL) throws {
            let data = try JSONSerialization.data(withJSONObject: ["pid": 100, "sessionId": id, "cwd": "/same"])
            try data.write(to: profile.appendingPathComponent("sessions/100.json"))
        }
        try write("one", to: a); try write("two", to: b)
        let entries = try XCTUnwrap(SessionRegistry.read(roots: ["A": a, "B": b]))
        XCTAssertEqual(Set(entries.compactMap(\.accountTargetID)), ["A", "B"])
        try write("one", to: b)
        XCTAssertNil(SessionRegistry.read(roots: ["A": a, "B": b]), "Do not route an ambiguous public session ID")
    }

    func testRecoveryMatchesAccountAndExactPaneNotDirectoryOrArrivalOrder() {
        var receipt = LaunchRecoveryRecord(id: "launch:a", targetID: "A", directory: "/same")
        receipt.paneID = "%17"; receipt.paneSession = "tb-owned"
        var live = LiveSession(pid: 100, sessionId: "one", cwd: "/same", status: nil, name: nil, waitingFor: nil)
        live.accountTargetID = "A"; live.registryTmux = "tb-owned:@17.%17"
        XCTAssertTrue(LaunchRecoveryStore.matches(live, record: receipt))
        live.registryTmux = "tb-other:@17.%17"
        XCTAssertFalse(LaunchRecoveryStore.matches(live, record: receipt))
        live.registryTmux = "tb-owned:@17.%17"; live.accountTargetID = "B"
        XCTAssertFalse(LaunchRecoveryStore.matches(live, record: receipt))
    }

    func testRegistrationSkipsOtherSameDirectoryLaunch() {
        var wanted = LiveSession(pid: 1, sessionId: "wanted", cwd: "/same", status: nil, name: nil, waitingFor: nil)
        wanted.accountTargetID = "B"
        let other = LiveSession(pid: 2, sessionId: "other", cwd: "/same", status: nil, name: nil, waitingFor: nil)
        let agents = LaunchGreetingTests.ScriptedAgents([[other, wanted]])
        XCTAssertEqual(LaunchGreeting.awaitRegistration(directory: "/same", excluding: [], matches: { $0.accountTargetID == "B" }, agents: agents), "wanted")
    }

    func testDraftAndAliasSurviveRestartWhileUncertainSendCannotReplay() throws {
        let file = root.appendingPathComponent("fragments.json")
        let first = AttachmentStore(fileURL: file)
        first.stage("source pointers", session: "launch:a")
        first.stage("my instruction", session: "launch:a")
        let restarted = AttachmentStore(fileURL: file)
        XCTAssertEqual(restarted.staged(for: "launch:a"), ["source pointers", "my instruction"])
        restarted.adopt(stagingKey: "launch:a", asSession: "real")
        restarted.stage("late attachment", session: "launch:a")
        let next = AttachmentStore(fileURL: file)
        XCTAssertEqual(next.staged(for: "real").count, 3)
        XCTAssertEqual(next.snapshot(session: "real", utteranceId: "send").count, 3)
        let crashedAfterSend = AttachmentStore(fileURL: file)
        XCTAssertTrue(crashedAfterSend.staged(for: "real").isEmpty)
        XCTAssertEqual(crashedAfterSend.uncertainDeliveries["send"]?.count, 3)
        XCTAssertTrue(crashedAfterSend.snapshot(session: "real", utteranceId: "new-send").isEmpty)
    }

    func testFailedSendRestagesButVerificationTimeoutRetainsReceiptOnly() throws {
        let store = AttachmentStore(fileURL: root.appendingPathComponent("fragments.json"))
        store.stage("context", session: "s")
        _ = store.snapshot(session: "s", utteranceId: "failure")
        store.resolve(utteranceId: "failure", landed: false)
        XCTAssertEqual(store.staged(for: "s"), ["context"])
        _ = store.snapshot(session: "s", utteranceId: "ambiguous")
        store.markUncertain(utteranceId: "ambiguous")
        XCTAssertEqual(store.uncertainDeliveries["ambiguous"], ["context"])
        XCTAssertTrue(store.staged(for: "s").isEmpty)
    }

    func testRecoveryReceiptRetainsInstructionAndProcessAcrossRestart() throws {
        let file = root.appendingPathComponent("launches.json")
        let store = LaunchRecoveryStore(fileURL: file)
        try store.save(LaunchRecoveryRecord(id: "launch:a", targetID: "B", directory: "/project"))
        try store.update("launch:a") { $0.instruction = "continue this"; $0.paneID = "%17"; $0.paneSession = "tb-owned"; $0.state = "unresolved" }
        let record = try XCTUnwrap(LaunchRecoveryStore(fileURL: file).records().first)
        XCTAssertEqual(record.targetID, "B"); XCTAssertEqual(record.instruction, "continue this")
        XCTAssertEqual(record.paneID, "%17"); XCTAssertNil(record.sessionID)
    }
    func testManagerCannotConsumeAnUnresolvedHandoffForAnotherAccount() {
        var tray = AttachmentTray()
        tray.stage("private handoff", session: "launch:account-b")
        tray.stage("file", session: "a")
        XCTAssertEqual(tray.snapshotAll(into: "a", utteranceId: "u"), ["file"])
        XCTAssertEqual(tray.staged(for: "launch:account-b"), ["private handoff"])
    }

    func testProfilePathIsAShellLiteralAndAuthOverridesAreRemoved() {
        let account = SavedAccount(label: "A", configDirectory: root.appendingPathComponent("don't $(touch wrong)").path)
        let command = account.scopedCommand("/usr/bin/true")
        XCTAssertTrue(command.contains("'\\''"))
        for variable in SavedAccount.authenticationOverrides { XCTAssertTrue(command.contains("-u " + variable)) }
    }

    func testResumeUsesDurableAccountAndRefusesMissingOrDuplicateOrigin() throws {
        let accounts = SavedAccountStore(fileURL: root.appendingPathComponent("accounts.json"))
        let bindings = SessionAccountStore(fileURL: root.appendingPathComponent("bindings.json"))
        let a = SavedAccount(label: "A", configDirectory: root.appendingPathComponent("A").path)
        let b = SavedAccount(label: "B", configDirectory: root.appendingPathComponent("B").path)
        try accounts.save(a); try accounts.save(b)
        let id = UUID().uuidString.lowercased()
        try bindings.bind(id, targetID: b.id, root: b.root)
        let resumed = HarnessLaunch.forExistingSession(id, accounts: accounts, bindings: bindings)
        XCTAssertEqual(resumed.account?.id, b.id)
        XCTAssertEqual(resumed.adapter.id, ClaudeCodeAdapter().id)
        for account in [a, b] {
            let project = account.projects.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent(id + ".jsonl"))
        }
        XCTAssertNotNil(HarnessLaunch.forExistingSession(id, accounts: accounts, bindings: bindings).resolutionError)
        try JSONEncoder().encode([a]).write(to: accounts.fileURL)
        XCTAssertNotNil(HarnessLaunch.forExistingSession(id, accounts: accounts, bindings: bindings).resolutionError)
    }

    func testMalformedDuplicateRegistryIsUnknownAndCannotBeOverwritten() throws {
        let accounts = SavedAccountStore(fileURL: root.appendingPathComponent("accounts.json"))
        let a = SavedAccount(label: "A", configDirectory: root.appendingPathComponent("A").path)
        try JSONEncoder().encode([a, a]).write(to: accounts.fileURL)
        XCTAssertFalse(accounts.isReadable)
        XCTAssertThrowsError(try accounts.save(a))
        XCTAssertEqual(try JSONDecoder().decode([SavedAccount].self, from: Data(contentsOf: accounts.fileURL)).count, 2)
    }

    func testCorruptRecoveryTrayIsRetainedAndBlocksDispatch() throws {
        let file = root.appendingPathComponent("tray.json")
        try Data("broken".utf8).write(to: file)
        let tray = AttachmentStore(fileURL: file)
        XCTAssertNotNil(tray.persistenceError)
        tray.stage("new draft", session: "s")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }

    func testLegacyWrapperUsesObservedAccountButStillRequiresExactLaunchedPane() {
        var record = LaunchRecoveryRecord(id: "legacy", targetID: "claude-code", directory: "/same", enforcesAccount: false)
        record.paneID = "%1"; record.paneSession = "tb-legacy"
        var session = LiveSession(pid: 7, sessionId: "b", cwd: "/same", status: nil, name: nil, waitingFor: nil)
        session.accountTargetID = "account-b"; session.registryTmux = "tb-legacy:@1.%1"
        XCTAssertTrue(LaunchRecoveryStore.matches(session, record: record))
        session.registryTmux = "tb-other:@1.%1"
        XCTAssertFalse(LaunchRecoveryStore.matches(session, record: record))
    }

}
