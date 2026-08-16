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
