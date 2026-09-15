import XCTest
@testable import TranquilityCore

/// A provider's address is read from the same config file as the hub's, and
/// the rule that matters is the one `HubApp` already holds: absent means "not
/// connected", never an error. A checklist row that reads red on a machine
/// which has simply never heard of a provider is worse than no row.
final class ProviderConfigTests: XCTestCase {

    private var dir: URL!
    private var config: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("provider-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        config = dir.appendingPathComponent("hq.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws {
        try json.write(to: config, atomically: true, encoding: .utf8)
    }

    // MARK: - Absent is not an error

    func testNoConfigFileAtAllReadsAsNotConnected() {
        XCTAssertNil(ProviderConfig.baseURL("crobot", config: config))
        XCTAssertEqual(ProviderConfig.configured(config: config), [])
    }

    func testAConfigWithNoProvidersBlockReadsAsNotConnected() throws {
        try write(#"{"app": {"base_url": "https://hq.example.test"}}"#)
        XCTAssertNil(ProviderConfig.baseURL("crobot", config: config))
        XCTAssertEqual(ProviderConfig.configured(config: config), [])
    }

    func testAnUnknownProviderIsNilRatherThanAFailure() throws {
        try write(#"{"providers": {"crobot": {"base_url": "https://crobot.example.test"}}}"#)
        XCTAssertNil(ProviderConfig.baseURL("opencode", config: config))
    }

    func testUnparseableConfigReadsAsNotConnectedRatherThanThrowing() throws {
        try write("{ this is not json")
        XCTAssertNil(ProviderConfig.baseURL("crobot", config: config))
        XCTAssertEqual(ProviderConfig.configured(config: config), [])
    }

    // MARK: - Reading

    func testReadsABaseURLAndTrimsTheTrailingSlash() throws {
        try write(#"{"providers": {"crobot": {"base_url": "https://crobot.example.test/"}}}"#)
        XCTAssertEqual(ProviderConfig.baseURL("crobot", config: config)?.absoluteString,
                       "https://crobot.example.test")
    }

    /// Local OpenCode is genuinely `http://127.0.0.1`, so http cannot be
    /// refused the way the hub's own reader can afford to prefer https.
    func testPlainHTTPIsAcceptedBecauseLocalOpenCodeIsPlainHTTP() throws {
        try write(#"{"providers": {"opencode": {"base_url": "http://127.0.0.1:4096"}}}"#)
        XCTAssertEqual(ProviderConfig.baseURL("opencode", config: config)?.absoluteString,
                       "http://127.0.0.1:4096")
    }

    /// A pasted address that is not an address builds a request which fails
    /// somewhere far from here, and gets reported as the provider being down.
    func testAnAddressWithNoSchemeOrTheWrongSchemeIsRefusedHere() throws {
        try write(#"{"providers": {"a": {"base_url": "crobot.example.test"}, "b": {"base_url": "file:///etc/passwd"}, "c": {"base_url": "   "}}}"#)
        XCTAssertNil(ProviderConfig.baseURL("a", config: config))
        XCTAssertNil(ProviderConfig.baseURL("b", config: config))
        XCTAssertNil(ProviderConfig.baseURL("c", config: config))
        XCTAssertEqual(ProviderConfig.configured(config: config), [])
    }

    func testConfiguredListsOnlyProvidersWithAUsableAddress() throws {
        try write(#"{"providers": {"crobot": {"base_url": "https://crobot.example.test"}, "opencode": {"base_url": "http://127.0.0.1:4096"}, "broken": {"base_url": "nonsense"}, "empty": {}}}"#)
        XCTAssertEqual(ProviderConfig.configured(config: config), ["crobot", "opencode"])
    }

    // MARK: - Writing

    /// hq.json is not this app's file. The page-writing skills read it, the
    /// indexer reads it, and `HubApp` writes one key in it.
    func testWritingOneProviderLeavesEveryOtherKeyAlone() throws {
        try write(#"{"app": {"base_url": "https://hq.example.test"}, "roots": {"agents": "~/Documents/agents"}, "providers": {"opencode": {"base_url": "http://127.0.0.1:4096", "note": "mine"}}}"#)
        try ProviderConfig.setBaseURL(URL(string: "https://crobot.example.test/")!,
                                      for: "crobot", config: config)

        let obj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: config)) as? [String: Any]
        let app = obj?["app"] as? [String: Any]
        XCTAssertEqual(app?["base_url"] as? String, "https://hq.example.test")
        XCTAssertNotNil(obj?["roots"])

        let providers = obj?["providers"] as? [String: Any]
        let opencode = providers?["opencode"] as? [String: Any]
        XCTAssertEqual(opencode?["base_url"] as? String, "http://127.0.0.1:4096")
        XCTAssertEqual(opencode?["note"] as? String, "mine", "a sibling provider's own keys survive")
        XCTAssertEqual(ProviderConfig.baseURL("crobot", config: config)?.absoluteString,
                       "https://crobot.example.test")
    }

    func testWritingIntoAMachineWithNoConfigYetCreatesOne() throws {
        try ProviderConfig.setBaseURL(URL(string: "https://crobot.example.test")!,
                                      for: "crobot", config: config)
        XCTAssertEqual(ProviderConfig.configured(config: config), ["crobot"])
    }

    // MARK: - The credential mapping

    /// One place, so a checklist row, a key check and an adapter cannot
    /// disagree about which secret a provider uses.
    func testAProviderResolvesToExactlyOneCredential() {
        XCTAssertEqual(Secrets.credential(forProvider: "crobot"), .crobotAPIKey)
        XCTAssertEqual(Secrets.credential(forProvider: "opencode"), .openCodePassword)
        XCTAssertNil(Secrets.credential(forProvider: "nobody"))
    }

    /// #326's root cause, pinned: `Prerequisites.Item` is hand-written and does
    /// NOT derive from `Secrets.Key.allCases`, so a credential added to the key
    /// enum can be perfectly usable everywhere except the one screen where a
    /// person types it in. The OpenAI key sat in that state for weeks.
    func testEveryPastableCredentialHasARowToTypeItIn() {
        let rows = Prerequisites.items(harnesses: [], providers: ["crobot", "opencode"])
        let reachable = Set(rows.compactMap(\.secret))
        for key in Secrets.Key.allCases where key.isPasted {
            // Keys nobody types are excluded by `isPasted` on the key itself,
            // not by a list here: the hub mints its token and this Mac makes
            // its own device key, so neither has anything for a person to do.
            // Declaring it there means the next key added answers the question
            // instead of quietly inheriting an exception.
            XCTAssertTrue(reachable.contains(key),
                          "\(key.rawValue) can be stored but not entered: it has no checklist row")
        }
    }

    /// The rows a caller gets by default must not depend on what is on this
    /// machine's disk. They did, until 13 Sep: `items()` defaulted `providers`
    /// to the live `hq.json` while `snapshot` defaulted its probe to empty, so
    /// the two disagreed about how many rows exist the moment a provider was
    /// actually configured, and every test looking a row up in the snapshot
    /// crashed on a nil.
    ///
    /// CI could not have caught it. CI has no configured provider, so the two
    /// defaults agreed there and diverged only on a machine that had finished
    /// the very setup this code exists to support.
    func testTheDefaultRowSetDoesNotDependOnThisMachinesDisk() {
        let byDefault = Prerequisites.items(harnesses: []).map(\.id)
        XCTAssertFalse(byDefault.contains { $0.hasPrefix("provider.") },
                       "items() read the real hq.json: \(byDefault)")
        XCTAssertEqual(
            byDefault,
            Prerequisites.snapshot(Prerequisites.Probes(
                tmuxPath: { nil }, hooksProblem: { _ in nil },
                hasSecret: { _ in false }, harnesses: { [] })).map(\.item.id),
            "items() and snapshot() must agree about which rows exist")
    }

    func testAProviderRowAppearsOnlyOnceTheMachineHasAnAddressForIt() {
        XCTAssertFalse(Prerequisites.items(harnesses: [], providers: [])
            .contains { $0.id == "provider.crobot" })
        XCTAssertTrue(Prerequisites.items(harnesses: [], providers: ["crobot"])
            .contains { $0.id == "provider.crobot" })
    }

    /// A row whose fix button cannot do anything is worse than no row: it
    /// looks like a thing you can fix. `promptForKey` guards on `item.secret`
    /// and returns silently when it is nil.
    func testAProviderWithNoKnownCredentialGetsNoRowAtAll() {
        let rows = Prerequisites.items(harnesses: [],
                                       providers: ["crobot", "some-future-thing"])
        XCTAssertTrue(rows.contains { $0.id == "provider.crobot" })
        XCTAssertFalse(rows.contains { $0.id == "provider.some-future-thing" },
                       "a row with no credential renders a button that does nothing")
        for row in rows where row.id.hasPrefix("provider.") {
            XCTAssertNotNil(row.secret, "\(row.id) offers Paste key with nothing to paste into")
        }
    }

    /// The setup checklist must not read the machine's real config through a
    /// defaulted argument. `Probes` exists to stop exactly that, and it was
    /// bypassed for the provider rows until 13 Sep.
    func testTheChecklistReadsProvidersFromItsProbesAndNotFromDisk() {
        let probes = Prerequisites.Probes(
            tmuxPath: { "/usr/bin/tmux" }, hooksProblem: { _ in nil },
            hasSecret: { _ in false }, harnesses: { [] },
            providers: { ["crobot"] })
        let rows = Prerequisites.snapshot(probes).map(\.item.id)
        XCTAssertTrue(rows.contains("provider.crobot"),
                      "the probe's providers never reached the rows")

        let none = Prerequisites.Probes(
            tmuxPath: { "/usr/bin/tmux" }, hooksProblem: { _ in nil },
            hasSecret: { _ in false }, harnesses: { [] })
        XCTAssertFalse(Prerequisites.snapshot(none).contains { $0.item.id.hasPrefix("provider.") },
                       "a Probes with no providers produced provider rows, so something "
                           + "read the real hq.json")
    }

    func testAProviderRowSurvivesTheRoundTripThroughItsIdentifier() {
        let item = Prerequisites.Item.provider(id: "crobot")
        XCTAssertEqual(item.id, "provider.crobot")
        XCTAssertEqual(Prerequisites.Item(id: item.id), item)
        XCTAssertEqual(item.title, "crobot")
        XCTAssertEqual(item.secret, .crobotAPIKey)
        XCTAssertFalse(item.isRequired)
    }
}
