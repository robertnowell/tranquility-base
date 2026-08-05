# WS-B interaction model — ruled by Robert, 05 Aug

The grid's resting shape, quoted near-verbatim:

- **Invisible by default.** No floating panel at rest.
- **The menu bar is the annunciator at rest**: a number, plus an amber lamp
  (or equivalent) when sessions are waiting. Quiet when nothing is.
- **Click the menu-bar item → the grid appears** — one row per session,
  callsign + lamp, row-tap invites that session. Dismiss → back to the number.

Implications folded in from the same conversation:

- The grid shows sessions in *every* state, not only waiting — a turn skipped
  by ⌃⌥-next is a visible row, not an absence. This is the recovery surface
  for the skip-spam incident (two fresh arrivals dismissed by two presses,
  11s apart, then invisible; log 2026-08-05T21:58Z).
- One callsign per session on every surface, panel and grid and voice; the
  app's own name appears only in the true empty state.
- Readback/cards must NEVER truncate displayed text (Robert: "the
  transcription review truncates the fucking text — don't do that").
  Layout logs prove the current panel wraps fully (textFits=true); the
  truncation he saw was transcription-layer — see
  finding-stream-truncation.md — but the rule binds the grid design too.

## Finding for the live-ear session: stream truncation

Utterance FB47179C (22:19Z): transcriptText stored at 246 chars, ending
mid-thought, for a spoken message whose typed continuation ran ~3x longer.
Two prior utterances in the same hour were the user testing streaming
("I'm not seeing assembly AI streaming surfaced", 68E4B204 dispatch_failed).
Hypothesis: `StreamedUtterance.finish()` returned a non-nil PARTIAL result
(stream closed early / final-turn packet missed) and the partial stood in as
the durable transcript — which contradicts the stated design ("the stream
can only ever ADD speed; the durable buffer and file-based recovery are
untouched"). Suggested rule: a stream result is accepted only when the
stream saw end-of-audio cleanly; otherwise fall back to the file transcript
unconditionally. A cheap tripwire: log both lengths and flag when the
stream's text is >20% shorter than Whisper's.

## New-session affordance — ruled 05 Aug (addendum)

Voice dispatch must also START sessions, not only answer them: "sometimes I
want to be reactive, but sometimes I want to kick off an investigation."

- v1 is choiceless: always `claude --dangerously-skip-permissions`, always
  the home directory. Directory/agent pickers come later, or never.
- Core half is DONE: `SessionLauncher.launch(directory:command:)` — same
  AppleScript transport, same Automation grant. `vdctl new [dir]` exercises it.
- **Wiring ask for the grid session** (you own the menu + grid right now):
  one menu item — title "New session", target-less closure onto
  `SessionLauncher.launch()` with `SessionLauncher.trace = Permissions.log`
  wired at app init — and, when the grid lands, a "+" row at the bottom of
  the grid doing the same. No gesture binding: ⌥ variants are spoken-reply
  space, and a mis-hold that spawns terminals is worse than a click.
- **First-run reality (observed 05 Aug):** a fresh directory (and sometimes a
  fresh window) hits Claude's own trust prompt — "Do you trust this
  directory?" — which `--dangerously-skip-permissions` does NOT suppress
  (that flag governs tool permissions, not folder trust). NEVER auto-answer
  it: it is a security consent, and dispatch's own rule (no typing into
  unregistered sessions) exists for exactly this. Instead: after launch,
  poll `claude agents --json` for a session in the launched cwd; if none
  registers within ~30s, show a quiet visual note — "new session is waiting
  on a prompt in Terminal" — so a walked-away launch is never a silently
  stillborn investigation. Launch already fronts the window, which covers
  the at-screen case.
