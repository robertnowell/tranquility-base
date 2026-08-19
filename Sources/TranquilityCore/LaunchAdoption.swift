import Foundation

/// Whether a launch that has just registered may claim the reply routing.
///
/// The destination follows the LAUNCH, not the card (ruled 19 Aug). Before
/// that, a launched agent became your reply target only inside the branch
/// where `StatusHUD.bindGreeting` succeeded — so anything that took the stage
/// during the five-to-nine seconds a session needs to register cost the new
/// agent its destination, silently. A microphone fault did exactly that at
/// 15:35:57: the error card replaced the greeting card, the session that
/// registered three seconds later was refused its binding, and every word
/// spoken afterwards was typed into the previous agent, in another repository.
///
/// Binding a card is a question about the panel. Where your words go is not.
///
/// But following the launch must not mean overriding you, which is why this is
/// a decision with a name rather than an unconditional assignment. Two things
/// can be true between pressing + NEW AGENT and the agent existing:
///
///   · you pressed it again — a second launch supersedes the first, and the
///     older one must not claim the destination just because it happened to
///     register second;
///   · you moved on — a lamp press or a ⌃⌥ is an explicit statement about
///     where your attention is, and an explicit statement outranks a launch
///     you started before making it.
///
/// Pure, in Core, and tested: the app layer has no unit tests, and this rule is
/// about attention rather than about drawing, so it does not need a panel to
/// be checked.
public enum LaunchAdoption {
    /// - Parameters:
    ///   - isNewestLaunch: this launch is still the one `pendingLaunch` names.
    ///   - conversationAtLaunch: the session you were in when the button was
    ///     pressed, or nil if you were in none.
    ///   - conversationNow: the session you are in as the agent registers.
    public static func claimsTheReply(isNewestLaunch: Bool,
                                      conversationAtLaunch: String?,
                                      conversationNow: String?) -> Bool {
        guard isNewestLaunch else { return false }
        return conversationAtLaunch == conversationNow
    }
}
