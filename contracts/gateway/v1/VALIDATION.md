# Credited-summary slice — local evidence, 13 September 2026

**Built and locally verified; not enabled in the app and not deployed.**
Public/native baseline: freshly fetched `origin/main` at `faf3362`.
Shared contract: `CONTRACT.lock.json`, canonical schema SHA-256
`52eaaaf041789538180e6b6dd27ca68edfc66503393fb273209ab8261bbdbd20`.

## Results

| Check | Result |
|---|---|
| Native full suite, including opt-in private-service HTTP drill | 1,656 XCTest + 61 Swift Testing = **1,717**, zero failures. |
| Private TypeScript type check | Pass (`npm run build`). |
| Private PostgreSQL/service tests | **24 passed**, zero failures/skips. |
| Cross-language local/remote/UTF-8 identity vectors | Same keys in Swift and TypeScript; all requests satisfy frozen schema. |
| Local credited summary drill | One fixture account; $10 once; synthetic $0.02 summary; one receipt; $9.98 available, zero held. |
| Lost response + reopened outbox + independent second outbox | Same operation/result/receipt, **one fixture-provider invocation** (asserted by server after native suite). |
| Runtime authority | Non-superuser/non-BYPASSRLS role; service refuses unsafe role; foreign-account access denied; scoped/expired/revoked fixture authority tested. |
| Ledger immutability | Updates/deletes/truncation refused; frozen intent and terminal outcome enforced by database triggers. |

The native suite adds 17 managed-summary tests, including its opt-in integration.
Its normal no-service run intentionally skips that one integration test; the
reported 1,717 run supplied a fresh local fixture and the server asserted exactly
one provider call afterward. No result depends on a real model/provider account.

## Financial and replay cases exercised

- 24 concurrent account/device requests grant once; a replacement service and
  changed device cannot mint another grant. Ineligible fixture principal gets none.
- 24 concurrent duplicate summary requests while the provider is paused: one
  reservation, one attempt and one settlement. Distinct concurrent operations
  cannot spend the same available balance.
- Same identity with changed input returns 409; JSON key order does not conflict.
  A genuinely edited source turn creates a distinct operation; inherited source
  history does not. Local request freeze survives changed carried goal/branch.
- Provider wait holds no idle database transaction; balance/other users remain usable.
- Definitive failure/invalid brief releases the hold and produces a zero receipt.
  Uncertain result holds credit without automatic re-execution; recovered-result
  and reviewed-no-charge reconciliation both tested, with idempotent resolution.
- Pre-attempt cancellation releases; running work survives cancellation and
  settles once. Abandoned-running-state fixture transitions to reconciliation.
- Pricebook changes cannot reprice admitted work; reusing a version with different
  rates refuses new work while preserving old-operation replay. Receipt and result commit
  together; reads/retries return the stored terminal outcome.
- Managed auth/pending/unknown remains visible in the Summary value alongside
  a free floor. No personal-key fallback. BYOK/empty source performs no Gateway
  call. Managed grounding scrubs locally without a paid retry, including the
  card/topic fallback when no authored recap survives.

## Environment and limits

The host rejected PostgreSQL's 56-byte shared-memory allocation on both
installed and native/thinned binaries. No kernel settings were changed. An
isolated Docker fixture used the already-cached PostgreSQL **16.15** image:

`postgres@sha256:f1c3376c26f2609ab9f29f71f824103fe2fcd8ee0346485cb6122a4f93df6f94`

Loopback random port, memory-backed disposable database, no host data mounts,
256 MiB / one CPU / 128 PIDs; fixture containers removed on completion. This
does not select the production PostgreSQL version or hosting target.

The integration injects response loss after service success and reopens SQLite
objects; it is **not** an OS-kill/power-loss experiment, a real two-Mac run or a
cloud network reliability test. The abandoned-worker test seeds state, rather
than killing a running production worker. Distributed leases, database COMMIT
response loss, backups, retention/encryption and operational recovery still need
deployment-level validation. No UI/panel drill was run and default app composition
is unchanged. Fake principals are not proof of deployed Hub token exchange.

The private fixture price is not a proposed selling price, provider-price audit
or proprietary cost ratio. Real usage normalization, provider selection and
grounding retries remain private-provider work. No payment/recharge, live key,
customer debit, cloud deployment or managed audio test occurred.

## Reproduce

Private repository: `/Users/robertnowell/Projects/tranquility-gateway` (no remote).
Use Node 22+, with the reviewed image already present and Docker running:

```sh
export TB_TEST_DATABASE=docker
export TB_GATEWAY_CONTRACT_DIR=/path/to/native/contracts/gateway/v1
export TB_NATIVE_ROOT=/path/to/native/worktree
npm run build
npm test
npm run test:native
```

The native-drill script owns a fresh service/database, runs the repository's
architecture-safe isolated full-suite script, asserts one fixture-provider call,
then closes the listener and removes its own fixture container. It does not
contact providers, payment processors or existing databases.

Next: real Hub authority exchange and private provider adapter, then a single
app-layer integration owner for stable event identity, mode-aware onboarding,
balance/receipt UX and real panel acceptance. See the updated
[launch plan](../../../docs/plans/credits-launch-2026-09-13.md).
