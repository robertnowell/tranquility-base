# Voice Dispatch

A macOS menu-bar app that closes the loop on terminal coding agents: when a
Claude Code session finishes a turn, Voice Dispatch **speaks a short, actionable
summary** — what happened, what's proposed, what decision it needs — and lets you
**reply by voice**. Your words are transcribed and typed into the originating
terminal tab, then verified against the session transcript so you know they
landed.

Across the existing Claude Code voice-notification tools, none generate a
summary — they announce *that* something happened, never *what the agent
concluded*. That summary, plus the verified voice reply, is the whole product.

## The loop

```
Claude Code hook ─▶ append-only event log ─▶ waiting = a query
                                                  │
        ⌃⌥ tap ─▶ Haiku summary ─▶ ElevenLabs voice ─▶ hold ⌥, speak
                                                  │
   your terminal tab ◀─ typed + submitted ◀─ 4s undo window ◀─ transcript
                └─ read back from the session transcript to confirm delivery
```

## Gestures

| Input | Action |
|---|---|
| **⌃⌥** tap | Hear the newest waiting session (press again to skip on) |
| | *(background agents are announced but never offer a reply — see Caveats)* |
| **⌥** hold | Push-to-talk reply — release to send |
| **⌥⌥** double-tap | Lock hands-free listening; single ⌥ tap sends |
| **⇧** tap | Pause / resume playback |
| **⌃⇧** tap | Dismiss (a chord, not Escape — Escape would interrupt the Claude session in your terminal) |

Bare modifiers are deliberate: the event tap is listen-only, so every gesture
types nothing anywhere. Any other key or click during a gesture cancels it.

With **nothing waiting**, the same gestures become dictation: the transcript
types at your cursor (with Accessibility granted) or lands on the clipboard.

HTML pages can carry live buttons via deep links — see
`docs/trigger-test.html`:
`voicedispatch://hear?session=ID`, `voicedispatch://reply?session=ID`,
`voicedispatch://show`.

## Install

Requires macOS 14+, Xcode command-line tools, and the `claude` CLI.

```sh
git clone <this repo> && cd voice-dispatch
./scripts/bundle.sh                  # build + sign the .app
open ".build/debug/Voice Dispatch.app"
swift run vdctl install-hooks        # wires the Claude Code hooks (backup kept)
```

Restart your Claude Code sessions (or open `/hooks` once) so they load the
hooks.

### Permissions

First run opens a checklist; each row's **Grant** button either prompts or
deep-links to the exact Settings pane. All granting is observable — the dots go
green live.

- **Microphone** — record your reply
- **Accessibility** — see the modifier gestures from any app, and type dictation
  at your cursor
- **Automation (Terminal)** — type replies into the right tab
- **Input Monitoring** *(alternative)* — also authorises the gestures; you need
  **either** this or Accessibility, not both

Grant **Accessibility**, not Input Monitoring. A listen-only `CGEvent` tap accepts
either, but on a normal Mac nothing requests Input Monitoring — that pane sits
empty while every comparable tool appears under Accessibility — and only
Accessibility additionally gives you dictation-at-cursor. Relaunch once after
granting it: `AXIsProcessTrusted()` is evaluated when the process starts, so a
running instance cannot see a grant you just made.

### Why the signing identity matters

`bundle.sh` creates a stable local code-signing certificate on first run
(`scripts/make-signing-identity.sh`, idempotent, no Xcode, no system trust
changes). This is not cosmetic. An **ad-hoc** signature has no certificate, so the
designated requirement macOS derives is `cdhash H"…"` — the hash of that exact
binary. TCC stores your grants against that requirement, so **every rebuild
becomes an app macOS has never seen and every permission silently reverts.**

The symptom is close to undiagnosable: the Privacy pane keeps listing the app with
its switch ON, while the API that gates the feature returns false. The pane is
describing a stored row; the API is describing *this* binary. Toggling the switch
does not help, and neither does removing the row — the grant is keyed to a code
identity that no longer exists.

If you ever see "granted but not working", the signing identity changed. Fix:

```sh
./scripts/reset-permissions.sh    # clear grants bound to the dead identity
open ".build/debug/Voice Dispatch.app"    # then Grant again
```

Also note: under the hardened runtime a missing *entitlement* produces a silent
denial — no prompt, no Privacy-pane listing. `bundle.sh` handles those.

### API keys

Create `~/Library/Application Support/VoiceDispatch/secrets.json` (mode 0600):

```json
{
  "anthropic-api-key": "sk-ant-…",
  "elevenlabs-api-key": "…",
  "openai-api-key": "sk-…"
}
```

Anthropic powers the summaries (Haiku, ~$0.001 each); ElevenLabs the voice
(falls back to the system voice with an on-screen reason); OpenAI the
transcription. The app works degraded without any of them, but the summaries
are the point.

## Design notes, briefly

- **The event log is the only system of record.** Events are append-only;
  "waiting" is a query (latest event per session is a Stop you haven't heard or
  dismissed). Read/dismissed are per-session watermarks, so a new turn revives a
  dismissed session by construction. `docs/state-architecture.html` has the full
  research-backed rationale.
- **Never speak an inferred fact.** Summaries are grounded in the session's own
  final message; a PR is mentioned only if the session mentioned it.
- **A reply is addressed when the mic opens**, displayed while you speak, and
  consumed at send — never re-derived later.
- **Refuse over guess**: unverifiable sessions are never typed into; sub-second
  or silent recordings are never transcribed (Whisper hallucinates over
  silence); ambiguous deliveries are never auto-retried.
- **Everything is observable**: state transitions, routing decisions, and full
  model call I/O are logged (`vdctl calls`, `vdctl status`, `vdctl cursors`,
  `app.log`).

## Caveats (alpha)

- **Terminal.app only** for reply routing; other terminals get announcements.
  Fullscreen rendering (`/tui fullscreen`) is fine — it changes how the CLI draws
  inside the tab, and the session keeps its controlling tty.
- **Background agents cannot be replied to.** A session with `kind: "background"`
  is hosted by `claude --bg-pty-host`, which owns the pty master, so the session has
  no controlling terminal and no Terminal tab — there is nothing to type into, and
  no supported IPC to reach it. Those announcements omit the Reply button and put
  your words on the clipboard instead of losing them.
- `model-calls.jsonl` retains full model inputs/outputs (your session content)
  for debugging, unbounded — delete or truncate freely.
- `app.log` records **what you dictated**, one line per recognised utterance with
  its time span. This is deliberate: a transcript that is quietly a fraction of
  what you said is indistinguishable from one that is merely wrong unless you can
  see which utterances arrived and what each said — the bug where only the last
  utterance of a paused recording survived was invisible without it. Everything
  here is already 0600 in a 0700 directory alongside the recordings themselves, so
  the one thing to remember is that `app.log` is the file you would attach to an
  issue. Skim it before you paste it.
- Long-running headless `claude -p` jobs can be announced while still executing.

## License

MIT. Portions adapted from [Clicky](https://github.com/farzaa/clicky) (MIT,
© 2026 Farza) — see `NOTICE`.
