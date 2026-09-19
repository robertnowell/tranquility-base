import Foundation
import GRDB

/// Explicitly supplied transport: managed code never reads personal provider keys.
public protocol GatewayTransport: Sendable {
    func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data)
}

private final class GatewayRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // never forward a spending credential to another route/origin
    }
}

/// The headers one Gateway request carries. Produced per request because the
/// proof is made for exactly this method and URL, and the token behind it may
/// have been refreshed since the last one.
public typealias GatewayCredential = @Sendable (_ method: String, _ url: String)
    async throws -> GatewayAuthority.Credential

public final class GatewayHTTPTransport: GatewayTransport, Sendable {
    private let base: URL
    private let credential: GatewayCredential
    private let session: URLSession
    public init(base: URL, allowLoopbackFixture: Bool = false,
                credential: @escaping GatewayCredential) throws {
        guard base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.path.isEmpty || base.path == "/",
              base.host != nil,
              base.scheme == "https" || (allowLoopbackFixture && base.scheme == "http" && base.host == "127.0.0.1")
        else { throw ManagedSummaryFailure.invalidResponse }
        self.base = base; self.credential = credential
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config, delegate: GatewayRedirectGuard(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
        guard path.hasPrefix("/v1/"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host == base.host, url.scheme == base.scheme, url.port == base.port
        else { throw ManagedSummaryFailure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        // DPoP, never Bearer: the verifier refuses a bound token presented as
        // a bearer token (RFC 9449 section 7.2), and there is no mode in which
        // both work. The proof is over the URL as the Gateway will rebuild it
        // from its configured origin, which is this absolute URL exactly.
        let presented: GatewayAuthority.Credential
        do { presented = try await credential(method, url.absoluteString) }
        catch let failure as GatewayAuthority.Failure {
            // Nothing was sent, so nothing is unknown: this is a refusal with
            // a name, and the chain reads the name. Two of them mean "this Mac
            // is not on credits" rather than "credits failed".
            throw ManagedSummaryFailure.refused(code: failure.code, operationId: nil)
        }
        request.setValue(presented.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(presented.proof, forHTTPHeaderField: "DPoP")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 262144, let http = response as? HTTPURLResponse
        else { throw ManagedSummaryFailure.invalidResponse }
        return (http.statusCode, data)
    }
}

/// Separate FULL-synchronous outbox: financial replay cannot depend on the
/// best-effort event/brief cache. Requests/results are private data, not logs.
public final class ManagedSummaryOutbox: Sendable {
    private let db: DatabaseQueue
    public init(url: URL) throws {
        try PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        db = try DatabaseQueue(path: url.path, configuration: config)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS managed_summary_outbox (
                    accountId TEXT NOT NULL, operationId TEXT NOT NULL,
                    request BLOB NOT NULL, result BLOB,
                    PRIMARY KEY(accountId, operationId)
                )
                """)
        }
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            PrivateStorage.protect(URL(fileURLWithPath: path))
        }
    }

    struct Entry: Sendable { let request: Data; let result: Data?; let isNew: Bool }
    func prepare(account: String, id: String, request: Data) throws -> Entry {
        try db.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT request,result FROM managed_summary_outbox WHERE accountId=? AND operationId=?", arguments: [account,id]) {
                // The first prepared request wins, including after a restart.
                return Entry(request: row["request"], result: row["result"], isNew: false)
            }
            try db.execute(sql: "INSERT INTO managed_summary_outbox(accountId,operationId,request) VALUES(?,?,?)", arguments: [account,id,request])
            return Entry(request: request, result: nil, isNew: true)
        }
    }
    func save(account: String, id: String, result: Data) throws {
        try db.write { db in
            // Pending replies arriving after a terminal one cannot erase it.
            // Callers only save validated terminal operations.
            if let old = try Data.fetchOne(db, sql: "SELECT result FROM managed_summary_outbox WHERE accountId=? AND operationId=?", arguments: [account,id]) {
                let a = try JSONDecoder().decode(GatewayOperation.self, from: old)
                let b = try JSONDecoder().decode(GatewayOperation.self, from: result)
                guard a == b else { throw ManagedSummaryFailure.invalidResponse }
            } else {
                try db.execute(sql: "UPDATE managed_summary_outbox SET result=? WHERE accountId=? AND operationId=?", arguments: [result,account,id])
            }
        }
    }
}

public struct ManagedSummaryClient: Sendable {
    public let accountId: UUID
    public let transport: any GatewayTransport
    public let outbox: ManagedSummaryOutbox
    public init(accountId: UUID, transport: any GatewayTransport, outbox: ManagedSummaryOutbox) {
        self.accountId = accountId; self.transport = transport; self.outbox = outbox
    }

    public static func connect(transport: any GatewayTransport) async throws -> GatewayAccount {
        let response = try await transport.request(method: "POST", path: "/v1/account", body: nil)
        try requireSuccess(response.status, response.body, operationId: nil)
        let account = try JSONDecoder().decode(GatewayAccount.self, from: response.body)
        guard account.version == "1", account.currency == "USD", account.balance.isValid,
              UUID(uuidString: account.accountId) != nil else { throw ManagedSummaryFailure.invalidResponse }
        return account
    }

    public func balance() async throws -> GatewayBalance {
        let response = try await transport.request(method: "GET", path: "/v1/accounts/\(accountId.uuidString.lowercased())/balance", body: nil)
        try Self.requireSuccess(response.status, response.body, operationId: nil)
        let balance = try JSONDecoder().decode(GatewayBalance.self, from: response.body)
        guard balance.isValid else { throw ManagedSummaryFailure.invalidResponse }
        return balance
    }

    public func summarize(source: GatewaySource, request: SummaryRequest) async throws -> GatewayOperation {
        try await result(source: source, request: request).operation
    }

    func result(source: GatewaySource, request: SummaryRequest) async throws -> (operation: GatewayOperation, replayed: Bool) {
        guard request.correctiveNote == nil else { throw ManagedSummaryFailure.correctiveRetryNotAllowed }
        let account = accountId.uuidString.lowercased()
        let id = source.operationId(accountId: accountId)
        let payload = try GatewayContract.encode(GatewaySummaryRequest(source: source, input: GatewaySummaryInput(request)))
        guard payload.count <= 131072 else { throw ManagedSummaryFailure.refused(code: "invalid_request", operationId: id) }
        let entry = try outbox.prepare(account: account, id: id, request: payload)
        if let result = entry.result { return (try decode(result, id: id), true) }
        try Task.checkCancellation()
        let path = "/v1/accounts/\(account)/summaries/\(id)"
        do {
            // An existing outbox entry may already have succeeded remotely.
            // GET never invokes a provider. Only 404 permits same-key PUT.
            if !entry.isNew {
                let found = try await transport.request(method: "GET", path: path, body: nil)
                if found.status != 404 { return (try accept(found, id: id), true) }
            }
            try Task.checkCancellation()
            return (try accept(await transport.request(method: "PUT", path: path, body: entry.request), id: id), !entry.isNew)
        } catch let error as ManagedSummaryFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ManagedSummaryFailure.outcomeUnknown(operationId: id) }
    }

    private func decode(_ data: Data, id: String) throws -> GatewayOperation {
        do {
            let op = try JSONDecoder().decode(GatewayOperation.self, from: data)
            try op.validate(account: accountId.uuidString.lowercased(), operation: id)
            return op
        } catch { throw ManagedSummaryFailure.invalidResponse }
    }
    private func accept(_ response: (status: Int, body: Data), id: String) throws -> GatewayOperation {
        try Self.requireSuccess(response.status, response.body, operationId: id)
        let op = try decode(response.body, id: id)
        guard (response.status == 200) == op.state.isTerminal else { throw ManagedSummaryFailure.invalidResponse }
        if op.state.isTerminal { try outbox.save(account: accountId.uuidString.lowercased(), id: id, result: response.body) }
        return op
    }
    private static func requireSuccess(_ status: Int, _ data: Data, operationId: String?) throws {
        guard status != 200 && status != 202 else { return }
        struct Envelope: Decodable { let error: GatewayOperation.ServiceError }
        let code = (try? JSONDecoder().decode(Envelope.self, from: data))?.error.code ?? "service_unavailable"
        throw ManagedSummaryFailure.refused(code: code, operationId: operationId)
    }
}

/// The account this Mac spends from, resolved once and remembered.
///
/// `POST /v1/account` is the call that creates the personal account and lands
/// the welcome grant, and it is idempotent, so asking on first use rather than
/// at launch costs nothing and keeps a network call off the launch path.
/// Coalesced so ten first summaries produce one request.
public actor ManagedAccount {
    private let transport: any GatewayTransport
    private var resolved: UUID?
    private var inFlight: Task<UUID, Error>?

    public init(transport: any GatewayTransport) { self.transport = transport }

    public func id() async throws -> UUID {
        if let resolved { return resolved }
        if let inFlight { return try await inFlight.value }
        let task = Task { () throws -> UUID in
            let account = try await ManagedSummaryClient.connect(transport: transport)
            guard let id = UUID(uuidString: account.accountId) else { throw ManagedSummaryFailure.invalidResponse }
            return id
        }
        inFlight = task
        defer { inFlight = nil }
        let id = try await task.value
        resolved = id
        return id
    }
}

public struct ManagedSummaryProvider: SummaryProvider {
    public let name = "tranquility-gateway"
    public let isConfigured = true
    public let usesManagedCredits = true

    private enum Source: Sendable {
        case fixed(ManagedSummaryClient)
        case resolved(ManagedAccount, any GatewayTransport, ManagedSummaryOutbox)
    }
    private let source: Source

    /// A client with its account already known. Tests, and any caller that
    /// connected up front.
    public init(client: ManagedSummaryClient) { self.source = .fixed(client) }

    /// The app's shape: the account is asked for on the first summary.
    public init(transport: any GatewayTransport, outbox: ManagedSummaryOutbox) {
        self.source = .resolved(ManagedAccount(transport: transport), transport, outbox)
    }

    private func client() async throws -> ManagedSummaryClient {
        switch source {
        case let .fixed(client): return client
        case let .resolved(account, transport, outbox):
            return ManagedSummaryClient(accountId: try await account.id(), transport: transport, outbox: outbox)
        }
    }

    public func brief(for request: SummaryRequest) async throws -> SessionBrief {
        try await delivery(for: request).brief
    }
    public func delivery(for request: SummaryRequest) async throws -> SummaryDelivery {
        guard let source = request.managedSource else { throw ManagedSummaryFailure.missingSourceIdentity }
        let result = try await client().result(source: source, request: request)
        let op = result.operation
        switch op.state {
        case .succeeded:
            guard let brief = op.brief, let receipt = op.receipt else { throw ManagedSummaryFailure.invalidResponse }
            return SummaryDelivery(brief: brief, receipt: receipt, receiptWasReplayed: result.replayed)
        case .admitted, .running, .reconciling:
            throw ManagedSummaryFailure.pending(operationId: op.operationId, state: op.state)
        case .failed, .cancelled:
            throw ManagedSummaryFailure.refused(code: op.error?.code ?? "cancelled", operationId: op.operationId)
        }
    }
}
