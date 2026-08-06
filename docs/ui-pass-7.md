# UI pass 7 — seven rulings on the panel

Baseline 0f2057f (voice-roster pane), 152 Core tests. App layer only —
PanelState, StateLegend, StatusHUD, main.swift — no Core change. Composes
with the ladder cycle (8fecb52: MESSAGE re-heard after WHY) and the
simplification pass (docs/simplification-pass.md).

## The rulings, change by change

1. **"Go to session" → "Go to agent".** The button and every user-facing
   "session" noun ON THE PANEL now says agent: the button title, the
   go-to failure bodies ("That agent is no longer running…", "That
   agent's tab isn't open…"), the empty state ("Agents appear here as
   they finish."), the `+ NEW AGENT` placard
   (`StateLegend.newAgentTitle`), the roster-pane note ("agents draw a
   durable voice in roster order"), and the panel cards main.swift
   paints ("That reply lost its agent", "That page's agent isn't in the
   log", "Couldn't start an agent", "New agent is waiting on a prompt in
   Terminal"). **Scope note:** the right-click MENU still says "New
   session" / session in log lines — the ruling named the panel;
   internal identifiers (`goToSession`, `sessionRows`, `sessionId`) are
   code, not UI, and keep their names.

2. **The button persists through the entire ladder.** The ⌃⌃ rung path
   passed `pid: nil` to `showAnnouncement`, and the baseline hides the
   button when the target has no pid — so "Go to agent" vanished the
   moment the walk began. Every rung now resolves the agent's live pid
   through the same probe the base announcement uses
   (`ClaudeAgentsCLI().sessions()`, cached by the intake tick) and
   passes it through. Verified in the `depth1` pose: the button is on
   the WHY rung.

3. **Promoted styling.** Still in the bottom action row, still flat, no
   lozenge — presence comes from ink and placement: letterspaced caps
   `GO TO AGENT ›` in `Palette.ready` (the go-green the lamps and the
   countdown fill already own), right-aligned alone against the row's
   trailing edge (the quiet context actions — Don't send, Cancel, Retry
   — keep the left edge). The action row now spans the content column
   (348) so the trailing gravity is a real edge. Judgment: caps at
   10.5/+1.3 tracking matches the grid's placard voice (NEW AGENT, the
   AGENTS strip), so the button reads as an instrument control rather
   than prose; green + the › glyph make it the card's one obvious exit.

4. **Topic always on its own line.** `renderTitle` renders identity
   (mono 13 semibold, ink) as line one and the topic (system 12,
   secondary) from line two — joined by `\n` in one attributed string,
   each line with its own truncating paragraph style;
   `titleLabel.maximumNumberOfLines = 2`. Never a same-line
   continuation. Faces with no topic (readback, failure, empty state)
   are unchanged single-liners.

5. **The dictation receipt is back.** New `PanelState.receipt` (log name
   `receipt` — never `result.failed` for a success), new
   `Situation.delivered` pill ("▶ Delivered"), new
   `StatusHUD.showDictationReceipt`. Dictation success shows "Typed
   into ⟨app⟩." or "Copied to clipboard: “⟨first 80 chars⟩”" — the card
   exists because it names where the words went, which nothing else
   does. `.transcribing` admits `.receipt`; the receipt allows no
   ambient stomp, and returns to the grid on ruling 14's 4s clock
   (`scheduleReturnToGrid` now dwells on `.speaking` OR `.receipt`).
   **Reply-send success stays silent** exactly as ruled in the
   simplification pass — this is the only success-shaped card.

6. **Karaoke starts unspoken.** `render()`'s `.speaking` arm ends with
   `highlight(upTo: 0)`: the card's text first paints entirely in the
   faint treatment (ink at 0.35), and full ink arrives only word-by-word
   with the voice. Kills the all-dark flash between the card appearing
   and the first word event. Applies to the base announcement and every
   ladder rung (both live in `.speaking`); the pose driver's frozen
   mid-highlight stills are unaffected (they highlight after posing).

7. **⌃⌥ = home first.** See the table.

## ⌃⌥ semantics — old vs new

| Panel state       | Old ⌃⌥                                   | New ⌃⌥                                          |
| ----------------- | ---------------------------------------- | ----------------------------------------------- |
| speaking (base announcement or ANY ladder rung) | dismiss current + announce next | **home**: stop speech, return to the grid; nothing advances (log `⌃⌥: home`) |
| pendingSend (readback) | commit the send, then announce next | unchanged: commit-and-advance (log `⌃⌥: next`)  |
| listening (mic open) | ignored                               | unchanged: ignored                              |
| transcribing      | ignored                                  | unchanged: ignored                              |
| idle grid / empty / hidden | announce next                   | unchanged: invite the next agent (log `⌃⌥: next`) — this is how a hail's "go ahead" resolves, since the hail surfaces the grid |
| result (failure card) / receipt / preparing / settings | announce next | unchanged (log `⌃⌥: next`)     |

Home advances NOTHING: no dismissal, no markHeard, no next
announcement. Core writes nothing before the audio (Coordinator.speak:
"nothing is written before the audio"), so a mid-speech home leaves the
turn unread and its grid row lit; a card that had finished speaking was
already heard and stays heard. `activeConversation` survives home — you
just heard that agent, and a hold-⌥ reply from the grid still addresses
it, same as ruling 14's automatic return.

**Rapid double-press = next agent**: no special mechanism — the first
press lands on the grid, and from the grid the second press invites the
next agent. The old dismiss-on-advance is gone (it is unreachable:
advancing can no longer happen FROM the speaking card).

## How ⌃⌥ composes with the ladder cycle (8fecb52)

The ladder walks FINDINGS → SOLUTION → WHY → MESSAGE re-heard → repeat,
one rung per ⌃⌃. Every rung is a `.speaking` card, so ⌃⌥ from any rung
EXITS the walk to the grid; it never advances the walk — ⌃⌃ is the only
gesture that moves the ladder. The walk's position (`ladderIndex`) is
deliberately NOT reset by home: `lastAnnouncement` survives, so a later
⌃⌃ resumes the walk at the next rung (a new announcement still resets
it, as before). Exiting is leaving the room, not burning the ladder.

## Judgment calls

- **Mid-speech double-press re-offers the same agent.** Home on an
  UNFINISHED announcement leaves it unread (ruled: "no cursor advance
  beyond what already happened"), and unread-and-newest is what the
  queue offers first — so ⌃⌥⌃⌥ mid-speech stops the card and then
  re-announces it. That is the ruling's own arithmetic; a true
  "skip past it" is ⌃⇧ dismiss, exactly as before. From a FINISHED card
  (the common case: the card holds after speech) double-press reaches a
  genuinely different agent.
- **The receipt's dwell reuses ruling 14's 4s clock** rather than the
  old Sent face's bespoke auto-hide: one return-to-grid mechanism, two
  card states. Any gesture cancels the return, as everywhere.
- **The receipt has no title.** Dictation is exactly the path with no
  agent, so the Delivered pill + body carry the whole story; a stale
  `currentTarget` label would be a lie.
- **Menu wording keeps "session"** (scope: the ruling said panel). Flag
  for a future ruling if the split reads as drift.
- **`GO TO AGENT ›` on readback/listening** renders right-aligned green
  like everywhere else — the promotion is baseline styling, not
  per-face.

## Verification

- `swift build` + `swift test` green: 152 XCTest + 7 swift-testing, 0
  failures. No Core file touched.
- `--selftest-hud`: all states + the new `receipt` state render; both
  legality checks pass (idle-over-listening refused; pendingSend
  cancellable for life). Matrix gains the `receipt` row.
- Poses: `receipt` added to the driver. Re-posed into scratchpad
  `state-shots-v3/` (window-id capture): grid, empty, speaking, depth1,
  receipt, readback, listening — speaking/depth1 show the two-line
  title, faint-start karaoke, and the green right-aligned button; the
  WHY rung shows the button (ruling 2); receipt shows "▶ Delivered" +
  the clipboard text; grid shows `+ NEW AGENT`.
- Relaunched from a clean worktree build of HEAD per the multi-session
  protocol; single instance verified.
