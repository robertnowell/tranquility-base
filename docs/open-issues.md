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
`acknowledge(_:)`), never a `PanelState`.

---

## 14. "Go to session" freezes the whole app — beach ball, hard restart (12 Aug) — CLOSED

**Status:** CLOSED 13 Aug, all three carriers, each by evidence.

- The button — PR #26: `goToSession()` paints its receipt and returns in 0 ms
  (drilled on every deploy: `goToSession` + `goToSession.roundTrip`), the walk
  runs in a detached task on a 5 s deadline, and the per-tab Apple-event loop
  became ONE batched `tty of tabs of windows` fetch — measured against the same
  192 live tabs: 3.54 s → 179 ms, ~20×. Confirmed in the wild: real clicks log
  `focused` on the new path.
- The tick (the nested blocker in the same spindump) — PR #40: `rebuildMenu()`
  and the settings pane read `SystemVoiceCatalog.cachedRows()`, a
  stale-while-revalidate snapshot that refreshes off-thread, single-flight;
  no reader ever waits on the TTS daemon or the four asset plists again.
  Drilled every deploy (`voiceMenu.cacheWarm`; warm rebuild measured 19 ms),
  and proven the way rule 4 likes it: a 5 s `sample` of the deployed build
  mid-ticking — 3,980 main-thread samples, `rebuildMenu` present, ZERO frames
  of `speechVoices` / `SystemVoiceCatalog` / `semaphore_wait` / `waitUntilExit`
  on any thread.
- The arrival path — PR #40: the frontmost-tab skip's three subprocesses
  (osascript, claude CLI, ps) run detached with a 2 s Apple-event deadline,
  generation-guarded so the newest arrival wins; Terminal-not-frontmost keeps
  the fully synchronous path, byte-identical behavior.

One drill lesson paid for along the way (PR #43): the first `voiceMenu` drill
read `statusItem.menu`, which is deliberately nil outside a right-click — the
deploy gate refused two relaunches on a passing feature. Assert against where
state actually lives (`statusMenu`), and thank the gate for catching it.

Original record, kept because the spindump reading is the reusable part:

Damage was top-tier: the app beach-balled for minutes, racked up 11 hang reports
in one afternoon, and Robert hard-restarted it — and because the CGEvent-tap
watchdog disables the tap after ~1s of main-thread block, every freeze also
silently killed the global hotkeys while it lasted.

**Evidence:** `/Library/Logs/DiagnosticReports/TranquilityApp_2026-08-12-124315_Roberts-Mac-2.spin`
(pid 42655, 12:39 PT). Main thread pinned for 465 of 477 samples inside
`StatusHUD.goToSession()` (StatusHUD.swift:3894) → `AppleScript.run`
(DispatchTransport.swift:279) → `-[NSConcreteTask waitUntilExit]` on `osascript`.
The script loops every Terminal window and tab sending one `tty of t` Apple event
per tab; Apple events to a busy app block up to the 2-minute default timeout *per
event*, and Terminal was churning a huge Claude scrollback across a dozen tabs.
Each re-click stacked another hang (Recent hangs went 8 → 11 under observation).

Nested second blocker in the same capture: `waitUntilExit` pumps the run loop, so
the permission-poll timer fired `AppDelegate.refresh()` → `rebuildMenu()`
(main.swift:2613) → `SystemVoiceCatalog.voices` → a TextToSpeech semaphore wait —
a second synchronous wait on main, inside the first.

Latent deadlock in the same helper: `AppleScript.run` drains the child's pipes
only *after* `waitUntilExit`, so a child writing more than the 64 KB pipe buffer
blocks forever, both sides waiting on each other.

**Ruled out by measurement:** the "415 GB virtual memory leak" Activity Monitor
showed during the hang. A 22-second-old fresh instance carries the identical
415.77 GB VSZ — normal arm64 address-space reservation. Real memory 211 MB,
footprint 52.8 MB. There is no leak; do not chase it again.

**Fix shape (not started):** the subprocess wait leaves the main thread entirely
— termination handler or background task, then hop back for the label writes.
Shortening the wait is not enough; the watchdog fires at ~1s. One targeted Apple
event (`first tab whose tty = X`) instead of the per-tab loop, a hard timeout in
`AppleScript.run`, pipes drained concurrently with the wait. `rebuildMenu`'s
voice-catalog scan leaves the main thread with it. `ProcessProbe.tty/name` have
the same synchronous shape and follow the same rule. This is a third evidence
line for the anti-pattern audit's item 1 (synchronous subprocess waits on main);
full spindump walk-through in the 12 Aug HQ brief.

---

## 15. ⌃⌃ ignored during active announcement playback (12 Aug)

**Status:** open, evidence gathered, root cause hypothesized but not proven.
Reported by Robert on the first minutes of the AUHAL mic build (024d60b era),
and almost certainly NOT the mic stack: a ⌃⌃ pull involves no microphone, and
the mic machine sat idle-warm throughout.

**What the log shows (21:12Z, pid 52224):** an announcement was speaking from
21:12:32 to 21:12:44. Robert pressed ⌃⌃ during it — the log has ZERO trace of
that press: no `ack: registered (blue)` (the first-tap acknowledgement), no
refusal, nothing. His second ⌃⌃ at 21:12:45 — one second after the speech
ended — registered normally and pulled the FINDINGS rung. A press the
classifier refuses still logs; a press that leaves nothing was never seen.

**Hypothesis (fits the only difference between the two presses):** run-loop
saturation during playback. The word-highlight pipeline runs a full HUD
render — `layoutSubtreeIfNeeded`, `boundingRect`, chrome/layout log lines —
per spoken word, ~15×/second on the main thread, and the CGEvent tap
delivers on that same run loop. A saturated loop delays the tap callback;
past the (~1s, undocumented) timeout macOS silently disables the tap with
`kCGEventTapDisabledByTimeout` and auto-reenables later — a window in which
key events pass through to nobody, uncounted. The 5s watchdog only logs taps
found dead at its tick, so a sub-5s silent gap is invisible today. This is
the "render throttle" item from Robert's own 12 Aug morning note, now with a
reproduction shape: gestures during speech.

**Fix shape (not started):** two independent halves. (a) Throttle the
highlight: coalesce word updates to ~10Hz and skip the full resizeToFit
per word — the label repaint needs none of it; today's per-word HUD layout
is the audit's item 1 wearing its quietest costume. (b) Make the silent
window visible: subscribe the tap callback to `kCGEventTapDisabledByTimeout`
re-enables and LOG them (the revive-and-count is one line in HotkeyMonitor),
so the next missed gesture has a timestamped culprit instead of an absence.
Measure before/after with the 21:12 shape: press ⌃⌃ mid-announcement.

---

## 16. `TruncationTests` was flaky — CLOSED (16 Aug), and it was hiding a real bug

**Resolved, and the flake was not the whole story.** Two causes, one of them
in shipping code.

**(a) The tests raced the wall clock.** Each wired test started
`Task { play(...) }` and then `Task.sleep`'d for its offset before acting —
assuming N seconds of wall clock buys N seconds of PLAYBACK. It does not:
the play Task has to be scheduled, `AVAudioPlayer(data:)` and
`prepareToPlay()` have to run, and `play()` returns before `isPlaying` flips
(the provider waits up to 500ms for that itself). Under a full-suite run
those costs land inside the test's sleep, so "stop it at 0.5s" stopped it at
0.12s. Passing alone and failing in the suite is what made it read as
nondeterminism rather than a missing barrier. Fixed with `awaitPlayback(_:
reaches:)`, which waits on the player's own `currentTime`; the wall-clock
deadline that remains exists only to fail a HUNG test.

**(b) `resume()` had a real race, and the flaky test was reporting it.**
It cleared the pause latch and then restarted the player. Since `play()`
returns before `isPlaying` flips, a loop poll landing in between saw neither
a playing player nor a paused one, exited, and called a clip the user was
still listening to `truncated` at the pause point. Under the 13 Aug read
ruling a truncation is a `failure`, so a pause-and-resume would have left the
turn unread and painted "Playback failed" over an announcement that never
stopped. `resume()` now only restarts the player and the playback loop drops
the latch once it OBSERVES playback running — measured, not assumed, the same
rule the truncation check itself is built on. Pinned by
`testResumeDoesNotBrieflyLookStopped`.

Full suite: 6 consecutive clean runs (495 tests), where it had been failing
about two in three.

**The standing lesson:** a test that fails two runs in three teaches the next
session to re-run until green — and this one had a genuine defect inside it
the whole time. The habit did not just risk waving through a future failure;
it was already waving through this one.

---

## Landed: the state machine

The five independent booleans became `PanelState` + the stage arbiter
(`admits()` legality table), then the eleven painters became one `render()` funnel.
Issues 5, 6 and 7 above were closed by exactly the mechanism this section promised.
History: `docs/state-architecture.html`, `docs/3a-collapse.md`.

## 18. A card came back with its own body highlighted — FIXED (18 Aug)

Reported from a screenshot: a Speaking card, `✓ SENT`, and the whole body in a
pale grey band nobody had dragged over. Two independent faults that read as one.

**It selected itself.** `bodyLabel` is `isSelectable` so a line can be quoted
out of a card by hand. A selectable `NSTextField` is also a valid key view, and
a text field that becomes first responder selects ALL of its text — so the two
faces that take the keyboard (the list, and settings→agents) handed it to
whatever AppKit picked, which was this label. From then on the field editor
stayed installed and every programmatic `stringValue` arrived pre-selected: a
new turn's words landed already highlighted.

Fixed by narrowing who may start a selection rather than by switching selection
off (`CardBodyLabel`): first responder is refused unless the current event is a
pointer press whose location is inside the label's own bounds. Keyboard
traversal, the window's automatic pick, and a click anywhere else are all
refused. A live selection is also dropped when the WORDS change — not on every
repaint, because `paintInk` rewrites this label once per spoken word to advance
the karaoke ink, and dropping a hand-made selection on a colour change is the
same bug pointing the other way.

**And it was unreadable when it did happen.** The panel pinned
`NSAppearance(named: .aqua)` when the console was light putty, with a comment
whose logic now argues the other way ("a dark-mode bezel sits on light putty
looking like a hole"). The console went dark on 09 Aug and the pin did not
follow, so every AppKit-drawn thing on the panel has been dressed for a light
ground on a dark one since. Measured on a non-key panel, which is every card
face:

| | selection band | text on it | contrast |
|---|---|---|---|
| `.aqua` (shipped) | `#DCDCDC` | `#C9C8BF` | **1.23:1** |
| `.darkAqua` (fixed) | `#464646` | `#FFFFFF` | 9.44:1 |

1.23:1 is below every floor in the palette — less readable than `faint`, which
is ruled decorative and forbidden for text. Note also that
`selectedTextAttributes` on the field editor does NOT reach this: measured, it
is ignored entirely while the window is not key, which is why the fix is the
appearance and not a colour.

Evidence: `selectionDrill` in the launch self-tests.

## 19. A callsign was minted that no voice can say — FIXED (18 Aug)

"promotions stlth". STLTH is a vape brand spelled without vowels on purpose; it
was the longest word in the topic, the distinctiveness heuristic is
longest-word-wins, and minting freezes for the session's life. The 06 Aug ruling
("callsigns exist to be SAID") had a de-hyphenating migration behind it and no
gate, so the same failure came back through a different door.

`Callsign.isSpeakable` is one condition — the word contains a vowel, `y`
included — applied to the directory half, the topic half, and the raw-topic
tie-break word. It is deliberately no cleverer: a consonant-run limit was the
obvious second rule and fails on real English ("strengths" carries five in a
row). Migration `v12_vowelless_callsigns` DELETES an offending row rather than
rewriting it, which un-freezes the session so it re-mints through the gate; one
row of 127 qualified.

Note what the gate does not catch, on purpose: an initialism WITH a vowel
("tvpa", "json") survives, because a voice can say it.

## 24. The signature is a door to the repository — SHIPPED (18 Aug)

Asked for directly: "let's have a Tranquility Base link to our GitHub, the
wordmark on the homepage, on the grid."

`GridFooterView`'s wordmark is a `DoorLabel` now, so it takes the cursor and the
hover step from the type rather than from a call site, and taps reach
`StatusHUD.onOpenRepository`. `StateLegend.repositoryURL` is the destination.

It goes through `BrowserFocus` like the other doors — raise the tab that already
has it rather than making tab twenty-nine — but with **`reloading: false`**,
which is the first caller for that parameter. The pages the other doors open are
rewritten by this app immediately beforehand, so reloading them is the point
(issue 22); the repository is a live page nobody here rewrote, and reloading it
would throw away whatever the user was reading.

This spends half of the 10 Aug wordmark ruling. "`Controls` brightens under the
cursor and the signature never does, so the pair reads as one live thing and one
dead one at identical contrast" — the signature is not a dead thing any more,
and a door that does not answer the pointer is exactly the secret this panel
spent the day closing. The pair still reads as two different things, by
DESTINATION rather than by liveness: `Controls` reveals the chords in place, the
signature leaves.

Drills: `signatureIsADoor`, `signatureAnswersTheCursor`, `signatureReachesTheHost`
— three, because they fail separately, and a door wired to nothing is the same
secret as a door with no cursor one layer further in.

## 26. `bottomLineHasAir` is failing the CORRECT layout — OPEN, and not what it looks like

It reads as a flaky drill. It is a flaky drill, but the flake is the symptom and
the diagnosis is inverted: **the check passes on the broken layout and fails on
the right one.** Measured 19 Aug; nothing changed as a result, and this is
written so whoever owns the bottom line does not have to re-derive it.

### The flake is real

Six runs of one unchanged binary (`--allow-second-instance --selftest-hud`, main
at 4461c0b) split 3/3 between `bottomLineAir=12.0` and `8.5`, with every other
number on the drill's own log line byte-identical — `panelH 209.0->209.0
noteW=275.5 column=352.0 lines=3 floorGap=63.0`. It is not the animating panel
bounds the neighbouring drill warns about: the author already avoided that by
measuring sibling geometry inside one settled pass, and an added multi-pass
settle never fired (`needsLayout` is false after the first pass, every time).

### What the two states actually are

Instrumenting both boxes:

| | action row | word view | measured air |
|---|---|---|---|
| A | **125.0pt** | **113.0pt** | 12.0 — **passes** |
| B | 25.0pt | 20.0pt | 8.5 — **fails** |

A is the broken one. The word is centred in a box five times its own height and
floats roughly sixty points below the body it belongs to; B is the compact row
the design describes. The 12.0 the check wants is an accident of centring inside
a tall box, so the gate is red exactly when the panel is right — and green when
it is not.

### The unbounded constraint underneath

`ControlsWordView` pins its `HoverBox` to all four edges and constrains it
`heightAnchor >= 20`. A floor with no ceiling and no preferred value: the view
has no opinion about its own height, so in a stack with vertical slack it takes
the slack. The 20 was ruled 18 Aug as a hit-target SIZE ("8pt of slack on each
side and a 20pt floor makes it the same size target on both faces"), which is a
statement about how big the target should BE, not merely how small it may get.

### What was tried, and why nothing shipped

Giving the box a `.defaultHigh` preferred height of 20 plus vertical hugging on
the action row produced 6/6 at 12.0 with the word at its ruled 20pt and the row
at 32 — the value the ruling asked for, arrived at honestly. Re-running the same
pair after trimming the instrumentation gave 4/6 at 8.5. Six-sample runs cannot
tell 50% from 33%, so that pair is unproven, and landing a half-verified layout
change into an area another session is actively working is worse than leaving
the gate red with the diagnosis written down.

**For whoever picks this up:** the fix is probably those two constraints, but it
needs a repeat count that can actually distinguish the distributions, and the
drill's expectation has to be re-derived from the ruling (6pt stack spacing +
6pt row inset = 12) rather than from whichever number the current layout happens
to produce.

## 25. The stalled row stopped naming its agent — FIXED (19 Aug)

A regression from the fix that made stall reasons visible at all. A stopped
session puts its REASON in the right column instead of an id — correct, and
ruled 16 Aug ("an id would be the one row where this column says nothing
useful") — but a reason is a sentence, and in the LIST nothing capped it.

`PastRowView` gave the name `.defaultLow` compression resistance and left the
right column at the default, so "silent for 24h, nothing written since it
started" took the whole row and the name was laid out at **zero width**. The one
row in the list that could not tell you which agent it was.

The user's reading of the original ask, which the implementation inverted:

> "The default should still be the agent name. The error message, like space
> allocation, is fine. But when you hover that row, the tooltip should show you
> the full error message."

Two changes, both needed: the right column is capped at `GridRowView.auxFraction`
(0.38, the same share the grid gives it) and drops below the name in compression
resistance, so the name is the last thing to lose space rather than the first.
The grid never had the bug because it measures one shared column across every
row and caps it; the list builds each row alone and had neither guard.

The hover half already existed — `StateLegend.hoverText` has carried the name
plus the uncut message since 18 Aug, and this face is the one that takes key
status, so its tooltips fire.

Drills: `stalledRowStillNamesItsAgent` asserts the laid-out WIDTH, not the
string — the string was right the whole time and rendered at zero points, so
every assertion about it would have passed. `theFullReasonIsReachable` pins the
tooltip that catches what the column cuts.

## 21. Obfuscation welded two words together — FIXED (18 Aug)

"Sometimes after we obfuscate variable names it removes the space between that
and the words." Reproduced first try once the right path was suspected, and the
redaction was innocent: it is the LABEL STRIP.

`Sanitizer.strippingLeadingLabels` handed the first segment to
`Callsign.strippingLabelPrefixes`, which opens with
`trimmingCharacters(in: .whitespaces)`. Correct for a whole string; wrong for a
SEGMENT, where the trailing space is the boundary with the next piece:

| source | before | after |
|---|---|---|
| `promotions: Fixed dispatchAttempts and…` | `FixeddispatchAttempts and…` | `Fixed dispatchAttempts and…` |
| spoken | `Fixeda variable and…` | `Fixed a variable and…` |

It hit the display and the ear equally, and it needed no label to fire — with
nothing to strip, the trim alone made the result differ from the original, so
the segment was rewritten shorter anyway. That is why it looked intermittent:
the visible condition is not "a label was present" but "the first segment ends
in a space and the next piece is a redaction".

The gap is restored and the guard now compares against the RESTORED string, so a
segment that only lost whitespace is left exactly as it was. Three regression
tests in `SanitizerTests`, one per branch (label stripped, no label, label is
the whole segment).

## 22. Open Report raised a stale tab — FIXED (18 Aug)

"If the report has been updated since it was originally opened, it opens the
original tab." Raising the tab is the right half — `BrowserFocus` exists so that
twenty agents do not become a wall of identical favicons — and showing the old
render of it is the wrong one. `openHub` rewrites the page immediately before
focusing, so the tab it raised was stale by construction.

`focusExistingTab` now reloads what it raises (`reload tab t of window w`, after
selecting it). Not gated on a file-date check: the answer would be "yes" almost
every time, and it would be wrong in the direction that teaches you not to trust
the door. Chrome restores scroll position across the reload. `reloading: false`
stays available; nothing needs it.

## 23. The card's title took the pointer and said nothing — FIXED (18 Aug)

The title showed a pointing hand and did not change colour. It rests at `ink`,
which was the top rung of the hover ramp, so the step function handed it back
unchanged. The amber pill and the go-green had the same silence for the same
reason.

Fixed by replacing the ramp — see `docs/ruling-the-panel-answers-the-pointer.md`
for the measurement, which also disposes of the 35%-toward-ink blend that
shipped alongside it for half an hour. `hovered` is now a fixed +8 ΔL* channel
scale: defined for every colour, the same perceptual distance everywhere, and
saturation-preserving, so the amber pill stays amber.

Three implementations of "one step brighter" existed in this file inside one
afternoon, written by sessions that could not see each other. `hoverDrill` now
asserts the PROPERTY (every ink lifts by the same ΔL* ±1, `fault` and `ready`
keep their hue) rather than a table of tiers, so the next duplicate fails the
gate instead of passing it.

## 20. Is the spoken callsign still earning its place? — CLOSED: no (18 Aug)

Ruled the same day it was raised: it is not. See
`docs/ruling-the-recap-starts-with-the-recap.md`.

Both halves failed on measurement. The project half names nothing — 23 of 127
minted signs begin "promotions", because that is where the work is — and the
voice already says who: `session_voice` assigns round-robin from a 14-voice
roster and fewer than fourteen sessions are ever live at once.

The topic half turned out to have no chooser at all: the model writes a topic
sentence and `candidateTopicWords` takes the LONGEST word in it, ties broken by
position, as a proxy for distinctiveness. That is "promotions stlth". The vowel
gate from issue 19 does not rescue it — it admits `b6y9z` and it admits
`stealthy` — and the ruling records why: **for a model-shaped failure the answer
is usually context, not a gate.** Asking for a name, told it will be spoken,
would have worked; mining prose for its longest token could not. Neither is
worth building for a name nobody hears.

`withCallsign` → `strippingModelLabels`: the prepend is gone, the strip stays and
is now the whole job (the model opens with a label 65 turns in 71, and picks the
wrong one on the miss). Minting no longer runs. Nothing is deleted — the table,
its rows, the lexicon seed, the grid's tab-less fallback and `hailText` all
stand, so bringing it back is one function.

## 17. The canary leaves its Terminal window behind — CLOSED BY DECISION

Reported 16 Aug with a screenshot: three windows piled up, each showing
"[Process was terminated by signal 15]". `scripts/canary.sh` had a cleanup
block that had never worked. It was rewritten several times, never fixed, and
then **removed**, which is the resolution.

**The question that closed it was "what are we actually trying to do here?"**
The canary's one real obligation is to leave no stray `claude` process running
against a throwaway directory. That always worked, and works now: the kill goes
by tty, which is the right handle because a tty names a device with live
processes on it. Verified after the change — no stray processes, no leftover
temp dirs. A dead Terminal tab costs no memory and no CPU.

So the cure was more dangerous than the disease. Closing the window requires a
handle on the window, and the shipped code used the tty, which macOS recycles
the instant a shell exits: four windows were measured claiming `/dev/ttys007`
simultaneously, three dead canaries and one LIVE coding session. Searching for
the first tty match and closing it could close the window somebody is working
in. That is a real hazard accepted in exchange for tidiness, and tidiness is
not worth it.

The windows persist at all because Terminal is configured to keep them:
`shellExitAction = 2` ("Don't close the window") on every profile on this
machine. The cleanup was fighting a user preference from the outside.

**If they ever must go, invert it.** Do not hunt the window. Give the canary
its own Terminal profile whose shell-exit action closes the window, launch
into that profile, and kill only the `claude` process so the shell exits on its
own. The window then closes itself and nothing has to identify it.

### What does not identify a Terminal window (so nobody re-tries these)

| handle | why it fails |
|---|---|
| tty, at cleanup | Recycled the moment a shell exits. Four windows on `/dev/ttys007` at once, three dead canaries and one live session. |
| `id of front window`, at creation | `do script` does not reliably front the new window before the next statement, so this names the PREVIOUS canary's window; each run then closes its predecessor's and leaks its own while reporting a clean close. |
| the window that appeared (set-difference) | Other sessions deploy concurrently, so the new window can be theirs. Leaked one run in three. |
| tab `contents` containing the run's temp dir | Matches any window that merely PRINTED the path, **including the session driving the canary**. Observed selecting the driver's own window; only its being busy prevented the close. |
| `custom title` on the tab | Settable without error, did not read back. |
| tty + busy at creation, close by id | Soundest of the six; returned `NOTOURS` at cleanup and was never fully diagnosed. Best hypothesis: the tab is not yet `busy` immediately after `do script`, so the scan matches nothing and falls through to a racy fallback. Poll for busy before capturing, if anyone resumes this. |

Iterating `windows` while other sessions open and close theirs also raises
"Can't get item 32 of every window" — snapshot the ids and address
`window id N` directly, with a `try` per window.

### Two traps that cost more than the bug

- **`before` is an AppleScript reserved word.** Using it as a variable is a
  syntax error reported as *"Expected expression but found `to`"* pointing at
  the assignment. The probe died before opening any window, so a leak test that
  only counted leftover windows saw zero and passed. A green meaning "nothing
  ran" is indistinguishable from one meaning "nothing leaked".
- **bash 3.2 cannot parse a heredoc inside command substitution.** A cleanup
  written that way assigned an empty string every iteration while `bash -n`
  called the script fine. The probe already lives in its own file for exactly
  this reason.

Any future work here must assert the canary **PASSES**, not merely that no
window leaked, and must prove its leftover-count predicate against a known
leftover first. Two separate false greens came from measuring the wrong thing.
