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
    private let log: @Sendable (String) -> Void
    private var context: Context?
    private var standing: CreditStanding = .notOnCredits(connectAgain: false)
    private var sequence: Int64 = -1
    private var nextTicket: UInt64 = 0
    private var statusTicket: UInt64 = 0
    private struct BalanceCheck: Sendable {
        let client: ManagedSummaryClient
        let context: Context
        let ticket: UInt64
        let mayRecover: Bool
    }
    private var queuedBalance: BalanceCheck?
    private var balanceTask: Task<Void, Never>?

    public init(identity: @escaping IdentitySource, outboxURL: URL,
                connect: @escaping Connect,
                publish: (@Sendable (CreditStanding, @escaping @Sendable () -> Bool) -> Void)? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.identity = identity; self.outboxURL = outboxURL; self.log = log
        self.connect = connect; self.publish = publish ?? { CreditStanding.set($0, isCurrent: $1) }
    }

    /// Called at launch, after pairing/sign-out, and when the network comes
    /// back. No provider call, no debit. Also exercised on every summary, so
    /// an external credential replacement cannot leave this process using a
    /// cached account.
    public func refresh() async {
        let ticket = ticket()
        do {
            let ctx = try currentContext()
            do {
                let client = try await client(ctx)
                try await updateBalance(client, context: ctx, ticket: ticket, mayRecover: true)
                refreshAttempt = 0
            } catch {
                // The reason goes in the log: on 22 Sep the only trace of a
                // failed check was the amber line it caused.
                log("credits: balance check failed: \(Self.describe(error))")
                reportFault(error, during: "balance check")
                record(error, context: ctx, ticket: ticket)
                if Self.saysNothingAboutTheAccount(error) { scheduleRefreshRetry() }
            }
        } catch {
            log("credits: session could not be prepared: \(Self.describe(error))")
            reportFault(error, during: "session preparation")
            recordPreparation(error)
            if Self.saysNothingAboutTheAccount(error) { scheduleRefreshRetry() }
        }
    }

    /// Retries after a check that got no answer about the account: soon,
    /// then less often, then left to the next summary or the next time the
    /// network comes back, both of which check anyway.
    static let refreshRetryDelays: [Duration] = [.seconds(15), .seconds(60), .seconds(300)]
    private var refreshAttempt = 0
    private var refreshRetry: Task<Void, Never>?

    private func scheduleRefreshRetry() {
        guard refreshRetry == nil, refreshAttempt < Self.refreshRetryDelays.count else { return }
        let delay = Self.refreshRetryDelays[refreshAttempt]
        refreshAttempt += 1
        refreshRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.retryRefresh()
        }
    }

    private func retryRefresh() async {
        refreshRetry = nil
        await refresh()
    }

    /// Online, and no answer about the account: that is our fault to fix, so
    /// it goes to diagnostics with its reason. Offline it is not a fault at
    /// all, and a cancellation is nobody's.
    private func reportFault(_ error: Error, during phase: String,
                             file: StaticString = #fileID, line: UInt = #line) {
        guard Self.saysNothingAboutTheAccount(error), Connectivity.isReachable else { return }
        Failures.report(.creditsService, reason: "\(phase): \(Self.describe(error))",
                        file: file, line: line)
    }

    /// The failure in words safe to send: the kind and code, never a URL
    /// (gateway paths carry the account id), a token, or an operation id.
    static func describe(_ error: Error) -> String {
        switch error {
        case let failure as ManagedSummaryFailure:
            switch failure {
            case let .refused(code, _): return "refused \(code)"
            case let .pending(_, state): return "still pending (\(state))"
            case .outcomeUnknown: return "outcome unknown"
            case .invalidResponse: return "invalid response"
            case .missingSourceIdentity: return "missing source identity"
            case .sourceIdentityConflict: return "source identity conflict"
            case .correctiveRetryNotAllowed: return "corrective retry not allowed"
            }
        case let failure as GatewayAuthority.Failure:
            return "authority \(failure.code)"
        case let failure as URLError:
            return "URLError \(failure.code.rawValue): \(failure.localizedDescription)"
        default:
            let ns = error as NSError
            return "\(type(of: error)) \(ns.domain) \(ns.code)"
        }
    }

    /// A failure that is not an answer about the account: unreachable,
    /// timed out, a gateway or provider fault. It keeps the last standing.
    static func saysNothingAboutTheAccount(_ error: Error) -> Bool {
        guard !(error is CancellationError) else { return false }
        let failure = (error as? ManagedSummaryFailure)
            ?? .refused(code: "service_unavailable", operationId: nil)
        return CreditStanding.from(receipt: nil, failure: failure, provider: "tranquility-gateway") == nil
    }

    public func brief(for request: SummaryRequest) async throws -> SessionBrief {
        try await delivery(for: request).brief
    }

    public func delivery(for request: SummaryRequest) async throws -> SummaryDelivery {
        let ticket = ticket()
        let ctx: Context
        do { ctx = try currentContext() }
        catch { reportFault(error, during: "summary preparation"); recordPreparation(error); throw error }
        do {
            let client = try await client(ctx)
            let result = try await ManagedSummaryProvider(client: client).delivery(for: request)
            // The client has saved A's settled receipt before this check.
            try requireCurrent(ctx)
            scheduleBalance(.init(client: client, context: ctx, ticket: ticket,
                                  mayRecover: !result.receiptWasReplayed))
            return result
        } catch {
            guard isCurrent(ctx) else { throw CancellationError() }
            reportFault(error, during: "summary")
            record(error, context: ctx, ticket: ticket)
            throw error
        }
    }

    private func ticket() -> UInt64 { nextTicket &+= 1; return nextTicket }

    /// One balance request in flight and one newest follow-up, never an
    /// unbounded task per summary. Display freshness cannot delay delivery.
    private func scheduleBalance(_ check: BalanceCheck) {
        queuedBalance = check
        guard balanceTask == nil else { return }
        balanceTask = Task {
            while let check = queuedBalance {
                queuedBalance = nil
                guard isCurrent(check.context) else { continue }
                do {
                    try await updateBalance(check.client, context: check.context,
                                            ticket: check.ticket, mayRecover: check.mayRecover)
                } catch {
                    // Paid work already succeeded; only the number is stale.
                    // Saying "credits unavailable" here was audit finding A10:
                    // the summary was on credits and charged, and the row
                    // said summaries were on the floor.
                    recordBalanceUnknown(error, context: check.context, ticket: check.ticket)
                }
            }
            balanceTask = nil
        }
    }

    /// Deterministic local acceptance can await display work; delivery never does.
    func waitForBalanceUpdates() async { await balanceTask?.value }

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

    /// The voice client for the account this Mac is signed in as, or a named
    /// refusal. Hands-free asks once per session and holds it for that
    /// session's life; an account change invalidates the context underneath,
    /// and the next call gets a fresh client rather than the old account's.
    public func voice() async throws -> ManagedVoiceClient {
        let ctx = try currentContext()
        let account = try await ctx.account.id()
        try requireCurrent(ctx)
        return ManagedVoiceClient(accountId: account, transport: ctx.connection.transport)
    }

    /// The voice this account speaks in, and the transcript it is heard with.
    ///
    /// Both are bound to the identity that is signed in now, exactly as
    /// summaries are: an account change invalidates the context underneath
    /// and the next call gets the new account's, never the old one's.
    /// A voice or transcript purchase failed. The same two consequences a
    /// summary's failure has: an account answer becomes the standing, so a
    /// refused transcript can say "Add credits"; anything else online is a
    /// fault for diagnostics. Before 22 Sep audio refusals reached only
    /// app.log, and out of credits on the microphone changed nothing on screen.
    public func noteAudioFailure(_ error: Error, during phase: String) {
        guard !(error is CancellationError) else { return }
        reportFault(error, during: phase)
        let failure = (error as? ManagedSummaryFailure) ?? .refused(code: "service_unavailable", operationId: nil)
        guard let next = CreditStanding.from(receipt: nil, failure: failure, provider: name) else { return }
        statusTicket = ticket(); standing = next
        let current = identity()
        publish(standing, { [identity] in identity() == current })
    }

    public func speech() async throws -> ManagedSpeechClient {
        let ctx = try currentContext()
        let account = try await ctx.account.id()
        try requireCurrent(ctx)
        return ManagedSpeechClient(accountId: account, transport: ctx.connection.transport)
    }

    public func transcription() async throws -> ManagedTranscriptionSession {
        let ctx = try currentContext()
        let account = try await ctx.account.id()
        try requireCurrent(ctx)
        return ManagedTranscriptionSession(accountId: account, transport: ctx.connection.transport)
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
    private func recordBalanceUnknown(_ error: Error, context ctx: Context, ticket: UInt64) {
        guard isCurrent(ctx), !(error is CancellationError), ticket >= statusTicket else { return }
        // A floor already showing keeps its reason; a stale number does not
        // outrank a real warning.
        if case .floored = standing { return }
        statusTicket = ticket; standing = .balanceUnknown(at: Date()); emit(ctx)
    }
    private func recordPreparation(_ error: Error) {
        let current = identity()
        let failure = (error as? ManagedSummaryFailure)
            ?? .refused(code: "service_unavailable", operationId: nil)
        // Not an answer about the account: the last standing holds.
        guard let next = CreditStanding.from(receipt: nil, failure: failure, provider: name) else { return }
        standing = next
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
