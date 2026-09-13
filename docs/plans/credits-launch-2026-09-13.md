# Credits launch: credited Coordinator built; next is Hub authority

## Onboarding alignment — latest user requirement, 13 September 2026

**One “Sign in to Tranquility Base” flow covers the app, Hub and managed
credits.** Hub authorization is not a separate account experience. Use the
existing browser session and device pairing; resolve the personal credit account
and refresh limited Gateway authority behind the scenes. No Gateway login,
Gateway token paste, personal API key or payment card is required to start in
managed mode. Payment/recharge consent remains a later, separate action.

The shared-session requirements and concrete integration/acceptance checklist
are now recorded in [AUTHORIZATION.md](../../contracts/gateway/v1/AUTHORIZATION.md).
This is the controlling requirement for the next Hub authority implementation
and the app onboarding work, not a claim that either has shipped. A credit
outage/empty balance must not look like sign-out; sign-out or account change
must invalidate the corresponding cached Gateway authority. Existing mirror-only
tokens do not silently acquire spending scopes.

## Continuation update — 13 September 2026

**No product decision or new login was needed for this step.** The remaining
C2 core wiring is implemented on `feature/credited-summary`, still not enabled
in the shipped app. The earlier implementation and investigation below are
historical snapshots; this section supersedes their next-step wording.

### Completed in this continuation

- Source provenance is stored with the event, before networking. Explicit local
  hook intake uses a stable producing-installation UUID and original session/event
  IDs. Imported/remote events carry their original `GatewaySource` unchanged.
  Missing provenance refuses managed work; it is not guessed from a rowid,
  current fork, viewing device, poll digest or changed text. Legacy events are
  not blindly backfilled. Re-fired hooks retain the first stored binding.
- Coordinator now supplies this source to the existing FULL-sync outbox/client.
  Overlapping managed preparations share one task. Pending/failure floors do
  not become permanent cache hits, and an already-cancelled preparation cannot
  create a new uncancelled paid task.
- Successful brief and receipt copy commit together in the queue cache. The
  association is validated against source/account/operation; a generic brief
  writer cannot silently erase it. Failed cache writes recover from the durable
  outbox. A stored result can be announced offline with its receipt intact.
- `Announcement` carries the typed managed failure or receipt before audio and
  after successful playback. This makes UI wiring possible; it is not evidence
  that the current panel displays those fields. Audio failure leaves the receipt
  intact. Existing free/BYOK/greeting briefs are not retroactively charged.
- The local HTTP/PostgreSQL drill now runs through Coordinator, not just the
  client. It loses a committed response, reopens queue and outbox, recovers by
  GET, restores an offline announcement, then imports the same source into an
  independent queue/outbox with different rowids. The service counts invocations.

### Main moved again, and is included

Rebased onto `82824903d03ca76ac4088949685d00d0425fee69`. This includes both
`a9d61e0` (reply heard-context/event text-ID lookup) and `#391` (provider seam,
agent events/turns, polling, config, grid assembly and conformance tests).
Only the test-count floor required conflict resolution. No app-layer files
were edited by this credits work; no running app was replaced.

The new agent-provider capability protocol is not the paid Gateway protocol.
It remains capability-driven and tolerant of unknown state. Gateway monetary
operations retain the frozen v1 contract and fail closed on unknown outcomes.
For remote narration, the future #372 ingress must carry provider-stable
`Turn.id`, raw task identity and stable installation/tenant namespace into
`GatewaySource`, after ownership filtering. `AgentSession.id` is an app address;
`AgentPoll.digest` is change detection. Neither substitutes for billing provenance.
This continuation tests Crobot/OpenCode-shaped sources; it does not ship their
real adapters, task filtering or cloud execution billing.

### Next, without another approval loop

1. **Next engineering milestone: real Hub-to-Gateway authority.** Implement the
   short-lived, audience/scoped, device-revocable exchange behind the existing
   Hub sign-in, with local verifier/exchange tests. Existing mirror credentials
   still do not automatically authorize spending. Continue private worker/usage
   foundation tests independently; no provider credential is needed for those.
2. **C2/C3 app activation, one app-layer owner:** persist the local origin UUID
   across upgrades; compose managed versus direct mode; wire real ingress and
   account/balance/historical receipt/error UI; reconcile the new provider-aware
   prerequisites with managed onboarding; run actual panel drills. Do not turn
   current mirror/grid events into paid requests by default. Receipt `balanceAfter`
   is a historical snapshot, never the current wallet balance.
3. **Before any remote/deployment/live-provider action:** resolve the private
   repository owner/location, secret placement, provider/pricebook and bounded
   test budget. Ask for a human step only if these are not already authorized
   and available. No such action was needed or taken for this local continuation.
4. **Then C4 payments**, followed by C5 premium speech/file recovery and C6 live
   audio. The frozen 24-session audio evidence and R1–R6 gates are unchanged.

Verification and limits for this continuation are recorded in
[COORDINATOR-VALIDATION.md](../../contracts/gateway/v1/COORDINATOR-VALIDATION.md).
The self-contained result/roadmap page is:
https://hq.tranquilitybase.dev/open?session=01a09b8d-c39b-7111-815c-6a09d382b46a&slug=credited-summary-coordinator

---

## Implementation update — 13 September 2026

The shared v1 boundary now lives in [contracts/gateway/v1](../../contracts/gateway/v1/README.md).
Native branch `feature/credited-summary` starts from freshly fetched main
`faf3362`, retaining the latest fork/Hub reconciliation work. Historical
gateway/audio evidence remains unchanged on its original branch.

Implemented locally (not deployed):

- **C0:** versioned request, source identity, operation, receipt and errors;
  scoped short-lived Gateway authority requirements; two remote-provider,
  local-turn and UTF-8 identity fixtures. Same turn/intent on two devices
  derives the same operation key. Fork identity is not a billing key.
- **C1 foundation:** a separate local-only private repository,
  `/Users/robertnowell/Projects/tranquility-gateway`, with no Git remote.
  TypeScript/PostgreSQL accounts, once-per-account $10 promotional grant,
  row-level isolation, append-only reservation/settlement/release ledger,
  immutable intent/pricebook/outcome, provider-attempt attribution and
  conservative uncertain-outcome reconciliation. Fixture provider only;
  synthetic $0.02 price is NOT a launch selling price.
- **C2 foundation:** Swift managed adapter and FULL-synchronous SQLite outbox,
  first-request freeze, durable terminal receipt, GET recovery after lost
  response, typed degraded outcomes and managed-vs-direct composition.
  Local safety scrubbing does not start another paid grounding invocation.
- **C3 local drill only:** native HTTP client to private HTTP service to an
  isolated PostgreSQL database, with an injected fixture identity/provider.
  This is not yet the real Hub-connected user / managed model / real panel.

### What is next, exactly

1. Review and land the frozen public contract and core adapter after the normal
   main/preflight checks; no app relaunch or main merge has occurred here.
2. Confirm the private repository owner/remote and implement the real
   Hub-to-Gateway authority exchange. Preserve user+device attribution and
   revocation; existing mirror tokens still cannot spend automatically.
3. Complete the production summary provider/usage adapter and private pricebook;
   keep provider retries within one operation. Add bounded worker ownership,
   crash/commit-loss recovery and operational reconciliation before deployment.
4. One app-layer owner composes managed mode, resolves stable event identity
   at ingestion, joins restored brief rows back to their managed receipts,
   wires account/balance/receipt states and mode-aware onboarding,
   then runs real panel drills. Current default app composition remains BYOK.
   The current Coordinator does not yet supply managed source identity; the
   new client/receipt path is exercised directly by the integration fixture.
5. Run one explicitly bounded real-provider integration after credentials,
   budget and service target are ready. Then C4 payment test-mode work; C5/C6
   remain speech/recovery/live-audio gates, not prerequisites for this summary slice.

No payment integration, real provider request, customer charge, cloud resource,
customer invitation or app deployment is part of this implementation.
The fixture tests are financial/conformance evidence, not a claim of production
auth, promotional abuse resistance, security review, uptime or managed-audio readiness.

### Evidence location

See `contracts/gateway/v1/VALIDATION.md` for the final run and its limitations.
The report for this implementation is:
https://hq.tranquilitybase.dev/open?session=01a09b8d-c39b-7111-815c-6a09d382b46a&slug=credited-summary-build

## Original planning baseline (preserved)

# Credits launch: current-main and cloud-agent integration plan

13 September 2026. Read-only investigation followed by this plan; no product
implementation, cloud deployment, paid API test or payment operation occurred.

## Evidence and precedence

- Native snapshot: fetched `origin/main`, pinned
  `ace70339de8ac81686db57bb79df2030fa03ae31` in a new worktree. The prior gateway
  plan used `b7ae6d1386c68d7303bcb708f4fdc5281259d5d2`. Eight intervening commits,
  41 files, 2,386 insertions/74 deletions. This is movement since the reviewed
  baseline, not a claim that all eight landed after our last conversation.
- One commit has a commit timestamp after the prior roadmap's 13 September
  15:28 UTC revision: `ace7033`, native Hub pairing (#377).
- HQ backend source: local `main` at
  `713b178d45b40d47b91dcf4871d20f9d6f1118ca`. Another session has active UI and
  publication changes; they were not edited. Backend source inspection is not
  proof of deployed database state. Live authenticated Hub discussion reads
  independently confirmed the latest discussion and working source links.
- Cloud-agent authority: [epic #366](https://github.com/robertnowell/tranquility-base/issues/366),
  updated 13 September 15:26 UTC, and its ten open children #367–376. This is
  later than the earlier read-only-first/OpenHands-last proposal. Both Crobot
  and local OpenCode fixtures/adapters start together; conformance runs from
  the model onward. The epic is open, not an implementation result.
- Crobot/Jarvis are local source snapshots without Git metadata. Findings from
  them are architectural observations, not a current remote-main audit.

Original product decisions remain: free Hub, $10 initial credit without a
card, pay-as-you-go dollar balance, $10 recharge increments, no launch expiry,
private versioned pricing, no customer spending/recharge cap. Explain recurring
charges and obtain consent. Hard payment failure visibly blocks new paid work;
admitted work is allowed to finish. No unlimited plan is assumed.

## What main changed that matters

| Change | Impact on credits |
|---|---|
| #377 native Hub connection | Reuse the existing human sign-in and Mac pairing. Do not build a second unrelated login. Existing mirror tokens do not yet have paid-work scopes/account attribution. |
| #364 panel-owned HubMirror | Reuse the existing result publication and transport/test seam. No separate Gateway-to-Hub content pipeline is required for the first native summary. |
| #358/#360/#365 failure reporting | Preserve reasons and show actionable payment/auth states, but expected refusal/offline polling must not become noisy operational alerts. |
| #357/#359/#362 local revival and dispatch guards | Cloud-agent integration must retain these guards for local rows and explicitly avoid applying process-only assumptions to remote rows. |

No changes to Summarizer, Speech, AssemblyAIStreaming or Transcription in this
range. RecoveryChain changes add diagnostics. This narrows the integration
impact; it does not rerun or upgrade the historical audio experiment evidence.

Native onboarding now requires both Hub and a direct Anthropic key. Managed
onboarding must satisfy the **summary capability**, not demand a personal
provider key. Preserve the new Hub connection decision; explicitly reconcile
the official BYOK setup versus standalone fork/self-host behavior instead of
silently overriding either product promise.

## How the three systems fit

**Hub:** human identity, reports, turns and presentation. Keep it free. Its
planned queued dispatch is a control-plane feature, not the credit ledger.

**Cloud-agent adapter:** lists/refines provider tasks, reads questions, starts
or sends when supported, and feeds normalized events into the app. Crobot owns
execution state; TB owns notification/read state. Failed observations are
unknown, not idle. The newest epic builds Crobot and local OpenCode together.

**Private Tranquility Gateway:** authorizes managed helper work, owns provider
keys and pricing, records operations/attempts and settles one customer debit.
The same summary/speech service can narrate local or remote agents.

Two axes stay independent: **where the coding agent runs** (local/cloud) and
**who supplies helper APIs** (managed/BYOK). Selecting Crobot does not select a
Tranquility credit-funded coding runtime.

| Activity | Tranquility credit treatment |
|---|---|
| Store/read Hub pages; poll task state; show a question/PR | No metered helper operation merely for observing or publishing. |
| Execute through the user's local coding-agent subscription | No Gateway debit for that execution. |
| Execute a Crobot task with the user's external credential | Crobot's existing execution/accounting, not resold through our wallet in v1. |
| Generate a managed summary, premium voice or transcription | One appropriately settled Gateway operation per logical delivered service. |
| Use direct helper API keys | User/provider relationship; no Tranquility credit debit. |
| A future runtime operated and funded by Tranquility | Separate explicit compute/model product and delegated authority, not silently included in voice credits. |

Crobot's task cost ledger is a mutable cumulative provider-cost record, not a
wallet, reservation or payment ledger. Do not reuse it as our financial truth.

## The joint contract to settle before two teams build independently

1. **Identity and authority:** one human identity; personal billing account for
   launch; explicit account membership. Preserve device identity through the
   auth layer. Define Gateway audience/capabilities, revocation and lifetime.
   Do not silently turn every existing mirror token into spending authority,
   or copy a broad human/device token into a cloud worker. Future owned workers
   need delegated run-scoped authority. Reuse sign-in, not unrestricted access.
2. **IDs:** provider/native task + TB agent/session + source turn/event +
   logical paid operation + provider attempt are separate identities. A cloud
   task spans many turns; a poll digest only detects change. Neither a task ID,
   SQLite row number nor a document content hash is the billable operation ID.
3. **Replay:** persist the canonical summary request and operation key before
   networking. Same intent after restart/lost response returns the same
   operation; changed intent is explicitly new. Remote event replay/two Macs
   must not manufacture a second paid summary. Filter Crobot tasks to the user
   before spool insertion or paid summarization.
4. **One owner for paid retries:** the existing client grounding path can call
   the provider again with a changed request. Put managed bounded paid retries
   and grounding attempts inside one Gateway operation; preserve client safety
   validation without an independent second billable operation.
5. **Honest outcomes:** currently try? swallows summary-provider failures. A
   managed auth/payment failure must remain visible even if a free local
   readout is shown. Task input-required/provider-auth and Gateway payment or
   sign-in errors must identify the correct service and recovery action.
6. **Delivery and privacy:** an available summary/card is the summary deliverable;
   audio playback is not its settlement signal. Define TTS/file-delivery and
   cancellation semantics separately. Never put raw recovery recordings through
   HQ's public-media upload path or put prompt/transcript bodies in ledger logs.

HQ currently has per-user tenancy, not a team billing-account model. Its
browser/device auth is implemented, but no paid account, wallet, operations,
payment or managed-summary routes were found in inspected HQ/native sources.
Native credentials are currently a user-only 0600 JSON file; comments calling
this Keychain do not make it Keychain. Paid credential storage/rotation needs
an explicit review. These are scoped source findings, not a claim about every
possible private repository.

## Implementation roadmap

Work-package identifiers below are planning labels, not newly filed issues.

| Package / owner lane | Deliverable | Acceptance / dependency |
|---|---|---|
| C0 — shared contract owner | Versioned account/authority, operation/request/receipt/errors and remote event-ID contracts; managed/BYOK composition rules. | Two provider fixtures plus local/remote-origin summary fixtures fit unchanged. Tenant A cannot access/spend B. Agree shared fields with #367/#372/#375. Start now, no real keys. |
| C1 — private Gateway owner | Personal accounts, one-time promotional grants, append-only ledger, operations/attempts, pricebook versions, reserve/settle/release and reconciliation. | Deterministic offline harness: concurrent retries, multiple devices, account isolation, cancellation and uncertain provider response. $10 once per eligible account, not per install. Depends C0. |
| C2 — native core owner | Managed adapter, frozen request/outbox, receipt cache and truthful degraded results; reuse SummaryProvider and existing Hub publication. | Duplicate event, process restart, lost server response, changed-request conflict and grounding retry preserve one logical debit. BYOK unchanged and cannot spend. Depends C0; can build against simulator alongside C1. |
| C3 — integration owner | Existing Hub-connected user → account/balance → one real managed summary → one receipt. Mode-aware onboarding and visible auth/payment door. | First internal product milestone. Controlled provider test only after service/credentials/budget are ready. Core tests plus real panel drills; a mocked path is not real integration. Depends C1+C2. |
| C4 — payments owner | Hosted card setup, explicit recharge consent, verified webhooks, serialized recharge, receipts and reconciliation. | Duplicate/out-of-order events cannot double-grant/charge; invalid signatures cannot grant. Pending payment, hard decline/bank-action and refund/chargeback reconciliation paths work. No customer spend cap. Test environment first. Depends account/ledger contract. |
| C5 — managed capabilities owner | Premium speech, then private saved-file transcription/recovery using the same operations. | Per-capability cost receipts and cancellation rules; preserved recording and completed recovery, not just a recovery-needed status. No double debit for failed live + successful recovery. Depends C3 and provider-specific tests. |
| C6 — audio/integration owners | Managed live stream, team canary and scoped external cohort. | Historical R1–R6 checks: finality, recording, representative failure/latency, bounded resources and attribution. No claim of managed-audio readiness from the 24 local sessions. |

The first internal demonstration is **connect the existing account → grant
$10 once → one managed summary → one correct receipt**. It is not the entire
external launch. A cohort receives only capabilities whose financial,
security, UX and reliability gates pass; do not advertise full managed voice
because summaries work.

Before the cohort, define promotional eligibility and signup-abuse controls,
and test that re-pairing, reinstalling or adding a device cannot repeat the
grant. These protect the free offer; they are not a monthly customer spend
cap. Lock the quoted pricebook version to admitted work rather than repricing
an in-flight operation when a private rate changes.

Pricebook work runs alongside C1: normalized summary token receipts (all
attempts), TTS generated/billable units versus played units, transcription
duration/failed-attempt costs, and infrastructure/payment overhead. Historical
September 7 prices and rough markups are not a current cost audit. Keep rates
and provider selection private/versioned; do not block contract work on a
30-day usage study or reopen subscriptions before observing cohorts.

## Coordinate with work already filed

- Reuse [#366](https://github.com/robertnowell/tranquility-base/issues/366);
  do not create a second cloud-agent epic. #367 model, #368 Crobot and #369
  local OpenCode concurrently, #370 poller, #371 rows/guards, #372 spool,
  #373 replies, #374 create, #375 conformance throughout, #376 credentials.
- Cross-team integration gate before #372 is billable: stable source turn IDs,
  replay/multiple-device behavior, user-task filtering and the frozen summary
  request contract. Poll observations are not automatically paid requests.
- One app-layer integration writer for Secrets/Prerequisites/SetupChecklist,
  composition and shared UI changes. Core/private-service work can proceed
  separately; parallel agents do not authorize competing app-layer edits.
- [#326](https://github.com/robertnowell/tranquility-base/issues/326) remains
  OPEN and reproduced by source inspection: OpenAI is supported in Secrets and
  file recovery but not offered in prerequisites/checklist; CLI help omits it.
  Keep this BYOK repair separate, coordinated with onboarding edits.
- Keep the frozen 24-attempt WSS definition from `d92f746` on the preserved
  gateway-validation branch. It still needs an implementation/executable
  freeze, current-baseline check and bounded run. It does not gate C0–C4.

## Human steps and limits

No human key is needed for C0/C1 simulator work or two-provider stub fixtures.
A live Crobot verification needs a revocable per-user Jarvis key, not the
global admin key. Earlier research warns that Jarvis permission/org choices
do not reduce Crobot team-member visibility; client filtering is not server
authorization. Live credential and account-boundary testing remains unproven.
The local OpenCode protocol fixture needs no account, but real model execution
can still incur provider cost and is not called free compute.

Later: confirm the private-service repository/deployment owner, provider secret
placement and a payment test environment before live integration. No new
provider account, private repo, cloud resources, customer invitation, issue,
PR, rebase of the historical experiment, or app deployment is performed here.

## Code anchors inspected

### Follow-up: prompt-edit identity regression, 13 September

A later main snapshot, `3a45692`, includes the fork-identity fixes #378/#384
and the linkage correction #385. The live credits workstream had one user
thread and six retained subagent writer locks in PID 91395. Its ownership
record is now `01a09b8d-c39b-7111-815c-6a09d382b46a`, continuing
`01a07eba-fa51-79a2-ade7-d416cb916dd0`; the app logged that migration at
17:07:55 UTC. A read-only shipping-classifier check during the 18:24 UTC turn
reported the child as working. No visual-grid acceptance or new prompt-edit
reproduction was performed; no additional product fix was applied here.

Carry this into C0/C2 fixtures: a runtime thread may change while the same
process and conversation continue. Inherited history and re-published reports
must not generate new grants or repeated historical summary debits. A newly
edited turn may intentionally produce a new operation, while transport retries
of that same operation keep its frozen request and idempotency identity.
Conversation lineage is presentation/correlation, not a billable-operation key.
Refresh the implementation branch against current main before building C0.

- Native: `HubPairing.swift:150`, `HubMirror.swift:35`, `Prerequisites.swift:147`,
  `Summarizer.swift:66`, `:614`, `:678`, `Coordinator+Announcer.swift:374`, `:412`,
  `Spool.swift:89`, `QueueStore.swift:110`, `Secrets.swift:113`.
- HQ: `lib/auth.ts:72`, `lib/db.ts:34`, `db/schema.sql:228`,
  `db/007-device-claims.sql:54`, `docs/dispatch.md:1`, `lib/blobs.ts:58`.
- Prior product roadmap: https://hq.tranquilitybase.dev/open?session=01a07eba-fa51-79a2-ade7-d416cb916dd0&slug=gateway-roadmap
- Original credits: https://hq.tranquilitybase.dev/open?session=01a07eba-fa51-79a2-ade7-d416cb916dd0&slug=tranquility-credits
- Original Gateway: https://hq.tranquilitybase.dev/open?session=01a07eba-fa51-79a2-ade7-d416cb916dd0&slug=tranquility-gateway
- Cloud discussion: https://hq.tranquilitybase.dev/open?session=bee124ae-b85d-48bf-b689-651c1c7d2e19
- New report: https://hq.tranquilitybase.dev/open?session=01a09b8d-c39b-7111-815c-6a09d382b46a&slug=credits-launch-plan
