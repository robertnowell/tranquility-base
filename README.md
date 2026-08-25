# Tranquility Base

A macOS menu-bar app that turns a fleet of terminal coding agents into a voice
loop. When a Claude Code session finishes a turn it **hails you by name** — a
chime and its own callsign, in its own voice — and then waits. Press ⌃⌥ and it
reports: what concluded, what it proposes next, and the decision it needs, in
about twenty-five words. Answer out loud. Your reply is transcribed, typed into
the originating terminal tab, and **verified against the session transcript** so
you know it landed.

The point is not dictation. It is that you can run ten sessions and supervise
them without reading ten walls of text or hunting for the tab that's blocked on
a permission prompt.

Other Claude Code voice tools speak: some announce that a turn ended, a few
generate real spoken summaries. What none of them do is impose a **protocol** —
hail and standby, callsign-first attribution, a proposal that ends on a
one-word decision, and a pull ladder for the detail you didn't get. That
protocol is the product, and it is borrowed, deliberately, from the room that
solved this problem in 1969.

## The loop

```
turn ends ─▶ chime + "promotions copy"          the hail: name only, then standby
                     │                          (never interrupts anything)
        ⌃⌥ ─▶ "…finished the poller. Propose adding the Shopify filter. Go?"
                     │                          12-word recap + <15-word proposal
        ⌃⌃ ─▶ FINDINGS ▸ SOLUTION ▸ WHY ▸ MESSAGE     the ladder, ~40 words a rung
                     │                          zero extra model calls
   hold ⌥, speak ─▶ 4s undo window ─▶ typed into the tab ─▶ read back to confirm
```

Silence means nominal. Nothing speaks unless a session is waiting on you.

## Gestures

| Input | Action |
|---|---|
| **⌃⌥** tap | Hear the newest waiting session (press again to skip on) |
| **⌃⌃** tap | Walk the ladder on what you just heard — findings, solution, why, then the original message |
| **⌥** hold | Push-to-talk reply — release to send |
| **⌥⌥** double-tap | Lock hands-free listening; single ⌥ tap sends |
| **⇧** tap | Pause / resume playback |
| **⌃⇧** tap | Dismiss (a chord, not Escape — Escape would interrupt the Claude session in your terminal) |

Bare modifiers are deliberate: the event tap is listen-only, so every gesture
types nothing anywhere. Any other key or click during a gesture cancels it.

With **nothing waiting**, the same gestures become dictation: the transcript
types at your cursor (with Accessibility granted) or lands on the clipboard.

## Identity — the part that makes N sessions tractable

- **Callsigns.** Every session is minted a deterministic two-word spoken name
  ("promotions copy") at its first summary, frozen for life, and kept at
  Levenshtein distance ≥2 from its neighbours so no two sound alike at speech
  speed. It is prepended mechanically, not by the model: attribution is the one
  thing a prompt instruction may not be trusted with.
- **Voices.** Each session draws a durable voice from a cast of fourteen. The ear
  knows *which* session before the name registers.
- **The grid.** At rest the app is a menu-bar annunciator with a waiting count.
  Click it and you get one row per live session: a lamp, the terminal tab's own
  title, and the callsign. Green means it wants you.

## Install

Requires macOS 14+, Xcode command-line tools, and the `claude` CLI.

```sh
git clone https://github.com/robertnowell/tranquility-base.git && cd tranquility-base
./scripts/bundle.sh                  # build + sign the .app
open ".build/debug/Tranquility Base.app"
swift run tbase install-hooks        # wires the Claude Code hooks (backup kept)
```

Restart your Claude Code sessions (or open `/hooks` once) so they load the
hooks. `tbase new [dir]` starts a fresh session in its own Terminal window.

### Permissions

First run opens a checklist; each row's **Grant** button either prompts or
deep-links to the exact Settings pane. All granting is observable — the dots go
green live.

- **Microphone** — record your reply
- **Input Monitoring** — see the modifier gestures from any app
- **Automation (Terminal)** — type replies into the right tab
- **Accessibility** *(optional)* — dictation types at your cursor; without it,
  clipboard

Note for tinkerers: under the hardened runtime, a missing entitlement produces
a *silent* denial — no prompt, no Privacy-pane listing. `bundle.sh` handles the
entitlements; if permissions behave strangely after rebuilds, create a free
Apple Development certificate in Xcode so the signing identity is stable.

### API keys

Stored in the login Keychain — `tbase set-key <name>` prompts without echoing,
and nothing is read from the environment (a stale `ANTHROPIC_API_KEY` in a shell
profile silently 401s every call and reads like an outage, so the fallback is
deliberately absent).

Anthropic powers the summaries (Haiku, ~$0.001 each); ElevenLabs the voice
(falls back to the system voice with an on-screen reason); AssemblyAI the live
streaming transcript, with Whisper as the durable one and Apple's on-device
engine as the floor. The app runs degraded without any of them, but the
summaries are the point.

## Design notes, briefly

- **The event log is the only system of record.** Events are append-only;
  "waiting" is a query (latest event per session is a Stop you haven't heard or
  dismissed). Read/dismissed are per-session watermarks, so a new turn revives a
  dismissed session by construction. `docs/design/state-architecture.html` has the full
  rationale.
- **Never speak an inferred fact.** Summaries are grounded in the session's own
  final message. A pull request is mentioned only if the session mentioned it —
  looking one up from the branch once announced a months-old merge as news,
  which is true, irrelevant, and indistinguishable from a hallucination.
- **Numbers are grounded mechanically.** Any digit not present in the source
  triggers one corrective retry, then the clause is scrubbed rather than spoken.
  A confident wrong number is the fastest way to lose the channel.
- **Guarantees live in types, not prompts.** Text-to-speech accepts only
  sanitizer output, so no future code path can hand raw model output to the
  voice. A prompt instruction erodes; a type doesn't.
- **Refuse over guess**: unverifiable sessions are never typed into; sub-second
  or silent recordings are never transcribed (Whisper hallucinates newscasts
  over silence); ambiguous deliveries are never auto-retried.
- **Everything is observable**: state transitions, routing decisions, and full
  model call I/O are logged (`tbase calls`, `tbase status`, `tbase dogfood`,
  `app.log`). `tools/replay/` runs candidate prompts against a corpus of real
  sessions and diffs the results, so prompt changes are measured, not felt.

## Caveats (alpha)

- **Terminal.app only** for reply routing; other terminals get announcements.
- `model-calls.jsonl` retains full model inputs/outputs (your session content)
  for debugging, unbounded — delete or truncate freely.
- `app.log` is also unbounded and grows fast; it records **what you dictated**
  whenever the on-device Apple engine runs (the last-resort fallback): one line
  per recognised utterance, text included. Same 0700 boundary as the recordings;
  it's the file you'd attach to an issue, so know what's in it.
- Long-running headless `claude -p` jobs can be announced while still executing.
- On-disk state still lives in `~/Library/Application Support/VoiceDispatch/`
  and credentials under the Keychain service `voice-dispatch` — both predate the
  rename and move only behind a migration, not as a side effect of it.

## License

MIT. Portions adapted from [Clicky](https://github.com/farzaa/clicky) (MIT,
© 2026 Farza) — see `NOTICE`.
