import Foundation

/// OpenCode's own shapes, and **the only file in this package that knows
/// them**.
///
/// Every field here was read from crobot's `ui/src/types.ts` against SDK
/// 1.18.29, which is the client OpenCode itself publishes and crobot drives in
/// production. Guessing these from documentation would have been the slower
/// route to the same place with more mistakes in it.
///
/// Rule 1 of the provider seam governs every decoder below: **missing means
/// absent, unknown means ignore.** Everything optional, nothing throwing on a
/// field a future version adds or renames. A vendor shipping a new event kind
/// must not be able to empty the grid.
enum Wire {

    // MARK: - Session

    struct Session: Decodable {
        var id: String
        var title: String?
        var time: Time?
        /// Present on some builds, absent on others, and never load-bearing.
        var parentID: String?

        struct Time: Decodable { var created: Double?; var updated: Double? }

        func agentSession(provider: String) -> AgentSession {
            // `of` keeps the addressable id and the server's own id together,
            // so nothing downstream has to reverse a one-way hash.
            AgentSession.of(
                id, provider: provider,
                title: title ?? "",
                // A LOCAL SERVER DOES NOT REPORT A STATE, and inventing one is
                // the failed-poll bug in another costume. `/session` says a
                // session exists, not what it is doing; the event stream and
                // the pending-request fetch say that. `.unknown` is the honest
                // answer and it renders as unreachable rather than as calm.
                state: .unknown,
                updatedAt: Self.date(time?.updated ?? time?.created))
        }

        /// OpenCode stamps milliseconds. A bare `timeIntervalSince1970` on that
        /// number lands in the year 57000, which sorts every row to the top and
        /// reads as a clock bug rather than a units bug.
        static func date(_ raw: Double?) -> Date {
            guard let raw, raw > 0 else { return Date(timeIntervalSince1970: 0) }
            return Date(timeIntervalSince1970: raw / 1000)
        }
    }

    // MARK: - Message

    struct Message: Decodable {
        var info: Info?
        var parts: [Part]?

        struct Info: Decodable {
            var id: String?
            var role: String?
            var time: Time?
            struct Time: Decodable { var created: Double?; var completed: Double? }
        }

        struct Part: Decodable {
            var type: String?
            var text: String?
        }

        /// Text parts only, joined. A tool call renders as a card elsewhere and
        /// has no business being read aloud as if the agent said it.
        func turn() -> Turn? {
            guard let info, let id = info.id else { return nil }
            let text = (parts ?? [])
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // An unknown role is the AGENT, not a crash and not the user. The
            // asymmetry is deliberate: attributing the agent's words to the
            // user would put them in the wrong half of a transcript, and a new
            // role OpenCode invents is far likelier to be some flavour of
            // agent than to be a person.
            let role: Turn.Role = info.role == "user" ? .user : .agent
            return Turn(id: id, at: Session.date(info.time?.created), role: role, text: text)
        }
    }

    // MARK: - Question

    /// A request holding MANY questions, each with its own options, its own
    /// multi-select flag and its own free-text flag, answered together as
    /// `answers: string[][]`. This shape is why `PendingRequest` carries an
    /// array: the single-question model it shipped with could not express one.
    struct Question: Decodable {
        var id: String
        var sessionID: String
        var questions: [Item]?

        struct Item: Decodable {
            /// Both spellings appear. crobot's own renderer reads either.
            var question: String?
            var text: String?
            var header: String?
            var multiple: Bool?
            var custom: Bool?
            var options: [Option]?

            struct Option: Decodable { var label: String; var description: String? }

            var prompt: String { question ?? text ?? header ?? "" }
        }

        func pending(session: AgentSession.ID) -> PendingRequest? {
            let items = (questions ?? []).map { item in
                PendingRequest.Question(
                    asked: item.prompt,
                    // The LABEL is the id. OpenCode answers by label (the reply
                    // is `answers: string[][]` of chosen labels), so minting a
                    // synthetic id here would mean translating back on the way
                    // out and getting it wrong once.
                    options: (item.options ?? []).map {
                        PendingRequest.Option(id: $0.label, label: $0.label)
                    },
                    allowsMultiple: item.multiple ?? false,
                    allowsCustom: item.custom ?? false)
            }
            // A request with no questions in it is not answerable, and showing
            // an amber row with nothing to say is worse than showing none.
            guard !items.isEmpty, items.contains(where: { !$0.asked.isEmpty }) else { return nil }
            return PendingRequest(id: id, session: session, questions: items)
        }
    }

    // MARK: - Permission

    /// The degenerate case: one question, three options, no free text.
    struct Permission: Decodable {
        var id: String
        var sessionID: String
        var action: String?
        var resources: [String]?

        func pending(session: AgentSession.ID) -> PendingRequest {
            let what = action ?? "run this"
            let on = (resources ?? []).prefix(3).joined(separator: ", ")
            let asked = on.isEmpty ? "Allow \(what)?" : "Allow \(what) on \(on)?"
            return PendingRequest(
                id: id, session: session,
                questions: [PendingRequest.Question(
                    asked: asked,
                    options: [
                        .init(id: "once", label: "Allow once", kind: .allowOnce),
                        .init(id: "always", label: "Always allow", kind: .allowAlways),
                        .init(id: "reject", label: "Reject", kind: .rejectOnce),
                    ])])
        }
    }

    // MARK: - Events

    /// One server-sent event, decoded into an `AgentEvent`, or nil for one this
    /// app has no use for.
    ///
    /// **Every case below was OBSERVED, not guessed.** The first draft invented
    /// four event names from the shape of the API and got two of them wrong; a
    /// live `opencode serve` 1.18.30 was driven through a real turn and the
    /// frames captured, which is the only reason the stream yields anything at
    /// all. What actually arrives, by frequency:
    ///
    ///     plugin.added, message.part.updated, message.part.delta,
    ///     message.updated, session.updated, session.status, session.created,
    ///     session.diff, session.idle, server.connected, catalog.updated,
    ///     reference.updated, integration.updated
    ///
    /// Returning nil rather than throwing for the rest is rule 1: OpenCode adds
    /// event types on a release nobody here controls, and a client that fell
    /// over on an unfamiliar one would break on somebody else's Tuesday.
    static func event(_ data: Data, provider: String) -> AgentEvent? {
        struct Envelope: Decodable {
            var type: String?
            var properties: Properties?
            struct Properties: Decodable {
                var sessionID: String?
                var info: Info?
                var part: Part?
                var status: Status?
                struct Info: Decodable {
                    var id: String?
                    var sessionID: String?
                    var role: String?
                }
                struct Part: Decodable {
                    var id: String?
                    var type: String?
                    var text: String?
                    var messageID: String?
                }
                /// `{"status":{"type":"busy"}}`. THE working signal, and it is
                /// first-hand rather than inferred from whether a message
                /// arrived recently.
                struct Status: Decodable { var type: String? }
            }
        }
        guard let e = try? JSONDecoder().decode(Envelope.self, from: data),
              let type = e.type else { return nil }
        let raw = e.properties?.sessionID ?? e.properties?.info?.sessionID
        guard let raw, !raw.isEmpty else { return nil }
        let session = AgentSession.id(raw, provider: provider)

        func changed(_ state: AgentSessionState) -> AgentEvent {
            var s = AgentSession.of(raw, provider: provider)
            s.state = state
            return AgentEvent(provider: provider, session: session, kind: .changed(s))
        }

        switch type {
        case "message.part.updated":
            // The TEXT lives on the part, and so does its own id. The first
            // draft fell back to `part.type` for the id, which made every text
            // part in a session share the id "text".
            guard let part = e.properties?.part, part.type == "text",
                  let text = part.text, !text.isEmpty,
                  let id = part.id ?? part.messageID else { return nil }
            // `message.updated` carries the role; a part does not, so an
            // assistant part and a user part are told apart by the message
            // event that precedes them. Absent that, agent is the safe default
            // for the reason `Message.turn` gives.
            return AgentEvent(provider: provider, session: session,
                              kind: .said(Turn(id: id, at: Date(), role: .agent, text: text)))

        case "session.status":
            // busy or idle, first-hand. `idle` means THE TURN ENDED, not that
            // the session is over: you can send it another message. A2A has no
            // "idle but alive", and `completed` is the closest honest word --
            // the bucket rule then decides between "finished, unread" and
            // "finished, read", which is exactly Paseo's attention-vs-done
            // split.
            switch e.properties?.status?.type {
            case "busy": return changed(.working)
            case "idle": return changed(.completed)
            default: return nil
            }

        case "session.idle":
            return changed(.completed)

        case "session.error":
            return AgentEvent(provider: provider, session: session,
                              kind: .failed(reason: "opencode reported a session error"))

        case "session.created", "session.updated":
            // It exists, or something about it moved. Neither says what it is
            // doing, and inventing a state here would overwrite a `busy` that
            // `session.status` had just reported correctly.
            return changed(.unknown)

        case "question.updated", "permission.updated":
            // The REQUEST ITSELF is not on this event in a shape worth trusting
            // across versions, and it is one cheap fetch away. So this says
            // "something is asking" and the caller fetches it, which is the
            // same separation the model already insists on everywhere else.
            return changed(.inputRequired)

        default:
            // Includes message.part.delta, deliberately: it carries a fragment
            // of text that message.part.updated then delivers whole, and
            // emitting both would read the same sentence out twice.
            return nil
        }
    }
}
