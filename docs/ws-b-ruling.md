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

Tranquility Base must also START sessions, not only answer them: "sometimes I
want to be reactive, but sometimes I want to kick off an investigation."

- v1 is choiceless: always `claude --dangerously-skip-permissions`, always
  the home directory. Directory/agent pickers come later, or never.
- Core half is DONE: `SessionLauncher.launch(directory:command:)` — same
  AppleScript transport, same Automation grant. `tbase new [dir]` exercises it.
- **Wiring ask for the grid session** (you own the menu + grid right now):
  one menu item — title "New session", target-less closure onto
  `SessionLauncher.launch()` with `SessionLauncher.trace = Permissions.log`
  wired at app init — and, when the grid lands, a "+" row at the bottom of
  the grid doing the same. No gesture binding: ⌥ variants are spoken-reply
  space, and a mis-hold that spawns terminals is worse than a click.
- **First-run trust prompt — OVERRULED 05 Aug, same day:** Robert: "I
  authorize you to click through and start this. I told you to start the
  session. Start the session." The launcher now answers the trust prompt
  itself — scoped to ONLY the tab it just created (by tty), ONLY the known
  prompt text, ONLY within 30s of a user-commanded launch, via the same
  bare-Return the dispatcher uses. The dispatcher's never-type-into-
  unregistered-sessions rule is untouched everywhere else. Consent lives at
  the button press, not at Anthropic's re-ask.
- **⌃⌃ must speak in the session's voice** (observed 05 Aug: depth-1 fell back
  to the narrator). Core accessor exists: `coordinator.voiceId(for:)`. The
  one-line wiring, for whoever holds main.swift when this lands — in the
  `.controlDoubleTapped` handler's speak call:
  `speech.speak(line, voice: coordinator.voiceId(for: announcement.event.sessionId), onWord: …)`.
- **Roster becomes hand-picked:** Robert is auditioning the catalog
  (vd-voice-roster-page) and will supply ten voice ids. They replace the
  first-ten-by-id placeholder in exactly one place: `Coordinator.voiceId(for:)`.
  Existing assignments are durable and unaffected by the roster change.
- **Hail voice — RULED 05 Aug: the session's voice, "for sure."** The hail is
  the session bidding for attention; hearing WHO before the name is the whole
  point of durable voices. Wire the hail's speak through
  `coordinator.voiceId(for:)` exactly like the announcement.
- **Lists sort newest-first by default** (grid rows, waiting list): recency is
  the resting order; anything else is an explicit view.
- Voice-assignment hygiene: two placeholder-era assignments (Kyle South Park
  on the intranet session — explicitly disapproved — and Cassidy) predated the
  hand-picked cast and were purged 05 Aug; those sessions redraw from the
  approved fourteen at next announce. Durability binds cast assignments;
  pre-cast leftovers were data, not contract.
