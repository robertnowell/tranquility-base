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

## 20. Is the spoken callsign still earning its place? — OPEN, needs a ruling

Raised 18 Aug alongside #19: "there's a deeper question of whether the spoken
call sign is even useful anymore — we already have the voice and the name of the
Claude Code session."

The callsign has been losing surfaces for two weeks. It left the grid's right
column on 12 Aug (an id answers "which tab is this" and a name does not) and the
hub page on 16 Aug ("a SPOKEN name… on a page it read as a third identity
competing with the two real ones"). The spoken HAIL died on 10 Aug. What is
left is one job: the mechanical prefix `withCallsign` prepends to every
announcement, and the Lexicon seed that lets the recogniser hear the name.

Against keeping it: three identities for one session (title, id, callsign) and
the panel already shows two of them.

For keeping it: the announcement is the one channel with no panel in it, and
`session_voice` assigns round-robin from a 14-voice roster — a voice identifies
a session only while fewer than fourteen have spoken.

The middle option, and the one worth measuring first: keep the prefix, drop the
topic word, and speak the DIRECTORY word alone. It is a name the user chose, so
it is speakable by construction and cannot be mis-minted; voice keeps saying
which session and the prefix says which project; and the whole minting apparatus
— candidates, collisions, Levenshtein, the freeze, both migrations — goes away.
Its cost is that two sessions in one directory sound alike, which the corpus
says is the common case (23 of 127 rows begin "promotions").

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
