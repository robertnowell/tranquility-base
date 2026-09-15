import Foundation

/// The Agent Client Protocol, as spoken on the wire.
///
/// Every shape here was read off a live `opencode acp` 1.18.30 on 14 Sep 2026,
/// not from the specification: the two agree, but the spec describes a family
/// and a running agent describes what this code will actually meet.
///
/// **Framing is newline-delimited JSON**, one object per line, and NOT the
/// LSP-style `Content-Length` header the protocol's ancestry would suggest.
/// That was the first thing checked and it is the thing most likely to be
/// assumed wrong, because every other JSON-RPC-over-stdio protocol in this
/// lineage frames with headers.
public enum ACPWire {

    /// ACP ships stdio ONLY. Its HTTP and WebSocket transport has been an
    /// Active RFD since 2 Jul 2026 and is unshipped, which is why `Transport`
    /// below is a pipe pair rather than a URL. Verified separately: `opencode
    /// acp` advertises `--port` in its help and never binds it.
    public static let protocolVersion = 1

    // MARK: - Envelopes

    /// A request, a response, or a notification.
    ///
    /// Only the ROUTING fields are decoded here — an id, a method, whether an
    /// error came back. The payload stays as the raw line and is decoded into
    /// a concrete type by whoever asked for it, which is the same discipline
    /// `OpenCodeClient` keeps with `decodeList(_:as:)`. The alternative is a
    /// general JSON tree type, and this codebase has gone four years without
    /// one; a protocol client is a poor reason to introduce the first.
    public struct Message: Sendable {
        public var id: Int?
        public var method: String?
        public var error: RPCError?
        /// How many notifications the client had delivered before this
        /// message, stamped by `ACPClient.receive`. Notifications reach the
        /// provider through a stream its pump drains asynchronously;
        /// responses resume the caller directly. So a `session/prompt`
        /// response can be acted on before the last `agent_message_chunk`
        /// ahead of it has been translated, and the turn's words come out
        /// short (CI, 15 Sep: "working " for "working on it"). The provider
        /// waits until it has translated up to this number.
        public var sequence: Int = 0
        /// The whole line, kept so a typed decode can happen later.
        public var raw: Data

        /// A response carries an id and no method. A notification carries a
        /// method and no id. A request FROM the agent carries both, and
        /// `session/request_permission` is the one that matters.
        public var isNotification: Bool { method != nil && id == nil }
        public var isAgentRequest: Bool { method != nil && id != nil }

        private struct Routing: Decodable {
            var id: Int?
            var method: String?
            var error: RPCError?
        }

        /// nil for a line that is not a JSON-RPC message at all. Agents print
        /// to stdout for reasons of their own, and a banner must not be able
        /// to kill the client.
        public init?(line: Data) {
            guard let routing = try? JSONDecoder().decode(Routing.self, from: line)
            else { return nil }
            guard routing.id != nil || routing.method != nil else { return nil }
            self.id = routing.id
            self.method = routing.method
            self.error = routing.error
            self.raw = line
        }

        /// The `result` of a response, decoded as `T`.
        public func result<T: Decodable>(_ type: T.Type) -> T? {
            (try? JSONDecoder().decode(Envelope<T>.self, from: raw))?.result
        }

        /// The `params` of a notification or an agent request, decoded as `T`.
        public func params<T: Decodable>(_ type: T.Type) -> T? {
            (try? JSONDecoder().decode(Envelope<T>.self, from: raw))?.params
        }
    }

    public struct RPCError: Decodable, Sendable, Error {
        public var code: Int
        public var message: String
    }

    /// Declared once at namespace scope: Swift refuses a generic type nested
    /// inside a generic function.
    struct Envelope<U: Decodable>: Decodable {
        var result: U?
        var params: U?
    }

    // MARK: - Handshake

    /// **The agent declares its own capabilities**, which is the whole economic
    /// argument of this client restated in one field.
    ///
    /// A catalog entry does not have to state what a vendor can do, so it
    /// cannot go stale when the vendor ships a release. That is the difference
    /// between a table of names and a table of names plus a maintenance
    /// burden, and it is why `ACPCatalog` carries a command and nothing else.
    public struct Initialized: Decodable, Sendable {
        public var protocolVersion: Int
        public var agentCapabilities: AgentCapabilities?
        public var agentInfo: AgentInfo?
        public var authMethods: [AuthMethod]?

        public struct AgentCapabilities: Decodable, Sendable {
            public var loadSession: Bool?
            public var promptCapabilities: PromptCapabilities?
            public var sessionCapabilities: SessionCapabilities?
        }
        public struct PromptCapabilities: Decodable, Sendable {
            public var image: Bool?
            public var embeddedContext: Bool?
        }
        /// Present-means-supported: the live agent returns `{"close":{},
        /// "fork":{},"list":{},"resume":{}}`, empty objects rather than
        /// booleans, so the KEY is the declaration and the value is reserved.
        public struct SessionCapabilities: Decodable, Sendable {
            /// Decoded as "did the key appear", which is what the wire means:
            /// the live agent returns empty objects, not booleans.
            public var close: Bool { present.contains("close") }
            public var fork: Bool { present.contains("fork") }
            public var list: Bool { present.contains("list") }
            public var resume: Bool { present.contains("resume") }

            private let present: Set<String>

            private struct Key: CodingKey {
                var stringValue: String
                var intValue: Int? { nil }
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { nil }
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                present = Set(container.allKeys.map(\.stringValue))
            }
        }
        public struct AgentInfo: Decodable, Sendable {
            public var name: String?
            public var version: String?
        }
        public struct AuthMethod: Decodable, Sendable {
            public var id: String?
            public var name: String?
            public var description: String?
        }

        /// Translate the vendor's own declaration into this app's, rather than
        /// letting a catalog assert it. `sendWhileWorking` is deliberately
        /// false: ACP's prompt turn is request/response and a second prompt
        /// mid-turn has no defined behaviour, so this surfaces the gap rather
        /// than hiding it (provider seam, the Warp rule).
        public var capabilities: Capabilities {
            Capabilities(
                canStart: true,
                canSend: true,
                canAnswer: true,
                canCancel: true,
                sendWhileWorking: false,
                listIsCallerScoped: true,
                carriesPullRequest: false)
        }
    }

    // MARK: - Session updates

    /// The kinds a live agent emitted across one prompt turn, in order:
    /// `available_commands_update`, `agent_message_chunk`, `usage_update`.
    /// The full vocabulary is larger; unknown kinds are carried, never
    /// discarded, because an update this app cannot name is still evidence
    /// that the agent is working.
    public enum UpdateKind: String, Sendable {
        case agentMessageChunk = "agent_message_chunk"
        case agentThoughtChunk = "agent_thought_chunk"
        case userMessageChunk = "user_message_chunk"
        case toolCall = "tool_call"
        case toolCallUpdate = "tool_call_update"
        case plan
        case availableCommandsUpdate = "available_commands_update"
        case usageUpdate = "usage_update"
        case currentModeUpdate = "current_mode_update"
    }

    public struct SessionUpdate: Decodable, Sendable {
        public var sessionId: String?
        public var update: Update?

        public struct Update: Decodable, Sendable {
            public var sessionUpdate: String?
            public var content: Content?

            public struct Content: Decodable, Sendable {
                public var type: String?
                public var text: String?
            }
        }

        private enum CodingKeys: String, CodingKey { case sessionId, update }
    }

    /// Why a prompt turn ended. `end_turn` is the ordinary one; the others are
    /// the reason a row must not simply go green.
    public enum StopReason: String, Decodable, Sendable {
        case endTurn = "end_turn"
        case maxTokens = "max_tokens"
        case maxTurnRequests = "max_turn_requests"
        case refusal
        case cancelled
    }

    public struct PromptResult: Decodable, Sendable {
        public var stopReason: StopReason?
        /// `Message.sequence` of the response, for the provider's barrier.
        public var sequence: Int = 0
        private enum CodingKeys: String, CodingKey { case stopReason }

        /// **A refusal is amber, not green.** The three-lamp ruling reserves
        /// amber for the unanticipated, and an agent that stopped because it
        /// hit a token ceiling or declined the work has not finished a turn in
        /// any sense the user would recognise.
        public var state: AgentSessionState {
            switch stopReason {
            case .endTurn, .none: return .completed
            case .cancelled: return .canceled
            case .refusal: return .rejected
            case .maxTokens, .maxTurnRequests: return .failed
            }
        }
    }

    public struct NewSession: Decodable, Sendable {
        public var sessionId: String
    }

    /// `session/list`, which is how a freshly-attached client learns about
    /// sessions that existed before it. Verified against a live agent on
    /// 14 Sep: declared via `sessionCapabilities.list` AND implemented, which
    /// are two different claims and both were checked.
    public struct SessionList: Decodable, Sendable {
        public var sessions: [Item]?

        public struct Item: Decodable, Sendable {
            public var sessionId: String
            public var title: String?
            public var cwd: String?
            public var updatedAt: String?

            /// A listed session is not running a turn — if it were, the agent
            /// would be streaming updates for it — so it has finished its turn
            /// and is ready for the next one. Under the three-lamp ruling that
            /// is green, and `.unknown` here would paint it amber.
            public func agentSession(provider: String) -> AgentSession {
                var session = AgentSession.of(sessionId, provider: provider,
                                              title: Self.name(title) ?? "",
                                              state: .completed,
                                              updatedAt: Self.date(updatedAt))
                session.repository = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                return session
            }

            /// The agent's title for a session, or nil when it has not named
            /// it yet. OpenCode lists an unprompted session as
            /// `New session - 2026-09-15T20:15:04.847Z`, which is a placeholder
            /// wearing a title's clothes: the row's own fallback (the agent and
            /// its place) says more than a timestamp does, and the model's
            /// title replaces both after the first turn. Measured 15 Sep.
            public static func name(_ title: String?) -> String? {
                guard let title, !title.isEmpty, !title.hasPrefix("New session - ") else { return nil }
                return title
            }

            /// `RolloutClock` already parses both the fractional and the plain
            /// stamp and already documents why it builds a formatter per call.
            /// A second copy here would be the same fact twice, with its own
            /// chance to be the one that forgets `.withFractionalSeconds` —
            /// and a stamp that fails to parse sorts the row to 1970, which
            /// reads as a clock bug rather than a parse bug.
            static func date(_ raw: String?) -> Date {
                RolloutClock.date(raw) ?? Date(timeIntervalSince1970: 0)
            }
        }
    }
}

