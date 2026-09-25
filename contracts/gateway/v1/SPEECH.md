# Premium voice on the Gateway — v1 addendum (2026-09-22)

Additive to the frozen v1 contract, like `VOICE.md`. A spoken clip is one
more paid operation on the same personal account, from the same grant, at a
price per character that is a server-owned pricebook constant.

Why it exists: the system voice is a degraded state, not a default (ruled 13
September). Until now the premium voice needed an ElevenLabs account of the
person's own, so a person who signed in and had credit still could not hear
their agents in a real voice.

## Authority

The same bearer, bound to the device, presented as `Authorization: DPoP`
with a proof per request. Devices with a key receive `speech:create` at mint.
The app never sees a vendor key.

## Route

`PUT /v1/accounts/{accountId}/speech/{clipId}` — `clipId` a UUID the client
mints. Scope `speech:create`. `Content-Type: application/json`.

```json
{ "version": "1", "text": "the line to speak", "voice": "optional voice id" }
```

`text` is required, non-blank, and at most **2,000 characters**; `voice` is
at most 64 characters and defaults to the deployment's voice.

Answers with the operation and, when it was bought on this call, the clip:

```json
{ "version": "1", "kind": "speech", "accountId": "…", "operationId": "…",
  "state": "succeeded", "characters": 47,
  "receipt": { "chargedMicros": "1410", "pricebookVersion": "…", … },
  "clip": { "audioBase64": "…", "characterStartTimes": [0, 0.1, …], "characters": 47 } }
```

`audioBase64` is MP3. `characterStartTimes` is the vendor's per-character
alignment when it sends one, which is what lets the app follow along.

**Idempotent on `clipId`.** The same id with the same text returns the
receipt **without `clip`**: the audio is not stored by the Gateway, and the
app kept it the first time. The same id with different text is `409
idempotency_conflict`.

## Metering

Reserved at admission for `characters × speechCharMicros`, settled for
exactly the characters the vendor was sent. A definitive refusal (400, 401,
403, 404, 422 — an invalid key, an exhausted quota, a voice this account
cannot use) releases the whole reservation and owes nothing: those are the
operator's problems, not the customer's. A timeout or a 5xx is uncertain: the
hold stays and the operation goes `reconciling`, because the vendor may have
charged us. A held operation is never spoken again on its own.

Errors: `402 insufficient_credit` before the vendor is ever called; `503
service_unavailable` when this deployment offers no voice; `400
invalid_request` for a bad body, checked before any money moves.

## Price

`speechCharMicros` is versioned with the pricebook and locked at admission.
The placeholder at launch is 30 micros a character — about 1.4¢ for a
spoken summary of 450 characters, roughly a tenth of a cent a word.
