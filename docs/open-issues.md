# Open issues — voice dispatch

Live tracker. Nothing gets closed here without evidence: a log line, a query, or a
test. Ordered by how much damage the bug does, not by how easy it is.

Companion to `docs/state-machine.html`, which maps every state against every input.

---

## 1. Headless sessions flood the queue — ROOT CAUSE OF THE "SAME MESSAGE" LOOP

**Status:** open. This explains three separate symptoms that looked unrelated.

`content-engine` is a launchd job running `claude -p`. **Every run is a new session
id**, so supersession — which collapses older turns *within a session* — never fires.
Ten runs produce ten unread rows carrying near-identical summaries.

That is why:

- dismissing the announcement left the count unchanged (other rows remained),
- pressing again replayed "the same message" (a different row, same text),
- the count said 2 while only 1 row was genuinely unread at the moment of the query.

There is no tab to open and no session to answer, so these should never be announced.

**Why it is not already fixed:** the hook filter was removed on purpose. Two attempts
were wrong — `$PPID` is not reliably the claude process, and walking the ancestry
crosses the session boundary — and both silently dropped *real* turns. The hook is
the one place where being wrong is unrecoverable.

**Built so far:** the `tty` column, the model field, the filter in every selection
path and in the badge, and tests pinning both directions. All of it is safe: a NULL
tty means *unknown* and is never filtered, so nothing can be silently lost.

**Measured, and this is where it stands:**

| source | recorded tty |
|---|---|
| real `claude -p` (setsid, no terminal) | `??` |
| same hook under a pty (`script`) | `ttys147` |
| **hooks spawned by real Claude Code sessions** | **NULL — empty, not `??`** |

So the discriminator works in a lab and does not fire in the field: real sessions
report nothing at all, which the filter correctly treats as unknown. The filter is
therefore inert today rather than wrong.

**Next:** `$$`'s tty is not available to a claude-spawned hook. Read
`CLAUDE_CODE_ENTRYPOINT` from the hook environment instead — a probe hook is written
at `/tmp/probe-hook.sh` but never fired, because project-level `.claude/settings.json`
was not picked up for `-p`. Install the probe in user settings and read one real
value from each path before choosing the signal. Do not ship a third guess.

**Lead from PR #1 (head a05f253, closed):** `kind` from `claude agents --json` is a
first-party discriminator — `"background"` sessions are hosted by
`claude --bg-pty-host` with no tab and no supported IPC, exact correlation across 11
live sessions in that branch's testing. `targetKind` already flows through dispatch
(Coordinator.swift:575). The PR also confirmed the `tty` column records `??` for
*every* session now, so a filter keyed on it would drop real turns: the tty approach
is dead, `kind` is the fourth guess that finally has evidence behind it.

---

## 2. Ambient surfacing did not fire for a superseding turn — FIXED

**Status:** fixed, verified by experiment.

The mechanism was working; the trigger was wrong. Surfacing fired on the waiting
COUNT changing, which misses the commonest case there is: a session taking several
turns in a row. Each new turn supersedes the previous, so the count goes 1 to 1 and
nothing repaints.

Proven rather than argued. Two turns were injected for one session with the panel
idle:

- turn A (new session, count 0 to 1) — surfaced;
- turn B (same session, supersedes A, count 1 to 1) — **nothing**, `a1` went
  superseded and `a2` went new and the panel never moved.

The trigger is now "rows were inserted", which is what "a turn came back" actually
means. Re-run against a settled baseline: a superseding turn surfaces.

---

## 3. Repeated ⌃⌥ replays the item you are listening to

**Status:** mostly dissolved by redesign; residual behaviour is deliberate.

The loop existed because ⌃⌥ went straight from item to item. Under home-first
(ui-pass-7 ruling 7, `main.swift` next-handler): ⌃⌥ mid-speech stops the voice and
returns to the *grid* — the stopped item stays unread and its row lit, and the way
past it is now on screen: tap any other row. A second ⌃⌥ from the grid does play the
top of the stack again, but that is the stack being honest, not a trap. Close for
good when dogfood confirms nobody hits it in anger.

---

## 4. Slow transcription looks like a hang

**Status:** open, exposure much reduced.

A 27-second recording took long enough that the panel sat on "Transcribing your
reply…" with no feedback. It completed — 401 characters — so nothing was lost, but
there was no way to know that.

Streaming transcription (AssemblyAI, WS-C) now carries the common case: text is
already transcribed when you release the key. The wait only survives on the recovery
path (stream failed, file re-transcribed). The fix there is unchanged (Wispr's):
after ~20s say "taking longer than usual, your audio is safe", with retry and
cancel. The audio is durable on disk before any network call, so that promise is
true today and just unstated.

---

## 5. Escape is dead in three states — CLOSED BY REDESIGN

**Status:** closed. Escape is no longer a control at all: dismiss is the ⌃⇧ chord
(`main.swift:824` — "a chord because Escape leaks ESC" into the focused app), and
every guard that made Escape unreliable now derives from `PanelState` instead of
the five booleans. The bug was real; the key it lived on was removed.

---

## 6. ⌃⌥ while the microphone is open — FIXED

**Status:** fixed, wired, guarded in two places. `guard !hud.isCapturingAudio`
in the announce handler and the next-handler (`main.swift:764`, `:892`), and the
stage arbiter refuses any paint over a capture state as a second line of defence
(capture states own the stage — `PanelState.admits()`).

---

## 7. ⌥ with nothing to reply to — CLOSED BY REDEFINITION

**Status:** closed. "Refuse at the gesture" was the wrong fix and is deliberately
not wired (`main.swift` reply-handler comment): with nothing to answer, ⌥ is
**dictation** — the transcript goes to the focused input or the clipboard, and the
listening placard says which. Refusing would have broken dictation-to-clipboard,
reply-window replies from an idle panel, and re-recording during transcription.
The router that names the destination up front is A6 (`micDestination`), still on
the program board.

---

## 8. ⌃⌥ during the send window

**Status:** needs a decision, not a fix.

Today: a new announcement starts and the countdown keeps running, so the reply sends
while a new summary plays. Either the countdown wins and the tap is ignored, or the
tap cancels the send. No obviously correct answer.

---

## 9. Summaries invent numbers — FIXED

**Status:** fixed exactly as prescribed. `DigitGrounding.swift`: no spoken number
that does not appear in the source, applied in `Summarizer` and pinned by tests
(`Phase1bTests`). The "ninety-nine tests" class of embellishment cannot reach the
voice.

---

## 10. Housekeeping (repo is public now)

- `model-calls.jsonl` grows without bound and holds full session content. Needs
  rotation and a cap. Same now applies to `app.log`, which records dictated text
  when the Apple recovery engine runs (disclosed in README).
- ~~Clicky's MIT copyright belongs in a NOTICE~~ — done, `NOTICE` exists at root.

---

## 11. Gestures permission — RESOLVED by measurement: BOTH are required

**Status:** closed 08 Aug, the opposite way round from how it was closed on the 7th.

The 7th's reasoning: a `.listenOnly` tap is authorised by Accessibility OR Input
Monitoring; `FocusedInput` needs Accessibility regardless to type at the cursor;
therefore Input Monitoring contributes nothing and was deleted. Apple's docs and
the community sources agree with that reasoning.

It is wrong. Measured with a probe carrying its own bundle id (inheriting no
grants) while a second process posted a keystroke every 400ms, so that "no
events" could not be confused with "nobody typed":

| condition | listenEventAccess | tapEnabled | events received |
|---|---|---|---|
| no permissions | false | false | 0 |
| **Accessibility only** | **false** | **false** | **0** |
| + Input Monitoring | true | true | 17, then 5 |

Accessibility alone leaves the tap created but DISABLED and silent — the exact
silent-denial failure that made the app look broken in the first place, and the
one a new user would have hit on day one.

The third row is the positive control, and it is the row that makes the second
one mean anything: until the probe was seen SUCCEEDING, "zero events" could
equally have been a defect in the probe. Nothing changed between rows two and
three except the one switch.

**Both are required.** Input Monitoring carries the gestures; Accessibility
carries dictation-at-cursor. Neither may be dropped again without repeating that
experiment; the probe is worth rebuilding rather than trusting this note.

Incidental finding worth keeping: because the app is signed with a real
development identity, its TCC grants key to identity + bundle id rather than
path, so they survive every rebuild and rename — and the Settings panes hide the
rows when the recorded path no longer exists. An app can therefore hold a
permission that appears nowhere in System Settings, which is exactly how this
question stayed unanswerable for so long.

## 12. Signing scripts for machines without a dev cert (from PR #1)

**Status:** open, nice-to-have until the repo has outside users.

`bundle.sh` uses an Apple Development identity when one exists (why grants survive
rebuilds on this machine) but falls back to ad-hoc with a warning. Ad-hoc means the
designated requirement is the binary's own cdhash: every rebuild is an app macOS
has never seen, and every TCC grant silently dies — while the Privacy pane still
shows the switch ON. Near-undiagnosable; full analysis preserved in
`docs/pr1-harvest.md`. PR #1 shipped `make-signing-identity.sh` (create a stable
local cert, no Xcode) and `reset-permissions.sh` (recover when an identity does
change); `bundle.sh` *created* the identity rather than warning. Port both scripts
before any release.

---

## 13. Sending gives no visible receipt (ruled 06 Aug)

**Status:** ruled, to build.

On success the only feedback is `lastStatusLine` — rendered as a disabled item
inside the menu-bar dropdown, i.e. invisible. Failures do surface as cards, but a
user who has never seen one has no reason to trust that. Robert's ruling: a small
non-blocking acknowledgment at the top — "sending to ⟨callsign⟩ → sent ✓" — not a
dedicated card, not a stage owner; errors keep their cards. Supersedes the earlier
"kill the Sent face" ruling in its spirit: that killed a *blocking* card, this is
a whisper. Design goes through the render funnel as a transient overlay (like
`flashAcknowledge`), never a `PanelState`.

---

## Landed: the state machine

The five independent booleans became `PanelState` + the stage arbiter
(`admits()` legality table), then the eleven painters became one `render()` funnel.
Issues 5, 6 and 7 above were closed by exactly the mechanism this section promised.
History: `docs/state-architecture.html`, `docs/3a-collapse.md`.
