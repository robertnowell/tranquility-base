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
/// Service/auth failures use the free floor. A Mac not on credits, or one
/// whose credits are exhausted, may use its pasted key (15 September ruling).
/// The standing explains exhaustion; it is not a second sign-in requirement.
public enum ManagedCredits {

    /// Shared by the app and the isolated onboarding drill. Notification
    /// payloads contain no credentials; the session reads its identity itself.
    public static func observeIdentityChanges(_ session: ManagedCreditSession,
                                              center: NotificationCenter = .default) -> NSObjectProtocol {
        center.addObserver(forName: Secrets.hubIdentityDidChange, object: nil, queue: nil) { _ in
            Task { await session.refresh() }
        }
    }

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

    /// Created even before sign-in. Each operation resolves the current app
    /// session; pairing never requires replacing the Coordinator or restarting.
    public static func session(
        identity: @escaping ManagedCreditSession.IdentitySource = {
            guard let hub = HubApp.baseURL, let token = Secrets.read(.hubToken), !token.isEmpty else { return nil }
            return .init(hub: hub, token: token)
        },
        outboxURL: URL = QueueStore.supportDirectory.appendingPathComponent("managed-outbox.sqlite"),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> ManagedCreditSession {
        ManagedCreditSession(identity: identity, outboxURL: outboxURL) { current, valid in
            guard let signer = deviceSigner(log: log) else {
                throw ManagedSummaryFailure.refused(code: "service_unavailable", operationId: nil)
            }
            let tokenURL = current.hub.appendingPathComponent("api/gateway/token")
            let authority = GatewayAuthority(
                signer: signer, hubBase: current.hub,
                deviceToken: { valid() ? current.token : nil },
                exchange: GatewayAuthority.httpExchange(tokenURL: tokenURL))
            let transport = try GatewayHTTPTransport(base: gatewayURL) { method, url in
                guard valid() else { throw CancellationError() }
                let credential = try await authority.credential(method: method, url: url)
                guard valid() else { throw CancellationError() }
                return credential
            }
            log("credits: managed session at \(gatewayURL.host ?? "?") as \(signer.storage)")
            return .init(transport: transport, invalidate: { await authority.clear() })
        }
    }
}
