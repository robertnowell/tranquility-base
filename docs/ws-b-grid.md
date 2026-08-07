# WS-B — the grid: one identity, the idle face opened up, ambient collapse

Baseline 1473f39 (the paint-funnel collapse). Everything here is app-layer;
Core untouched. Binding input: docs/ws-b-ruling.md (b875aaf + the 05 Aug
addenda committed mid-pass as 24b0636/992d3f5).

## What changed

**The idle face IS the grid.** `showIdle(note:rows:)` takes row DATA
(`StateLegend.SessionRow`: id, name, topic, lamp) and the `.idle` arm of
`render()` draws one row per session — lamp glyph in its flat state color,
callsign in semibold, topic in chrome — capped at 8, plus a "+ New session"
row (ruled addendum). Row tap = `onPickWaiting` → `announceNext(only:)`,
which reads `latestStop` and therefore works for quiet (heard/skipped) rows
too. The separate `showWaitingList` face, `onOpenWaitingList`, and the
clickable count pill (`stateButton`) are deleted — one face, not two
near-identical lists. The old idle hint text is dead; a one-line hint
survives only in the true empty state.

**Rows show every state derivable today** (ruled: a skipped turn is a row,
not an absence): green `.ready` = the liveness-filtered
`coordinator.waiting()` set; quiet `.running` = any other LIVE session
(from the cached `claude agents --json` probe, joined with its latest stop
for callsign/topic). Dead sessions appear nowhere. `.fault` (amber) exists
in the `StateLegend.Lamp` seam but nothing observable emits it yet —
readiness probing per session is a dispatch-time subprocess, and inventing
a fault state the app cannot see was out of bounds.

**Ambient collapse.** Dismiss → panel hidden; the menu-bar item carries the
waiting count as its title next to the symbol (`StateLegend.menuBarCount`,
quiet/image-only at zero, text fallback when the symbol fails). Left-click
on the status item opens the grid; the menu (permissions, voice, New
session, quit) moved behind right-click, because an assigned menu swallows
the primary click. "Show panel" and `voicedispatch://show` land on the grid
too. The count and the menu-bar title refresh every intake tick and log on
change (`menubar: count=…`), so neither can go stale while the panel is
hidden.

**New session** (ruled addendum, wired here because this pass owns menu +
grid): menu item + grid "+" row → `SessionLauncher.launch()`, trace wired
to `Permissions.log` at init. Post-launch, per the first-run ruling: if no
new session registers in the launched cwd within ~30s, a quiet visual note
("New session is waiting on a prompt in Terminal.") surfaces through the
normal ambient path — the trust prompt is a consent and is never
auto-answered.

## The one-identity rule's touchpoints

`StateLegend.displayName(callsign:fallback:)` is the single resolver.

- Grid rows: `callsign` → live session name → project label.
- Announcement card title + `activeConversation` (which feeds the listening
  pill and later sends): resolved at `onWillSpeak`, and in the depth-1 path.
- `resolveReplyContext` (listening pill, adopt-target): callsign wins; the
  live name ("promotions-49") covers unminted sessions because it is
  checkable against the tab; bare label last.
- "Sending to X": Core's `readyToSend` still carries the project label, so
  the app upgrades it via `store.callsign(for:)` at `showPendingSend` time
  (Core is not this pass's to change).
- Deep-link reply: label resolved the same way.
- The literal "Tranquility Base" now appears ONLY in the true empty state.
  The preparing card, the success receipt, and the transcribing fallback
  lost their app-name mastheads (title hidden when the face carries none —
  `titleLabel.isHidden = face.title.isEmpty` in the render baseline).

## The count unification

`store.pendingCount()` (unfiltered) is no longer read anywhere in the app —
the menu's "N waiting" row is deleted with a comment saying why. Every
surface — menu-bar title, grid green count, panel "N waiting" headline,
`.idle(waiting:)` state — derives from the liveness-filtered
`coordinator.waiting()` set. `tbase status` still prints the raw store
count; that is Core/CLI territory and untouched.

## Intake timer

The change guard moved from `(waiting, unsent)` counts to the row data
itself (`lastShownRows`, `SessionRow: Equatable`): a topic changing or a
newer turn replacing an older one repaints; identical content does not
(verified live: two paints in 25s, then silence). `unsentReplyCount` reads
died with the old signature — the value was already deliberately unshown.

## Selftest / matrix

`--selftest-hud` gained an `idleGrid` state (mixed lamps, worst-case topic,
empty topic) and lost `waitingList`; still 10 states + both legality
checks. Matrix deltas, all intended: the `count` column is gone from every
state (widget deleted — no residue possible, the matrix proves it);
`preparing` and `resultOk` show `title=0` (one-identity); `idle` empty
state shows the Ready pill instead of the count-pill swap. Everything else
is identical to the 1473f39 baseline.

## Judgment calls

- **Truncation ruling vs. the 60-char topic.** The ruling says displayed
  text must never truncate and "binds the grid design too". The brief
  specifies the existing topic derivation (first sentence, else 60 chars of
  the last assistant message), now centralized in `StateLegend.topic`. Read
  as: the topic is a composed short label, not displayed source text; rows
  are single-line with tail-truncation as layout safety. If Robert reads
  the ruling stricter than this, the fix is wrapping rows — flagged, not
  guessed.
- **Menu-bar "amber lamp".** The ruling says "a number, plus an amber lamp
  (or equivalent)". The template-image status item is monochrome by design;
  the count appearing next to the symbol is the "equivalent" for now. A
  colored dot belongs to the MOCR palette item.
- **Grid headline.** "N waiting" appears as the panel title when N > 0 —
  not the dead count-pill (that was chrome pretending to be a button), just
  orientation matching the menu-bar number. Title hidden when nothing is
  green.
- **Quiet rows show the last topic**, not "running": the last thing a
  session said is more useful than a state word the lamp already carries;
  a session with no stored stop shows its live name alone.
- **Row order**: green (newest first, the store's order) then quiet — so
  the 8-row cap can never hide a waiting session behind an idle one.
- **`tbase new` launch left untested here** — the Core session already
  exercised it live (and hit the trust prompt that produced the first-run
  ruling); re-spawning throwaway interactive sessions from this pass would
  have left artifacts.
