import Foundation
import Testing
@testable import TranquilityCore

/// Who owns the reply after + NEW AGENT.
///
/// The incident: 19 Aug, 15:35:54 launch, 15:35:57 a microphone fault took the
/// stage from the greeting card, 15:36:00 the session registered and was
/// refused its binding, and the destination — which lived inside that
/// binding's success branch — stayed on the previous agent.
struct LaunchAdoptionTests {

    @Test func theLaunchClaimsTheReplyWhenNothingHasChanged() {
        // The plain case, and the one the incident broke: you pressed the
        // button, you have not touched anything since, the agent exists.
        #expect(LaunchAdoption.claimsTheReply(
            isNewestLaunch: true, conversationAtLaunch: nil, conversationNow: nil))
    }

    @Test func aCardThatMovedOnDoesNotCostTheDestination() {
        // The whole point. Nothing in this decision can see the panel, so no
        // amount of stage-taking — a mic fault, a result card, a repaint —
        // can reach it. Same inputs as above; the panel is simply not one.
        #expect(LaunchAdoption.claimsTheReply(
            isNewestLaunch: true, conversationAtLaunch: "prev", conversationNow: "prev"))
    }

    @Test func movingOnDeliberatelyOutranksTheLaunch() {
        // You pressed a lamp, or ⌃⌥'d to another agent, while the new one was
        // still coming up. That is an explicit statement about your attention
        // and it must survive a registration that lands afterwards.
        #expect(!LaunchAdoption.claimsTheReply(
            isNewestLaunch: true, conversationAtLaunch: "prev", conversationNow: "somewhere-else"))
    }

    @Test func startingAConversationDuringTheWaitAlsoOutranksIt() {
        // The nil → something case: no conversation when the button was
        // pressed, one by the time the agent arrived.
        #expect(!LaunchAdoption.claimsTheReply(
            isNewestLaunch: true, conversationAtLaunch: nil, conversationNow: "answered-someone"))
    }

    @Test func anOlderLaunchNeverClaimsOverANewerOne() {
        // Two presses of + NEW AGENT. Registration order is Terminal's
        // business, not yours: the launch you started LAST is the one you are
        // waiting on, whichever comes up first.
        #expect(!LaunchAdoption.claimsTheReply(
            isNewestLaunch: false, conversationAtLaunch: nil, conversationNow: nil))
        // Not even when everything else about it still looks current.
        #expect(!LaunchAdoption.claimsTheReply(
            isNewestLaunch: false, conversationAtLaunch: "prev", conversationNow: "prev"))
    }
}
