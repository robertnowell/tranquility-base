# Saved-file recovery on the Gateway — v1 addendum (2026-09-23)

Additive to the frozen v1 contract, like `VOICE.md`, `SPEECH.md` and
`TRANSCRIPTION.md`. Recovering a saved recording is one more paid operation
on the same personal account, from the same grant, at a price per audio
minute that is a server-owned pricebook constant.

Why it exists: it is the last thing a signed-in person still needed a key of
their own for. Recovery fires about five times a day — 4–6% of all
transcriptions, measured over 62 real recoveries between 7 and 22 September —
and while it runs off the critical path, it is what saved a lost 27-minute
dictation on 12 August. That is the moment the promise is worth most.

## Shape: an operation, polled by the caller

A recovery is an **operation**, not a session: one file, one definite end,
charged by the minutes the vendor measures. It reuses the v1 operation state
machine unchanged — `running`, `reconciling`, `succeeded`, `failed` — with one
reserve and one settle, the frozen pricebook version, and a receipt.

**The caller does the waiting.** The Gateway has a sixty-second request
timeout and does no work outside a request, which is what lets a shutdown
simply let in-flight work finish and leave the rest to the ledger. So `PUT`
hands the audio to the vendor and answers at once, and each `GET` asks the
vendor exactly once, inside that request. A recording that takes four minutes
costs four cheap requests, not one held connection and not a background task.

## Authority

The same bearer, bound to the device, presented as `Authorization: DPoP`
with a proof per request. Devices with a key receive `recovery:create` at
mint. The app never sees a vendor key.

## Routes

`PUT /v1/accounts/{accountId}/recoveries/{operationId}` — scope
`recovery:create`. The body is **the audio itself**, not JSON. At most
**25 MB**, which is about seventy minutes at the bitrate the app encodes at;
larger is `413 payload_too_large`.

    tb-audio-seconds: 180

Required, 1 to 4,200. It is what gets **reserved** — a ceiling the caller
states, not a price. The **settle** uses the vendor's own measurement of the
audio, so a caller that overstates the length simply holds more than it
spends. The ledger refuses to settle more than was reserved, so a caller that
understates one is never billed past the number it was shown.

Answers `202` while the work is in flight:

```json
{ "version": "1", "kind": "recovery", "accountId": "…", "operationId": "…",
  "state": "running" }
```

`GET /v1/accounts/{accountId}/recoveries/{operationId}` — one vendor poll,
inside this request. `202` while running; `200` when it is settled:

```json
{ "version": "1", "kind": "recovery", "accountId": "…", "operationId": "…",
  "state": "succeeded", "text": "…", "seconds": "120",
  "receipt": { "chargedMicros": "7000", "pricebookVersion": "…", … } }
```

## Idempotency

`operationId` is the caller's, and the audio's SHA-256 is stored with the
operation. The same recording sent again under the same id joins the existing
operation and reserves nothing further; **different** audio under that id is
`409 idempotency_conflict`. A Mac that restarts mid-recovery re-sends and
gets its own operation back rather than paying twice.

## What is not charged

- **Silence**, which the vendor reports as a language-detection error on a
  file with no spoken audio (measured 09 September).
- **Audio under the vendor's 160 ms floor**, reported as
  `"Audio duration is too short."` (measured 23 September).
- **A refused upload** — an authentication or 4xx answer.

All three release the whole reservation and settle a receipt of `0`. There is
nothing to sell somebody for a recording with nothing in it.

An **uncertain** upload — a timeout, a dropped connection — leaves the
operation `reconciling` with its reservation held, and is never resubmitted
automatically: the vendor may already have the file, and a second upload
against one reservation is a second charge waiting to happen.
