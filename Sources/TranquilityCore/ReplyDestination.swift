import Foundation

/// Where the words you are about to speak will go.
///
/// One value, decided once, at the moment the microphone opens.
///
/// Before this, the panel carried the same fact in three fields —
/// `recordingTarget: String?`, `recordingLaunch: PendingLaunch?` and
/// `dictationMode: Bool` — across forty sites in `main.swift`. Three fields is
/// eight representable states, of which three were ever legal, and the 24 Aug
/// misroute was the app sitting in one of the five that were not: no launch
/// claim, no adoption yet, and an `if/else` with nothing to match, which fell
/// through and answered with the previous agent. Six and a half minutes of
/// speech about Klaviyo campaigns were typed into a LinkedIn session, under a
/// label that read correctly the whole time because both agents lived in the
/// same directory.
///
/// An enum cannot fall through. Every input to `ReplyRouting.destination`
/// returns one of these three, so the state that produced that bug stops being
/// expressible rather than being guarded against.
///
/// `nil` at the call site is not a fourth case: it means no capture is in
/// flight. The distinction matters — `.dictation` is a live capture with no
/// agent to answer, which is a different thing from having nothing to say.
public enum ReplyDestination: Sendable, Equatable {
    /// A session that exists now. The id is final.
    case session(String)

    /// A launch whose agent has not registered yet. It becomes a session id
    /// before the send — see `PendingLaunch.session(timeout:)`. This case is
    /// the whole reason the greeting card can be answered in the first place.
    case launch(PendingLaunch)

    /// No agent is being answered: the transcript goes to the focused text
    /// field, or to the clipboard. Wispr's rule.
    case dictation

    public static func == (a: ReplyDestination, b: ReplyDestination) -> Bool {
        switch (a, b) {
        case (.session(let x), .session(let y)): return x == y
        case (.launch(let x), .launch(let y)):   return x === y
        case (.dictation, .dictation):           return true
        default:                                 return false
        }
    }
}

/// The one place that answers "where do these words go".
///
/// Asked when the microphone opens, and never asked again. The send addresses
/// the value this returned; it does not re-derive one. That half was already
/// right — `main.swift` has said so since the HTML button replied to the wrong
/// session — but the rule was written about the VALUE and never about the
/// DECISION that produces it, so the decision stayed an ad-hoc `if/else`
/// duplicated at two call sites, reading a predicate that answered a different
/// question. This is that sentence finished.
///
/// Pure, and in Core, for the reason rule 7 exists: `Sources/TranquilityApp`
/// has no unit tests and cannot easily have them, and this is the most
/// consequential decision the app makes. Here it is five inputs and a table.
///
/// Deliberately NOT responsible for pid, label or cwd. Those need a subprocess
/// probe, and tangling the lookup with the decision is what kept the decision
/// in the app layer in the first place. This says WHICH; the caller looks up
/// what it knows about it.
public enum ReplyRouting {
    /// - Parameters:
    ///   - launch: the newest launch, if one is in flight — the app's
    ///     `pendingLaunch`. Newest by construction: each `+ NEW AGENT` press
    ///     overwrites it, which is the `isNewestLaunch` half of
    ///     `LaunchAdoption.claimsTheReply` already satisfied at the call site.
    ///   - conversationNow: the session you are in as the microphone opens.
    ///   - lastHeard: the session that last spoke to you and was heard — the
    ///     reply cursor, valid inside the reply window.
    public static func destination(launch: PendingLaunch?,
                                   conversationNow: String?,
                                   lastHeard: String?) -> ReplyDestination {
        // 1. A launch that still owns your voice.
        //
        // "Still owns" is NOT "has no id yet". That was the 24 Aug bug: the
        // launcher resolves the promise on a background thread and adopts the
        // destination one main-actor hop later, and in the gap between the two
        // the launch had an id (so the old `isPending` guard declined) while
        // `activeConversation` was still the previous agent (so the ladder
        // answered with it). Registration had never been fast enough to open
        // that gap — five to nine seconds against a person answering a card —
        // until tmux replaced Terminal and one launch came up in three.
        //
        // A resolved launch is therefore not a launch that has stopped
        // mattering. It is a launch whose id we happen to know already, and it
        // takes the same rung, which is why there is no special case here.
        if let launch, launch.ownsTheReply,
           LaunchAdoption.claimsTheReply(isNewestLaunch: true,
                                         conversationAtLaunch: launch.conversationAtLaunch,
                                         conversationNow: conversationNow) {
            // Knowing the id early is worth using: the panel can name the real
            // session while you speak instead of a directory, and the send
            // skips the wait entirely.
            if let id = launch.resolvedSession { return .session(id) }
            return .launch(launch)
        }
        // 2. The session on screen, or the one you just replied to. Your
        //    attention, which outranks anything derived from cursors.
        if let conversationNow { return .session(conversationNow) }
        // 3. The session you last heard from, inside the reply window.
        if let lastHeard { return .session(lastHeard) }
        // 4. Nothing is being answered.
        return .dictation
    }
}
