# Managed live transcription — v1 addendum (2026-09-22)

Additive, like `VOICE.md` and `SPEECH.md`. The live transcript is a metered
session on the same personal account and the same grant.

## The audio never comes here

AssemblyAI issues short-lived streaming tokens, so this service sells a
metered **session** and mints a **token per socket**; the Mac opens
`wss://streaming.assemblyai.com/v3/ws` itself and speaks to the vendor
directly. There is deliberately no relay: a relay would put every microphone
through one service, add a hop to a latency budget measured in tens of
milliseconds, and make this the place recordings pile up. It also answers
CL-11's R5 (resource bounds) by construction — there is nothing here to
bound.

## Authority

The same device-bound bearer, presented as `Authorization: DPoP` with a proof
per request. Devices with a key receive `transcription:session` at mint. The
vendor key never leaves this service.

## Routes

Under `/v1/accounts/{accountId}/transcription/sessions/{sessionId}`, the
session id a UUID the client mints. Scope `transcription:session`.

| Method | Path | Result |
|---|---|---|
| PUT | `…/{sessionId}` | Start. Reserves block 1 and returns the session with `wsUrl`, `token` and `expiresInSeconds` for the first socket. Idempotent for the same device. |
| POST | `…/{sessionId}/token` | Another socket for a session already paid for: `{ wsUrl, token, expiresInSeconds }`. **Free** — the minutes are already reserved. |
| POST | `…/{sessionId}/renew` | The next 30-minute block. |
| POST | `…/{sessionId}/end` | Settles every open block by measured seconds. |
| GET | `…/{sessionId}` | The session; never a token. |

The session shape is `VOICE.md`'s, with `"kind": "transcription"`.

## Metering, and what bounds it

Identical to hands-free: 30-minute blocks, each its own operation and
reservation, sequential windows so no minute is counted twice or missed,
settled by seconds the Gateway measures with its own clock. A session with no
open block left is ended.

Two bounds exist because the vendor is spoken to directly:

- **A token never outlives what is reserved.** `max_session_duration_seconds`
  is the remainder of the open block, so a socket cannot run past the minutes
  that were paid for, whatever the client does.
- **240 tokens per block.** One stream per utterance is a few dozen sockets
  in half an hour; past this the answer is `429 too_many_sockets`, so one
  reserved block cannot run an unbounded number of parallel streams on our
  vendor account. Renewing buys the next allowance with the next block.

A token is issued only to the device that started the session.

## Price

`transcriptionMinuteMicros`, versioned with the pricebook and locked at each
block's admission. The placeholder is 12,000 micros a minute (1.2¢), against
a vendor cost near 0.7¢: a $10 grant is about thirteen hours of listening.

## What this does not yet answer

CL-11's R1 (finality), R2 (durable recording plus completed recovery), R3
(added-failure estimate), R4 (latency distributions) and R6 (attribution)
remain the app's to demonstrate, because the stream is the app's. What this
settles is that the money and the credentials are the Gateway's, and that
neither the audio nor the vendor key passes through anything of ours.
