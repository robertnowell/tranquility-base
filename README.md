# voice-dispatch

A local macOS loop for terminal coding agents. When a Claude Code session finishes a
turn, it speaks a short summary at a moment that doesn't interrupt, listens for a
dictated reply, routes that reply back into the originating terminal tab, and
verifies it landed.

Nothing leaves the machine except the summarization and transcription calls you
configure. There is no server, no telemetry, and no account.

## Why

Session managers like Vibe Kanban and Kanban Code have to *own* session creation, so
they can never adopt a session you started in an ordinary terminal tab. And of the
several existing Claude Code voice-notification projects, none generates a summary —
they announce that an event occurred, never what the agent concluded.

## Status

Under construction. Working today:

- **Capture** — a hook writes every turn-end to an append-only spool; the app drains
  it into SQLite (WAL). The hook never blocks and always exits 0, so it cannot affect
  a live turn.
- **Dispatch** — resolve `sessionId → pid → tty → Terminal.app tab`, inject the text,
  submit with a *separate* Return, then verify by reading the text back out of the
  session transcript. Fails closed and never guesses.

Not yet built: summarization, speech, recording, transcription, the overlay.

## Design notes worth knowing

**Dispatch is two AppleEvents, not one.** `do script "text"` delivers text but does
not submit it for anything longer than a short line — it accumulates silently in the
input box while the session still reports `idle`. The submit must be its own event.

**Presence in `claude agents --json` is the readiness gate.** A session blocked on a
dialog is alive as a process but absent from that API. Injecting into it would
*answer the dialog*, so absence means "never inject."

**An ambiguous dispatch is never retried.** If keystrokes were sent but the read-back
didn't confirm, we cannot know whether they landed, and a duplicate injection into a
live session is worse than a dropped one. It is surfaced for a human instead.

**Audio is written to disk before the first network call**, and the retention sweep is
structurally incapable of deleting audio for a row that still needs it.

**Raw mode matters.** Canonical-mode tty input is capped at `MAX_CANON` (1024 bytes on
macOS) and silently truncates beyond it. Claude Code's TUI runs raw, so long replies
are fine — but any future transport aimed at a plain shell inherits that cap.

## Usage

```bash
swift build

.build/debug/vdctl status            # queue overview
.build/debug/vdctl drain             # move spooled hook events into the queue
.build/debug/vdctl events            # what's waiting
.build/debug/vdctl targets           # live sessions, with tty and enrolment
.build/debug/vdctl hook-config       # snippet to install the hook

scripts/test-dispatch.sh             # dispatch integration tests, no Claude needed
swift test                           # unit tests
```

### Safety rail

Dispatch refuses to inject into any session not explicitly enrolled:

```bash
.build/debug/vdctl enroll <sessionId>
.build/debug/vdctl enroll --cwd ~/Projects/scratch
```

So a bug in the loop cannot type into something that matters — the worst case is that
nothing happens.

## Credits

Two MIT-licensed projects were read closely while designing this: **Clicky**
(farzaa/clicky) for the macOS shell — the non-activating overlay, the listen-only
`CGEvent` tap, and the permission flows — and **OpenWhispr** for the durability model,
audio on disk keyed to a row with a status, retried from disk rather than from memory.

## License

MIT
