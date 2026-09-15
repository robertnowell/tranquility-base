import Foundation

/// The managed path, assembled from what this Mac already holds.
///
/// Nothing here asks the person for anything. A Mac that is connected to a
/// hub has a device token; a Mac connected since key binding has a device
/// key; from those two the app mints authority silently and spends against
/// the Gateway. A Mac that has neither summarises the way it always did.
/// AUTHORIZATION.md is the requirement: one sign-in, no second login, and an
/// outage is never shown as being signed out.
///
/// The provider order is not a fallback chain. A failure of the credits path
/// lands on the deterministic floor, never on a pasted key: the floor is free
/// and honest, and a person who is on credits must not be silently moved onto
/// their own bill. The one exception is a Mac the hub says is not on credits
/// at all, paired before key binding; that Mac keeps whatever it had.
public enum ManagedCredits {

    /// The Gateway this build spends at. `gateway.base_url` in hq.json when
    /// it says, else the one built in. Same file and same rule as the hub's
    /// own address: one place, never a link's idea of where money goes.
    public static let builtInGateway =
        URL(string: "https://tranquility-gateway-425196748976.us-west1.run.app")!

    public static var gatewayURL: URL { gatewayURL(config: HubApp.configPath) }

    static func gatewayURL(config: URL) -> URL {
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = obj["gateway"] as? [String: Any],
              let raw = gateway["base_url"] as? String,
              let url = URL(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))),
              url.scheme == "https"
        else { return builtInGateway }
        return url
    }

    /// This installation's identity in a summary's source, made once and kept.
    ///
    /// The Gateway keys an operation on (origin, session, turn), so the same
    /// turn asked twice is one charge. The origin therefore has to survive
    /// upgrades and relaunches, and belong to the installation that produced
    /// the event rather than the Mac that happens to be viewing it.
    public static func originId(
        at url: URL = QueueStore.supportDirectory.appendingPathComponent("origin-id")
    ) -> UUID? {
        if let stored = try? String(contentsOf: url, encoding: .utf8),
           let id = UUID(uuidString: stored.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id
        }
        let fresh = UUID()
        do {
            try PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
            try fresh.uuidString.lowercased().write(to: url, atomically: true, encoding: .utf8)
            PrivateStorage.protect(url)
        } catch {
            return nil
        }
        return fresh
    }

    /// The key this Mac proves itself with, made on first use.
    ///
    /// Made at pairing, so the hub can record its thumbprint, and reused on
    /// every request afterwards. Logs which guarantee it got: the enclave, or
    /// the software file the 2019 iMac has to settle for.
    public static func deviceSigner(log: (String) -> Void = { _ in }) -> DeviceKey.Signer? {
        do {
            let resolved = try DeviceKeyStore.resolve()
            if resolved.created {
                log("credits: device key made in \(resolved.signer.storage)")
            }
            return resolved.signer
        } catch {
            log("credits: no device key: \(error)")
            return nil
        }
    }

    /// The summariser that spends, or nil when this Mac cannot.
    ///
    /// Nil is the ordinary state for a Mac that is not connected to a hub, and
    /// the caller falls back to the chain it always used. A connected Mac that
    /// was paired before key binding gets a summariser that will be told
    /// `rebindingRequired` on first use and land on the floor; that is
    /// reported where the failure is, not guessed here.
    public static func summarizer(
        hubBase: URL?,
        deviceToken: @escaping @Sendable () -> String? = { Secrets.read(.hubToken) },
        outboxURL: URL = QueueStore.supportDirectory.appendingPathComponent("managed-outbox.sqlite"),
        log: (String) -> Void = { _ in }
    ) -> SummarizerChain? {
        guard let hubBase, let token = deviceToken(), !token.isEmpty else { return nil }
        guard let signer = deviceSigner(log: log) else { return nil }
        let tokenURL = hubBase.appendingPathComponent("api/gateway/token")
        let authority = GatewayAuthority(
            signer: signer, hubBase: hubBase, deviceToken: deviceToken,
            exchange: GatewayAuthority.httpExchange(tokenURL: tokenURL))
        do {
            let transport = try GatewayHTTPTransport(base: gatewayURL) { method, url in
                try await authority.credential(method: method, url: url)
            }
            let outbox = try ManagedSummaryOutbox(url: outboxURL)
            log("credits: managed summaries at \(gatewayURL.host ?? "?") as \(signer.storage)")
            CreditStanding.set(.onCredits)
            // Managed first. A pasted key follows ONLY for a Mac the hub says
            // is not on credits yet (see SummarizerChain); a failure of the
            // credits path itself lands on the floor.
            return SummarizerChain(providers: [
                ManagedSummaryProvider(transport: transport, outbox: outbox),
                AnthropicSummaryProvider(),
                DeterministicSummarizer(),
            ])
        } catch {
            log("credits: managed path unavailable: \(error)")
            return nil
        }
    }
}
