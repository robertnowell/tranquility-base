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
                                secret: (Secrets.Key) -> String? = { Secrets.read($0) })
        -> AgentProviderRegistry {
        var built: [any AgentProvider] = []

        if let base = ProviderConfig.baseURL("opencode", config: config) {
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

        return AgentProviderRegistry(built)
    }
}
