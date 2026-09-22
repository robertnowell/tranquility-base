# Hands-free on the Gateway — v1 addendum (2026-09-21)

Additive to the frozen v1 contract. Nothing in `summary.schema.json`, the
identity algorithm or the summary routes changes. A hosted voice session is
one more paid operation on the same personal account, from the same grant,
at a price that is a server-owned pricebook constant beside the summary's.

## Authority

The same bearer as every route: minted by the hub, bound to this Mac's key,
presented as `Authorization: DPoP` with a proof per request. Devices with a
key receive the scope `voice:session` at mint. The bot receives none of it:
it gets audio and a session id over its socket and speaks to providers with
the operator's keys from the host's secret set. Workers never hold a
human/device bearer.

## Metering

A session is metered in **blocks of 1,800 seconds**. Each block is its own
operation with its own reservation of `1800 / 60 × voiceMinuteMicros`. The
ledger allows one reservation per operation; a renewal therefore never
extends a block, it opens the next one.

Blocks are **sequential windows**: block n+1's window begins where block n's
ends, whenever the renewal arrived. A minute is never counted twice, and a
minute with no block open is never counted at all.

Settlement is by seconds **measured by the Gateway's own clock**:

- `end`: every open block settles for the seconds of its window used at that
  moment; charge = `ceil(seconds × voiceMinuteMicros / 60)`, never above the
  block's reservation; the rest is released in the same settle.
- expiry: a block whose window has elapsed settles in full on the next
  request that touches the session (renew, end or read). A running session
  with no open block left is ended, and the host is told to stop the bot.
- a host that will not start: the block is released (settled for zero
  seconds), the session is ended, nothing is owed.

The host's own session record is never the source of money. It may be used
to reconcile a dispute; the ledger is the truth.

## Routes

All under `/v1/accounts/{accountId}/voice/sessions/{sessionId}`, `sessionId` a
UUID the client mints. Scope `voice:session`.

| Method | Path | Result |
|---|---|---|
| PUT | `…/{sessionId}` | Start. Body optional: `{ "keyterms": [string ≤ 64] ≤ 80 }`. Reserves block 1, starts the bot, returns the session **with `wsUrl` and `token`**. Idempotent on `sessionId` for the same device; another device's id is `409 idempotency_conflict`. |
| POST | `…/{sessionId}/renew` | Opens the next block (reserve). Idempotent while a block is already waiting to start. `409 session_ended` after the last window elapsed. |
| POST | `…/{sessionId}/end` | Settles every open block by measured seconds; tells the host. Idempotent. |
| GET | `…/{sessionId}` | The session; never the socket. Settles elapsed blocks as a side effect. |

Session shape:

```json
{ "version": "1", "accountId": "…", "sessionId": "…", "state": "running" | "ended",
  "startedAt": "…", "endedAt"?: "…", "blocks": 2, "renewBy"?: "…",
  "chargedSeconds"?: "2400", "pricebookVersion": "…" }
```

`renewBy` is the end of the latest window: renew before it or the session
ends. Start additionally returns `wsUrl` and, when the host issues one,
`token`.

Errors: `402 insufficient_credit` when the next block cannot be reserved (the
app shows the credit standing); `503 service_unavailable` when this
deployment offers no voice host, or the host would not start.

## Price

`voiceMinuteMicros` is versioned with the pricebook and locked at each
block's admission. The placeholder at launch is 20,000 micros a minute (two
cents; a $10 grant buys just over eight hours). A version never changes its
rates; a new price is a new version.
