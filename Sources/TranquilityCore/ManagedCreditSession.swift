import Foundation

/// One local sign-in owns its authority, account resolver and credit display.
/// Connections are bound to an immutable identity, never a token read midway
/// through an operation. Old operations may settle into their own outbox;
/// they cannot spend as the next user or publish that user's standing.
public actor ManagedCreditSession: SummaryProvider {
    public nonisolated let name = "tranquility-gateway"
    public nonisolated let isConfigured = true
    public nonisolated let usesManagedCredits = true

    public struct Identity: Sendable, Equatable {
        public let hub: URL
        public let token: String
        public init(hub: URL, token: String) { self.hub = hub; self.token = token }
    }

    public struct Connection: Sendable {
        public let transport: any GatewayTransport
        public let invalidate: @Sendable () async -> Void
        public init(transport: any GatewayTransport,
                    invalidate: @escaping @Sendable () async -> Void = {}) {
            self.transport = transport; self.invalidate = invalidate
        }
    }

    public typealias IdentitySource = @Sendable () -> Identity?
    public typealias Connect = @Sendable (Identity, @escaping @Sendable () -> Bool) throws -> Connection
    private struct Context: Sendable {
        let id: UUID
        let identity: Identity
        let connection: Connection
        let account: ManagedAccount
        let outbox: ManagedSummaryOutbox
    }
    private let identity: IdentitySource
    private let connect: Connect
    private let outboxURL: URL
    private let publish: @Sendable (CreditStanding, @escaping @Sendable () -> Bool) -> Void
    private var context: Context?
    private var standing: CreditStanding = .notOnCredits(connectAgain: false)
    private var sequence: Int64 = -1
    private var nextTicket: UInt64 = 0
    private var statusTicket: UInt64 = 0

    public init(identity: @escaping IdentitySource, outboxURL: URL,
                connect: @escaping Connect,
                publish: (@Sendable (CreditStanding, @escaping @Sendable () -> Bool) -> Void)? = nil) {
        self.identity = identity; self.outboxURL = outboxURL
        self.connect = connect; self.publish = publish ?? { CreditStanding.set($0, isCurrent: $1) }
    }

    /// Called at launch and after pairing/sign-out. No provider call, no debit.
    /// Also exercised on every summary, so an external credential replacement
    /// cannot leave this process using a cached account.
    public func refresh() async {
        let ticket = ticket()
        do {
            let ctx = try currentContext()
            do {
                let client = try await client(ctx)
                try await updateBalance(client, context: ctx, ticket: ticket, mayRecover: false)
            } catch { record(error, context: ctx, ticket: ticket) }
        } catch { recordPreparation(error) }
    }

    public func brief(for request: SummaryRequest) async throws -> SessionBrief {
        try await delivery(for: request).brief
    }

    public func delivery(for request: SummaryRequest) async throws -> SummaryDelivery {
        let ticket = ticket()
        let ctx: Context
        do { ctx = try currentContext() }
        catch { recordPreparation(error); throw error }
        do {
            let client = try await client(ctx)
            let result = try await ManagedSummaryProvider(client: client).delivery(for: request)
            // The client has saved A's settled receipt before this check.
            try requireCurrent(ctx)
            do {
                try await updateBalance(client, context: ctx, ticket: ticket,
                                        mayRecover: !result.receiptWasReplayed)
            } catch {
                // A balance read failing cannot turn paid, delivered work into
                // an unpaid failure. Keep its receipt and mark only readiness.
                record(error, context: ctx, ticket: ticket)
            }
            try requireCurrent(ctx)
            return result
        } catch {
            guard isCurrent(ctx) else { throw CancellationError() }
            record(error, context: ctx, ticket: ticket)
            throw error
        }
    }

    private func ticket() -> UInt64 { nextTicket &+= 1; return nextTicket }

    private func currentContext() throws -> Context {
        let current = identity()
        if let context, context.identity == current { return context }
        let old = context
        context = nil; sequence = -1; statusTicket = 0
        if let old { Task { await old.connection.invalidate() } }
        standing = current == nil ? .notOnCredits(connectAgain: false) : .onCredits
        publish(standing, { [identity] in identity() == current })
        guard let current, !current.token.isEmpty else {
            throw ManagedSummaryFailure.refused(code: "not_connected", operationId: nil)
        }
        let valid: @Sendable () -> Bool = { [identity] in identity() == current }
        let connection = try connect(current, valid)
        let transport = BoundTransport(base: connection.transport, isCurrent: valid)
        let ctx = Context(id: UUID(), identity: current,
                          connection: Connection(transport: transport, invalidate: connection.invalidate),
                          account: ManagedAccount(transport: transport),
                          outbox: try ManagedSummaryOutbox(url: outboxURL))
        context = ctx
        return ctx
    }

    private func isCurrent(_ ctx: Context) -> Bool {
        context?.id == ctx.id && identity() == ctx.identity
    }
    private func requireCurrent(_ ctx: Context) throws {
        guard isCurrent(ctx) else { throw CancellationError() }
        try Task.checkCancellation()
    }
    private func client(_ ctx: Context) async throws -> ManagedSummaryClient {
        let account = try await ctx.account.id()
        try requireCurrent(ctx)
        return ManagedSummaryClient(accountId: account, transport: ctx.connection.transport, outbox: ctx.outbox)
    }
    private func updateBalance(_ client: ManagedSummaryClient, context ctx: Context,
                               ticket: UInt64, mayRecover: Bool) async throws {
        // A receipt is historical. Only this route supplies the balance UI.
        let balance = try await client.balance()
        try requireCurrent(ctx)
        guard let incoming = Int64(balance.ledgerSequence), incoming >= sequence else { return }
        sequence = incoming
        guard ticket >= statusTicket else { return }
        if case .floored = standing, !mayRecover { return }
        statusTicket = ticket
        standing = balance.availableMicros == "0" ? .floored(.outOfCredits, at: Date())
            : .good(availableMicros: balance.availableMicros, at: Date())
        emit(ctx)
    }
    private func record(_ error: Error, context ctx: Context, ticket: UInt64) {
        guard isCurrent(ctx), !(error is CancellationError), ticket >= statusTicket else { return }
        let failure = (error as? ManagedSummaryFailure)
            ?? .refused(code: "service_unavailable", operationId: nil)
        guard let next = CreditStanding.from(receipt: nil, failure: failure, provider: name) else { return }
        statusTicket = ticket; standing = next; emit(ctx)
    }
    private func recordPreparation(_ error: Error) {
        let current = identity()
        let failure = (error as? ManagedSummaryFailure)
            ?? .refused(code: "service_unavailable", operationId: nil)
        standing = CreditStanding.from(receipt: nil, failure: failure, provider: name)
            ?? .floored(.serviceUnavailable, at: Date())
        publish(standing, { [identity] in identity() == current })
    }
    private func emit(_ ctx: Context) {
        publish(standing, { [identity] in identity() == ctx.identity })
    }
}

private struct BoundTransport: GatewayTransport {
    let base: any GatewayTransport
    let isCurrent: @Sendable () -> Bool
    func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
        guard isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
        // Do not discard a response after sending: an admitted operation may
        // have settled, and its original account's outbox must retain that fact.
        return try await base.request(method: method, path: path, body: body)
    }
}
