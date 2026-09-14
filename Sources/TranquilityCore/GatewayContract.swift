import CryptoKit
import Foundation

/// Public v1 wire values. Provider prices, keys, attempts and ledger stay private.
public struct GatewaySource: Codable, Sendable, Equatable {
    public let namespace: String
    public let taskId: String
    public let turnId: String
    public let intentId: String

    public init(namespace: String, taskId: String, turnId: String, intentId: String = "summary.v1") {
        self.namespace = namespace; self.taskId = taskId; self.turnId = turnId; self.intentId = intentId
    }

    /// Only for a locally produced hook event, at ingestion. The origin UUID
    /// belongs to the producing installation and must survive upgrades. Imported
    /// events carry their original source unchanged, never the viewing Mac's ID.
    public static func localHook(_ event: QueuedEvent, originId: UUID) -> GatewaySource {
        GatewaySource(namespace: "local:\(originId.uuidString.lowercased())",
                      taskId: event.sessionId, turnId: event.id)
    }

    var isValid: Bool {
        [namespace, taskId, turnId, intentId].allSatisfy { (1...256).contains($0.unicodeScalars.count) }
    }

    /// Hashes identity, NOT content. See contracts/gateway/v1 for byte framing.
    public func operationId(accountId: UUID) -> String {
        var bytes = Data("tb.summary.v1\0".utf8)
        for part in [accountId.uuidString.lowercased(), namespace, taskId, turnId, intentId] {
            let value = Data(part.utf8)
            bytes.append(Data("\(value.count):".utf8)); bytes.append(value)
        }
        var digest = Array(SHA256.hash(data: bytes).prefix(16))
        digest[6] = (digest[6] & 15) | 128
        digest[8] = (digest[8] & 63) | 128
        let hex = digest.map { String(format: "%02x", $0) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]]
            .map { $0.joined() }.joined(separator: "-")
    }
}

public struct GatewaySummaryInput: Codable, Sendable, Equatable {
    public let lastAssistantMessage: String
    public let projectLabel: String
    public let firstUserMessage: String?
    public let previousGoal: String?
    public let gitBranch: String?
    public let cwd: String?
    public let hookEvent: HookEventKind
    public let notificationMatcher: String?

    public init(_ request: SummaryRequest) {
        lastAssistantMessage = request.lastAssistantMessage; projectLabel = request.projectLabel
        firstUserMessage = request.firstUserMessage; previousGoal = request.previousGoal
        gitBranch = request.gitBranch; cwd = request.cwd; hookEvent = request.hookEvent
        notificationMatcher = request.notificationMatcher
    }
}

public struct GatewaySummaryRequest: Codable, Sendable, Equatable {
    public let version: String
    public let source: GatewaySource
    public let input: GatewaySummaryInput
    public init(source: GatewaySource, input: GatewaySummaryInput) {
        self.version = "1"; self.source = source; self.input = input
    }
}

public struct GatewayBalance: Codable, Sendable, Equatable {
    public let availableMicros: String
    public let reservedMicros: String
    public let ledgerSequence: String
    var isValid: Bool { [availableMicros, reservedMicros, ledgerSequence].allSatisfy(GatewayContract.isMoney) }
}

public struct GatewayReceipt: Codable, Sendable, Equatable {
    public let id: String
    public let accountId: String
    public let operationId: String
    public let currency: String
    public let chargedMicros: String
    public let pricebookVersion: String
    public let settledAt: String
    /// Historical snapshot. Fetch balance separately for the current value.
    public let balanceAfter: GatewayBalance
}

public struct GatewayAccount: Codable, Sendable, Equatable {
    public let version: String
    public let accountId: String
    public let currency: String
    public let balance: GatewayBalance
}

public struct GatewayOperation: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case admitted, running, reconciling, succeeded, failed, cancelled
        public var isTerminal: Bool { [.succeeded, .failed, .cancelled].contains(self) }
    }
    public struct ServiceError: Codable, Sendable, Equatable { public let code: String }
    public let version: String
    public let accountId: String
    public let operationId: String
    public let state: State
    public let brief: SessionBrief?
    public let receipt: GatewayReceipt?
    public let error: ServiceError?

    func validate(account: String, operation: String) throws {
        guard version == "1", accountId == account, operationId == operation,
              state.isTerminal == (receipt != nil), (state == .succeeded) == (brief != nil)
        else { throw ManagedSummaryFailure.invalidResponse }
        if let brief {
            guard !brief.topic.isEmpty, !brief.happened.isEmpty, error == nil
            else { throw ManagedSummaryFailure.invalidResponse }
        }
        if let receipt {
            guard receipt.accountId == account, receipt.operationId == operation,
                  UUID(uuidString: receipt.id) != nil, receipt.currency == "USD",
                  GatewayContract.isMoney(receipt.chargedMicros), receipt.balanceAfter.isValid,
                  !receipt.pricebookVersion.isEmpty,
                  GatewayContract.isTimestamp(receipt.settledAt),
                  state == .succeeded || receipt.chargedMicros == "0"
            else { throw ManagedSummaryFailure.invalidResponse }
        }
    }
}

enum GatewayContract {
    static func isTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
    static func isMoney(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 18 && (value == "0" || value.first != "0")
            && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// A free fallback must not erase these actionable financial/transport outcomes.
public enum ManagedSummaryFailure: Error, Sendable, Equatable {
    case missingSourceIdentity
    case sourceIdentityConflict
    case correctiveRetryNotAllowed
    case refused(code: String, operationId: String?)
    case pending(operationId: String, state: GatewayOperation.State)
    case outcomeUnknown(operationId: String)
    case invalidResponse
}
