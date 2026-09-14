# Credited summary contract v1 — frozen 2026-09-13

This is the public client/service boundary, not the private pricebook or ledger.
Breaking changes require a new version. `summary.schema.json` and the fixtures
are executable conformance inputs. Currency is USD; money is a decimal string
of integer **millionths of a dollar**, never a JSON floating-point amount.

## Authority

**One onboarding sign-in covers the app, free Hub and managed credits.** The
Gateway exchange is background authorization from that same app session, never
a second login or account signup. See [AUTHORIZATION.md](AUTHORIZATION.md) for
the shared-session, onboarding, refresh/revocation and acceptance requirements.

All routes require a Gateway-audience bearer, verified on every request for
issuer, signature (or opaque-token lookup), expiry and device revocation. The
trusted verifier supplies immutable `userId`, `deviceId`, audience
`tranquility-gateway`, capabilities and server-side promotional eligibility.
Maximum bearer lifetime: 15 minutes. An existing Hub mirror token is NOT a
Gateway bearer. A future Hub exchange may reuse the human sign-in, but must
explicitly mint this authority; no second human login is required by this API.
Workers must not receive a human/device bearer. Run delegation is outside v1.

The service resolves the user's personal billing account; account membership
is enforced on every route, including GET/replay. Device IDs are audit
attribution, not grant or wallet keys. No caller-supplied user/account claim
can create membership. Revocation and scope checks precede replay responses.

| Route | Capability | Result |
|---|---|---|
| POST `/v1/account` (empty body) | `account:read` | Personal account and balance; one eligible $10 lifetime launch grant, never per device/install. |
| GET `/v1/accounts/{accountId}/balance` | `account:read` | Current balance snapshot. |
| PUT `/v1/accounts/{accountId}/summaries/{operationId}` | `summary:create` | Admit or replay exactly this frozen request. |
| GET same summary URL | `summary:read` | Retrieve existing outcome; never starts a provider call. |
| POST same summary URL + `/cancel` | `summary:create` | Cancel only before provider start; admitted running work finishes. |

No payment/recharge endpoint is frozen here. The launch has no expiration or
customer spend/recharge cap; payment consent is a separate implementation gate.

## Source identity and replay

Request shape: `{version: "1", source, input}`. `source` has four opaque strings:
`namespace`, `taskId`, `turnId`, `intentId`. The normal intent is `summary.v1`.
An explicit new summary intent uses a new durable intentId, never a retry nonce.
`namespace` identifies a provider AND its stable installation/tenant authority,
not the viewing device. Remote integrations MUST filter authorized/owned tasks
before requesting paid work, and provide provider-stable turn IDs. An adapter
without stable identity is not ready for managed narration. Local events use
their original stable event identity, not SQLite rowid, PID or current fork ID.
Inherited fork history preserves the original source; a genuinely edited new
turn gets its own turnId. Session lineage, task state and polling digests are
not paid-operation keys. Local and both remote fixture shapes share this API.

Both sides derive `operationId` from identity, NOT summary content:

1. Start with UTF-8 bytes `tb.summary.v1` followed by one zero byte.
2. For lower-case account UUID, namespace, taskId, turnId, intentId in order,
   append ASCII decimal UTF-8 byte length, ASCII colon, then exact UTF-8 bytes.
   No Unicode normalization, JSON escaping, delimiter splitting or whitespace trim.
3. SHA-256 the bytes, take first 16 bytes; set byte 6 high nibble to 8 and byte 8
   high two bits to binary 10. Format as a lower-case UUID.

This makes two Macs choose the same key for the same logical service. The server
verifies the key. It normalizes the strictly validated request's object-key order
before comparison: same key + same request replays; changed request returns 409
`idempotency_conflict`. Optional input fields are omitted, not null.
Persist the FIRST request before sending. Resume uses this frozen payload even
if current carried goal, branch or presentation/session identity has changed.
The first device's request is authoritative; conflicting context on another
device is visible, not a second debit. It may GET the existing operation.

## Lifecycle and delivery

`admitted → running → succeeded | failed | reconciling`; admitted may be
`cancelled` before any provider attempt. Operations in `reconciling` are never
automatically re-executed. A timeout is not evidence the provider did no work.
Explicit internal reconciliation may resolve one uncertain attempt, without
minting a new operation or repeating the provider request.

The pricebook version and maximum reservation are locked at admission. Provider
attempt IDs are private and distinct from the customer operation. Bounded
grounding retries, if enabled, belong inside it. The client may scrub unsafe
output but may not create another paid grounding call.

Success means a validated SessionBrief and receipt are durably retrievable in
one committed transaction with the debit. It does NOT mean spoken, played,
mirrored to Hub or acknowledged by the client. A lost HTTP response is recovered
by GET. Terminal failures/cancellations release reservations and have zero-charge
receipts; uncertain work retains its reservation pending reconciliation.
Current balance is a separate GET: `balanceAfter` on a receipt is a historical
snapshot, identified by its ledger sequence. No database transaction stays open
across a provider call. No prompt/transcript text goes in the ledger or HTTP logs.

200: terminal operation or account/balance. 202: admitted/running/reconciling.
401: auth_required. 403: forbidden. 404: not_found (including foreign accounts).
409: idempotency_conflict. 402: insufficient_credit. 400: invalid_request.
503: service_unavailable. Errors use `{error:{code}}`; an operation may carry
`provider_failed` or `provider_uncertain`. Unknown versions/states fail closed.
No transport redirects may forward a credential. Request limit: 128 KiB.

## Client composition

Managed mode uses only the explicitly supplied Gateway credential/transport.
BYOK mode uses only direct providers and makes no Gateway request. Choose a
composition for each operation; switching mode does not mutate in-flight work.
Managed refusal/pending/unknown must remain a typed outcome even when a free
deterministic fallback is displayed/spoken. Do not hide it via `try?`, fall
through to a personal API key, or describe a local floor as a paid success.

## Release boundary

The native integration now persists source bindings at ingestion and copies a
validated receipt alongside each successful cached brief. See
[COORDINATOR-VALIDATION.md](COORDINATOR-VALIDATION.md) for the current evidence;
[VALIDATION.md](VALIDATION.md) preserves the earlier client-only drill.
Local producers use `local:<stable-origin-installation-UUID>`, original session
ID and original event UUID. Imported events MUST preserve that source, not
re-enter the local-hook mapper. An unset origin or unproven legacy source is a
managed refusal, not a reason to mint new provenance. App activation remains
separate. Historical receipt copies do not confer current spending authority
and must not be presented as a current wallet balance.

This freeze enables C0, C1 and C2 locally. Real Hub-to-Gateway authority exchange,
provider credentials/prices, panel/onboarding composition, retention, operational
reconciliation and payment flows are NOT proven by fixtures. No public launch
or managed audio release is implied. Changes discovered by integration must
revise the contract explicitly, with conformance fixtures, not silently diverge.

## Summariser prompt

`summary.prompt.txt` is the system prompt the app sends the model, verbatim.
It is one file on purpose (ruled 2026-09-14): a provider behind this gateway
uses this text and nothing else, so the app and the gateway cannot drift.
`SummaryPromptContractTests` holds the app's Swift literal to this file byte
for byte. The user turn is assembled per request from the frozen `input`
fields (see `AnthropicSummaryProvider.userPrompt` in the app); a provider
either receives it compiled or ports that function unchanged. The `brief` in
`summary.schema.json` is the flat shape; the app also accepts the nested
`spoken`/`written` shape the prompt asks for, and a provider may return either.
