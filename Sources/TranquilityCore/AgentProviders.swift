import Foundation

/// Every provider this build can drive, and the ones this machine actually has.
///
/// **The one place a provider is named.** Adding a fifth agent is a line here
/// plus its own file, which is the acceptance test the whole epic was written
/// against (#366). Everything downstream reads the registry, never a list of
/// its own.
public enum AgentProviders {

    /// Built for this machine, or an empty registry when nothing is
    /// configured. Absent means not connected, never an error.
    ///
    /// A provider appears only when `hq.json` carries a base URL for it,
    /// which is the same rule `Prerequisites.Item.provider` follows: telling
    /// somebody their crobot credential is missing on a machine that has never
    /// heard of crobot is what `Harness.isPresent` has always existed to
    /// prevent.
    /// `secret` is injectable for the reason this codebase has now learned
    /// three times in one day: a default that reads the machine makes every
    /// test depend on what happens to be installed on it, and the divergence
    /// appears only once somebody has finished the setup the code exists to
    /// support. `Prerequisites.items`, `AgentPoller.registryConfig`, and now
    /// this.
    public static func registry(config: URL = HubApp.configPath,
                                session: URLSession = .shared,
                                secret: (Secrets.Key) -> String? = { Secrets.read($0) },
                                ledger: ProviderLedger = .standard)
        -> AgentProviderRegistry {
        var built: [any AgentProvider] = []

        // **One vendor, one route** (#412, revised 15 Sep): an agent this
        // machine can spawn is driven over the protocol, owned by this app the
        // way a Claude Code pane is. Every installed catalog entry becomes a
        // provider here; none of them runs a process until something is
        // started on it (`ACPProvider.connectIfNeeded`), so listing them at
        // launch is free. The workspace is where a new agent starts (#446).
        for (entry, command) in installedACP() {
            // The directory the Settings pane holds for this agent, or the
            // workspace: the same setting a terminal harness launches into,
            // read the same way (#471). Fixed for the life of the process,
            // which is the child's cwd and the list's filter.
            let workspace = AgentDefaults.directory(for: entry.id)
            // OPENCODE IS SERVED, NOT PIPED (revised 15 Sep 9:11 PM). The
            // pipe could drive it but not share it: a permission asked over
            // the pipe was invisible to the terminal opened on the session.
            // `opencode serve` is one session seen from two places, and Go to
            // Agent raises the TUI already attached to it in a pane of ours
            // (attached from the start, since a late attach never shows a
            // pending ask). See ServedOpenCodeProvider and OpenCodePane.
            if entry.id == "opencode" {
                built.append(ServedOpenCodeProvider(
                    binary: command[0], directory: workspace, ledger: ledger,
                    pidFile: QueueStore.supportDirectory.appendingPathComponent("opencode-serve.pid"),
                    hostsPanes: true,
                    trace: { Failures.trace?($0) }))
                continue
            }
            let transport = ACPProcessTransport(command: command, cwd: workspace)
            let binary = command[0]
            built.append(ACPProvider(id: entry.id,
                                     client: ACPClient(transport: transport),
                                     cwd: workspace,
                                     start: { try transport.start() },
                                     ledger: ledger,
                                     open: { entry.openLine(session: $0, binary: binary) }))
        }
        let spawnable = Set(built.map(\.id))

        // The HTTP route adopts an `opencode serve` somebody else runs. It is
        // built only when this machine cannot spawn OpenCode itself, because
        // two providers under one id would send a reply to whichever the
        // registry found first (`RemoteDispatchTransport` resolves by id).
        if !spawnable.contains("opencode"),
           let base = ProviderConfig.baseURL("opencode", config: config) {
            built.append(LocalOpenCodeProvider(client: OpenCodeClient(
                transport: HTTPTransport(base: base,
                                         password: secret(.openCodePassword),
                                         session: session,
                                         trace: { Failures.trace?($0) }),
                provider: "opencode")))
        }

        if let base = ProviderConfig.baseURL("crobot", config: config),
           let key = secret(.crobotAPIKey) {
            // crobot needs BOTH. A base URL with no key authenticates nothing
            // and would put a row on the panel that 401s on every poll, which
            // reads as the agent being broken rather than as setup being
            // unfinished.
            built.append(CrobotProvider(
                transport: CrobotHTTPTransport(base: base, key: key, session: session),
                me: nil))
        }

        return AgentProviderRegistry(built, spawnable: spawnable)
    }

    /// Injectable for tests, which must not depend on what this Mac has
    /// installed: the class of failure recorded three times on 14 Sep.
    nonisolated(unsafe) public static var installedACP: () -> [(entry: ACPCatalog.Entry, command: [String])]
        = { ACPCatalog.installed() }
}
