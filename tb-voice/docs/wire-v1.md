# Wire v1: the manager's hands on the Mac

Approved 22 Sep 2026 (hf-3). The hosted manager runs in a container that has
none of the Mac's files: not `tbase`, not the agents' transcripts, not the hub.
Everything it knows about the fleet it must ask the Mac for. Before v1 it sent
`request:run` with any `tbase` argv; the app ran it with no deadline, inside the
socket's receive loop, and a send that landed could read as failed and be
retried. v1 replaces that with named tools.

## Rules

- The Mac says what it offers (`hello`). The bot calls only those, by name,
  never an argv.
- Every call has a deadline, enforced on the Mac (the subprocess is killed) and
  on the bot (it gives up 500 ms later and sends `cancel`).
- Reads run at most 4 at once; effectful calls run one at a time.
- An effectful call carries `idem`. The Mac records it **before** the work, so a
  repeat returns the recorded outcome or `in_progress`, and never runs twice.
  A timed-out effect stays recorded: it may have happened, so it is never
  retried by its key.
- A result over its cap is cut from the end the tool does not keep and marked
  `truncated: true`. No frame exceeds 64 KB, so audio never queues behind one.
- Calls are answered off the transport's receive loop.
- `request:run` stays until no bot path and no shipped app needs it. A bot that
  gets no `hello` within 1.5 s of the session start keeps using it.

## Frames (JSON text, discriminator `wire`)

| `wire` | direction | shape |
|---|---|---|
| `hello` | Mac → bot | `{protocol: 1, app_version, tools: [{name, version}]}` |
| `call` | bot → Mac | `{id, tool, args, deadline_ms, idem?}` |
| `result` | Mac → bot | `{id, ok, data, truncated?, repeat?}` or `{id, ok: false, error: {code, message, retryable}}` |
| `cancel` | bot → Mac | `{id}` |
| `event` | Mac → bot | `{kind, ...}`, reserved for chords (hf-16) and tray changes (hf-12) |

On WebRTC, every frame the Mac sends also carries `"type": "tb"`: the bot's
data channel reads `type` on each message and drops any without it. That is
carriage, not protocol; nothing reads it (`ManagerDataChannel.stamped`). A
hello sent without it on 24 Sep never arrived, and the bot stayed on
`request:run` for the whole session.

Error codes: `unknown_tool`, `bad_args`, `not_found`, `refused`, `timeout`,
`cancelled`, `in_progress`, `too_large`, `internal`.

## Tools in this release

| tool | args | returns | deadline | cap |
|---|---|---|---|---|
| `agents` | | `tbase targets --json` | 3 s | 16 KB |
| `waiting` | | `tbase status --json` | 3 s | 16 KB |
| `brief` | `agent` | `tbase brief <agent> --json` | 3 s | 8 KB |
| `transcript` | `agent`, `chars` (≤ 30 000, default 7 000) | `{turns: [{who, text}], total_turns}`, newest last | 5 s | 32 KB |

| `send` | `agent`, `text`; `idem` required | `{outcome}`: `typed`, `queued`, `not_dispatched` or `ambiguous` | 20 s | 1 KB |

`send` is the panel's own Send (`AppDelegate.sendTyped`, hf-12): the words go
in verbatim, and everything the developer has staged, for whichever agent,
rides with them. `ambiguous` (and a `timeout`) means it may have landed: the
bot says so and never retries. Quiet sends (notes, seeding) and `start_agent`,
`enroll` and `open` stay on `request:run`, as does every send to an app that
does not offer `send`.

## Where it lives

- Mac: `TranquilityCore/ManagerToolHost.swift` (the rules above),
  `ManagerTools.swift` (the tools, `ManagerCommand`, `TranscriptTail`); the
  WebSocket (`ManagerSocket`) and WebRTC (`ManagerPeer`) transports both send
  `hello` and hand `wire` frames to one host.
- Bot: `wire.call()` and `take_reply` in `wire.py`; `tools._run` routes the
  three reads through v1 when offered; `Brain.tail` reads the transcript.
- Proof: `ManagerToolHostTests` (15), `drills/isolation_drill.py` (wire
  checks), `drills/wire_v1_drill.py` (end to end, with and without hello).
