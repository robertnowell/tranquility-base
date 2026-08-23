import XCTest
@testable import TranquilityCore

/// The 23 Aug send bug: two readings of "the TUI echoes a paste", both wrong.
///
/// Every screen below is a VERBATIM `capture-pane -p` of a live Claude Code
/// v2.1.241 in a 120x40 tmux pane, taken while reproducing the failure — not
/// a hand-written approximation of one. That distinction is the whole
/// lesson: the transport passed a 100/100 validation run and a live 3/3
/// because every payload those used was short enough to render on one line.
final class PasteEchoTests: XCTestCase {

    /// The utterance that failed to send, flattened exactly as
    /// `DispatchText.flatten` hands it to the transport.
    static let payload = "Okay, this is interesting. The reusable method, collinearity, that is to say, are they coupled in their send patterns? What percentage of the audience is actually sent each time? Yeah, the efficiency gradient. What's the difference? What difference does it make? I don't know what the difference is between the efficiency gradient and differentiability. Per segment revenue per recipient width against baseline measured only on sends where the segment is the audience. I actually don't understand what that means. Segment carried along in a blast tells you about the blast. This, the step that went wrong in the first run. Segments are near collinear measured. Yeah. Basically, more segments doesn't mean many more people because they kind of cover most people. Yeah, really what, what matters is the VIP. Hey, can we update the incorrect? It seems like, uh, Mirai, the same method finds nothing, and that finding too. That is the finding no structure. First of all, I think we've got some weird spacing issues. I see finding no with no space between it. I also see the method reusable as one word. It's weird. Not one ruled. One ruled is missing a space. I don't know what's going on there. But anyway, It seems like we say something and then correct it in the next paragraph. We just get rid of the incorrect claim. Yes, uh, collections, not products. That's right. Make the 4 measurements a stage of the brand audit. So whatever we did to conduct this analysis, it needs to be baked into the campaign analysis. So we can do this automatically. 2 buckets are the floor. I agree, VIP and standard. Presumably they have some VIP segment, right? Rank collections, not products, and only one within a bucket. I want to see some numbers around this, actually. Rank collections. How do you rank collections versus products? Treat bucket A and B slots as evidence generation. I don't know what. Bucket A and B slots, 7th generation. Um. Yeah, anyway, yeah, this is a good analysis. This is kind of what I had in mind. Let's proceed with the product and collection analysis because I think that's a little thin on this. Because I don't actually see the products. Sorry, the collections that are ranked per segment in Augmented. So obviously we need to do that analysis by hand before we bake it in. So let's do that analysis by hand. And then plan out how we bake in both the segment analysis and the products per segment analysis into the brand doc."

    /// Verbatim capture after pasting `payload`: the TUI drew a chip instead.
    static let collapsedScreen = [
        "╭─── Claude Code v2.1.241 ─────────────────────────────────────────────────────────────────────────────────────────────╮",
        "│                                                    │ Tips for getting started                                        │",
        "│                  Welcome back rob!                 │ Ask Claude to create a new app or clone a repository            │",
        "│                                                    │ ─────────────────────────────────────────────────────────────── │",
        "│                       ▐▛███▛█                      │ What's new                                                      │",
        "│                      ▝▜██████▀                     │ Bug fixes and reliability improvements                          │",
        "│                        ▝▝ ▝▝                       │ Bug fixes and reliability improvements                          │",
        "│ Haiku 4.5 · Claude Max · jknowlesaroni@gmail.com's │ Cost estimates (`/cost`, status line, `--max-budget-usd`) now … │",
        "│ Organization                                       │ /release-notes for more                                         │",
        "│                /…/scratchpad/probes                │                                                                 │",
        "╰──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯",
        "",
        " ⚠ 1 MCP server needs authentication · run /mcp",
        "",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "❯ [Pasted text #1]",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "  paste again to expand                                                           auto mode unavailable for this model",
        "                                                                                                                   /rc",
    ].joined(separator: "\n")

    /// Verbatim capture with the same payload drawn in full, across 22 rows.
    static let expandedScreen = [
        "│                                                    │ Tips for getting started                                        │",
        "│                  Welcome back rob!                 │ Ask Claude to create a new app or clone a repository            │",
        "│                                                    │ ─────────────────────────────────────────────────────────────── │",
        "│                       ▐▛███▛█                      │ What's new                                                      │",
        "│                      ▝▜██████▀                     │ Bug fixes and reliability improvements                          │",
        "│                        ▝▝ ▝▝                       │ Bug fixes and reliability improvements                          │",
        "│ Haiku 4.5 · Claude Max · jknowlesaroni@gmail.com's │ Cost estimates (`/cost`, status line, `--max-budget-usd`) now … │",
        "│ Organization                                       │ /release-notes for more                                         │",
        "│                /…/scratchpad/probes                │                                                                 │",
        "╰──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯",
        "",
        " ⚠ 1 MCP server needs authentication · run /mcp",
        "",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "❯ Okay, this is interesting. The reusable method, collinearity, that is to say, are they coupled in their send",
        "  patterns? What percentage of the audience is actually sent each time? Yeah, the efficiency gradient. What's the",
        "  difference? What difference does it make? I don't know what the difference is between the efficiency gradient and",
        "  differentiability. Per segment revenue per recipient width against baseline measured only on sends where the segment",
        "  is the audience. I actually don't understand what that means. Segment carried along in a blast tells you about the",
        "  blast. This, the step that went wrong in the first run. Segments are near collinear measured. Yeah. Basically, more",
        "  segments doesn't mean many more people because they kind of cover most people. Yeah, really what, what matters is",
        "  the VIP. Hey, can we update the incorrect? It seems like, uh, Mirai, the same method finds nothing, and that finding",
        "  too. That is the finding no structure. First of all, I think we've got some weird spacing issues. I see finding no",
        "  with no space between it. I also see the method reusable as one word. It's weird. Not one ruled. One ruled is",
        "  missing a space. I don't know what's going on there. But anyway, It seems like we say something and then correct it",
        "  in the next paragraph. We just get rid of the incorrect claim. Yes, uh, collections, not products. That's right.",
        "  Make the 4 measurements a stage of the brand audit. So whatever we did to conduct this analysis, it needs to be",
        "  baked into the campaign analysis. So we can do this automatically. 2 buckets are the floor. I agree, VIP and",
        "  standard. Presumably they have some VIP segment, right? Rank collections, not products, and only one within a",
        "  bucket. I want to see some numbers around this, actually. Rank collections. How do you rank collections versus",
        "  products? Treat bucket A and B slots as evidence generation. I don't know what. Bucket A and B slots, 7th",
        "  generation. Um. Yeah, anyway, yeah, this is a good analysis. This is kind of what I had in mind. Let's proceed with",
        "  the product and collection analysis because I think that's a little thin on this. Because I don't actually see the",
        "  products. Sorry, the collections that are ranked per segment in Augmented. So obviously we need to do that analysis",
        "  by hand before we bake it in. So let's do that analysis by hand. And then plan out how we bake in both the segment",
        "  analysis and the products per segment analysis into the brand doc.",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "  ⏸ manual mode on                                                                auto mode unavailable for this model",
        "                                                                                                                   /rc",
    ].joined(separator: "\n")

    // MARK: the collapsed paste — the bug itself

    func testALargePasteIsNowhereOnScreenAtAll() {
        // The whole failure in one assertion. Claude Code renders a paste
        // over ~800 characters as a chip instead of the text (measured 23
        // Aug: 800 literal, 810 collapsed), so the old landing check —
        // `screen.contains(payload)` — could never pass, no Return was ever
        // sent, and 2,444 dictated characters sat in the box while the
        // panel said "couldn't confirm it landed."
        XCTAssertFalse(Self.collapsedScreen.contains(Self.payload))
        XCTAssertEqual(TmuxTransport.pasteChips(
            screen: Self.collapsedScreen, glyph: "❯", chip: "[Pasted text #"),
            ["[Pasted text #1]"])
    }

    func testOurOwnChipReadsAsOurOwnUnsubmittedText() {
        // Attempt 2 arrives to find our chip on the floor. Recognising it
        // is what turns five wasted pastes into one Return.
        XCTAssertEqual(TmuxTransport.classifyPromptLine(
            screen: Self.collapsedScreen, payload: Self.payload,
            chip: "[Pasted text #", ourChips: ["[Pasted text #1]"]),
            .holds(ours: true))
    }

    func testAChipThisSendDidNotDrawIsStillSomebodyElsesFloor() {
        // The safety half. A chip is ours only because we watched it
        // appear — never because it merely LOOKS like a chip. A paste the
        // human made before we arrived must still hold the floor, or this
        // fix would press Return under somebody else's unsent message.
        XCTAssertEqual(TmuxTransport.classifyPromptLine(
            screen: Self.collapsedScreen, payload: Self.payload,
            chip: "[Pasted text #", ourChips: ["[Pasted text #7]"]),
            .holds(ours: false))
        XCTAssertEqual(TmuxTransport.classifyPromptLine(
            screen: Self.collapsedScreen, payload: Self.payload,
            chip: "[Pasted text #"),
            .holds(ours: false))
    }

    func testChipsAreReadWholeSoTwoOfThemAreTellableApart() {
        // The prefix is shared; the counter is the identity. Matching only
        // the prefix would make attempt 3's chip indistinguishable from
        // attempt 2's, and "did MY paste land" unanswerable again.
        let screen = "────\n❯ [Pasted text #10] [Pasted text #11]\n────"
        XCTAssertEqual(TmuxTransport.pasteChips(
            screen: screen, glyph: "❯", chip: "[Pasted text #"),
            ["[Pasted text #10]", "[Pasted text #11]"])
    }

    func testCodexCollapsesTooAndWearsItsOwnChip() {
        // Measured live 23 Aug against codex-cli in the same pane geometry:
        // 1,000 characters render literally, 1,024 collapse to
        // `[Pasted Content NNNN chars]`. Same defect class, different
        // clothes — which is why the chip is a harness capability and not a
        // constant in this file.
        let screen = "────\n› [Pasted Content 1500 chars]\n────"
        XCTAssertEqual(TmuxTransport.pasteChips(
            screen: screen, glyph: "›", chip: "[Pasted Content "),
            ["[Pasted Content 1500 chars]"])
        XCTAssertEqual(TmuxTransport.classifyPromptLine(
            screen: screen, payload: Self.payload, glyph: "›",
            chip: "[Pasted Content ", ourChips: ["[Pasted Content 1500 chars]"]),
            .holds(ours: true))
    }

    func testNoChipConfiguredChangesNothing() {
        // Opt-in per harness, like the glyph and the idle placeholder
        // before it: a target with no measured chip behaves as it always did.
        XCTAssertEqual(TmuxTransport.pasteChips(
            screen: Self.collapsedScreen, glyph: "❯", chip: nil), [])
    }

    // MARK: the wide paste — the same defect, one size down

    func testAWidePayloadIsFullyVisibleAndStillFailsContains() {
        // Below the collapse threshold the text IS drawn — across 22 rows
        // the TUI lays out itself, each indented under the glyph. Those are
        // not soft wraps, so `capture-pane -J` does not join them either
        // (verified: byte-identical result with and without -J). `contains`
        // fails on a payload the user can plainly see, which is why this
        // case only ever worked by accident, on attempt 2, via the
        // truncated-prefix rule — one wasted attempt every long reply.
        XCTAssertFalse(Self.expandedScreen.contains(Self.payload))
        XCTAssertEqual(TmuxTransport.boxRows(
            screen: Self.expandedScreen, glyph: "❯")?.count, 22)
        XCTAssertTrue(TmuxTransport.boxHolds(
            payload: Self.payload, screen: Self.expandedScreen, glyph: "❯"))
    }

    func testTheBoxMustHoldOurPayloadAndNothingElse() {
        // Equality, not containment. A box holding our words PLUS somebody
        // else's is exactly the splice `.holds(ours: false)` exists to
        // refuse; accepting it here would let this fix press Return under a
        // spliced message.
        let screen = "────\n❯ send it now and also rm -rf /tmp\n────"
        XCTAssertFalse(TmuxTransport.boxHolds(
            payload: "send it now", screen: screen, glyph: "❯"))
        XCTAssertTrue(TmuxTransport.boxHolds(
            payload: "send it now and also rm -rf /tmp", screen: screen, glyph: "❯"))
    }

    func testTheBoxStopsAtItsOwnBorder() {
        // The rows below the box — the mode line, the hint line — are
        // indented like continuations. Reading them as box content would
        // make `boxHolds` fail on every real screen.
        let screen = "────\n❯ hello\n────\n  ⏸ manual mode on · ← for agents"
        XCTAssertEqual(TmuxTransport.boxRows(screen: screen, glyph: "❯"), ["hello"])
    }

    // MARK: the capability that was half true

    func testBothAdaptersDeclareTheirMeasuredChip() {
        // `echoesPaste: true` was never wrong, only incomplete — and the
        // part it left out is the part that broke. What the transport
        // believes about echo now has to name HOW each harness echoes.
        XCTAssertEqual(ClaudeCodeAdapter().capabilities.pasteChipPrefix, "[Pasted text #")
        XCTAssertEqual(CodexAdapter().capabilities.pasteChipPrefix, "[Pasted Content ")
    }

    func testDispatchTargetDefaultChipIsClaudeCodes() {
        // The same co-existence guarantee every other harness field carries.
        XCTAssertEqual(DispatchTarget(sessionId: "s").pasteChip, "[Pasted text #")
    }
}
