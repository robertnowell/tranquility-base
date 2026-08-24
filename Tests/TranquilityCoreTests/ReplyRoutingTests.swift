import Testing
@testable import TranquilityCore

/// Where the words go, decided once, at mic-open.
///
/// The case that matters is `testAResolvedButUnsettledLaunchStillOwnsTheReply`.
/// That is the 24 Aug misroute stated as an input: the launcher had resolved
/// the promise, the adoption had not yet run, and the old guard — which asked
/// `isPending` — declined the launch and let the ladder answer with whoever
/// had spoken last. Six and a half minutes of speech went to the wrong agent.
/// It could not be a test before this, because the decision lived in
/// `main.swift`, which has no unit tests and cannot easily have any (rule 7).
@Suite struct ReplyRoutingTests {
    private func launch(at conversation: String? = nil) -> PendingLaunch {
        PendingLaunch(label: "Projects", directory: "/Users/x/Projects",
                      conversationAtLaunch: conversation)
    }

    // MARK: - The bug

    @Test func aResolvedButUnsettledLaunchStillOwnsTheReply() {
        let l = launch()
        l.resolve(sessionId: "new-agent")     // registered on the launcher task…
        // …and the adoption block has NOT run yet: no settle(), and the panel's
        // conversation is still the previous agent's. This half-second is the
        // whole incident.
        let d = ReplyRouting.destination(launch: l, conversationNow: nil,
                                         lastHeard: "linkedin-agent")
        #expect(d == .session("new-agent"), "a launch that has an id but has not handed off still owns the mic")
    }

    @Test func anUnresolvedLaunchOwnsTheReplyAndWaits() {
        let l = launch()
        let d = ReplyRouting.destination(launch: l, conversationNow: nil,
                                         lastHeard: "linkedin-agent")
        #expect(d == .launch(l), "answering the card before the agent registers is the common case")
    }

    // MARK: - The claim expiring

    @Test func aSettledLaunchStopsOwningTheReply() {
        let l = launch()
        l.resolve(sessionId: "new-agent")
        l.settle()                            // adoption ran; the panel has the answer
        let d = ReplyRouting.destination(launch: l, conversationNow: "new-agent",
                                         lastHeard: "linkedin-agent")
        #expect(d == .session("new-agent"), "same answer, now by way of the conversation rather than the launch")
    }

    @Test func aStaleSettledLaunchCannotCaptureALaterMicrophone() {
        let l = launch()
        l.resolve(sessionId: "an-hour-old")
        l.settle()
        let d = ReplyRouting.destination(launch: l, conversationNow: nil,
                                         lastHeard: "linkedin-agent")
        #expect(d == .session("linkedin-agent"), "settle() is what keeps pendingLaunch from owning the mic forever")
    }

    @Test func anAbandonedLaunchOwnsNothing() {
        let l = launch()
        l.abandon()                           // trust prompt unanswered, or never registered
        let d = ReplyRouting.destination(launch: l, conversationNow: nil,
                                         lastHeard: "linkedin-agent")
        #expect(d == .session("linkedin-agent"))
    }

    // MARK: - You moved on

    @Test func anExplicitAttentionMoveOutranksALaunchInFlight() {
        // Pressed + NEW AGENT from nothing, then pressed a lamp before it came
        // up. The lamp is a statement about where you are; the launch is not.
        let l = launch(at: nil)
        let d = ReplyRouting.destination(launch: l, conversationNow: "a-lamp-i-pressed",
                                         lastHeard: "linkedin-agent")
        #expect(d == .session("a-lamp-i-pressed"))
    }

    @Test func stayingWhereYouWereLetsTheLaunchClaimTheReply() {
        let l = launch(at: "where-i-was")
        let d = ReplyRouting.destination(launch: l, conversationNow: "where-i-was",
                                         lastHeard: "linkedin-agent")
        #expect(d == .launch(l))
    }

    // MARK: - The ladder with no launch in it

    @Test func theConversationOutranksTheCursor() {
        let d = ReplyRouting.destination(launch: nil, conversationNow: "on-screen",
                                         lastHeard: "older")
        #expect(d == .session("on-screen"))
    }

    @Test func theCursorAnswersWhenThereIsNoConversation() {
        let d = ReplyRouting.destination(launch: nil, conversationNow: nil,
                                         lastHeard: "last-heard")
        #expect(d == .session("last-heard"))
    }

    @Test func nothingToAnswerIsDictationNotAFallThrough() {
        // The old code reached this state by having no branch match, and then
        // addressed the capture to whatever a re-derivation produced. There is
        // no fall-through left to reach: every input returns a case.
        let d = ReplyRouting.destination(launch: nil, conversationNow: nil, lastHeard: nil)
        #expect(d == .dictation)
    }
}
