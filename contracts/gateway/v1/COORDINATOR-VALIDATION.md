# Credited Coordinator — local evidence, 13 September 2026

**Implemented and verified locally. Not enabled, merged, deployed or billed.**

Native implementation commit: `5a7e41f` on `feature/credited-summary`, rebased
onto main `82824903d03ca76ac4088949685d00d0425fee69` (#391 provider seam).
Private fixture remains `f5a3cb75fafdf33f54504fbc9167085ca84abe21` in the
local-only `/Users/robertnowell/Projects/tranquility-gateway` repository.
The frozen wire schema and identity fixtures did not change. Canonical SHA-256:
`52eaaaf041789538180e6b6dd27ca68edfc66503393fb273209ab8261bbdbd20`.

## Final measured run

Run completed 13 September 2026, by 20:19 UTC, after the second main rebase.

| Check | Result |
|---|---|
| Architecture-safe native full suite | **1,746 XCTest + 61 Swift Testing = 1,807 tests; zero failures.** |
| Opt-in native → private HTTP → PostgreSQL drill | Passed within that full run; **exactly one fixture-provider invocation**, asserted independently by the service runner. |
| Private TypeScript build | Passed (`npm run build`). |
| Private SQL/HTTP service tests | **24 passed**, zero failures/skips (`npm test`). |
| New provider-seam compatibility-comment gate | Passed: five current markers; no expired/malformed markers. |
| New credited-Coordinator tests | **16**; the previous 17 managed-client tests remain, with their opt-in drill upgraded to Coordinator. |

The initial run before #391 was 1,679 + 61 = 1,740, also green. Main added
67 XCTest tests; these are included in the final 1,807 total, not claimed as
new credits tests. Both frameworks ran explicitly through `scripts/test.sh`.

## What the integrated drill proved

1. Connect one fixture account twice: one $10 grant.
2. Insert an event with its original source. Coordinator prepares it through
   the managed adapter, which freezes the first request in its SQLite outbox.
3. Private service commits a synthetic $0.02 result/debit/receipt; the transport
   deliberately discards the response. No successful brief is cached locally.
4. Reopen queue, outbox and Coordinator. GET recovers the existing operation;
   brief and validated receipt copy commit together. Audio is still unplayed.
5. Reopen again with an offline transport. Announcement restores the receipt
   without networking. The before-speech callback also carries metadata.
6. Import the same source into an independent queue/outbox with different local
   rowids. Coordinator submits the same intent and receives the same receipt.
7. Fetch balance: **$9.98 available, $0 held**. Runner asserts **one provider call**.

The fixture price is not a proposed selling price, markup or provider-cost
calculation. This is two independent local stores, not two physical Macs.

## Added failure and provenance checks

- Opt-in local spool ingestion binds the stable producing-installation namespace
  and original event; duplicate ingestion cannot replace it. Copied provenance
  survives changed rowids/presentation, and an edited event derives a new key.
- Source bindings are immutable; an unknown event cannot be bound. No implicit
  provenance for legacy events. Missing identity makes no network call and the
  spoken free floor retains `.missingSourceIdentity`.
- Crobot/OpenCode-shaped source namespaces reach the managed request unchanged.
  These are source conformance fixtures, not real remote adapters or ownership tests.
- Lost response stays `.outcomeUnknown` through Announcement, then a reopened
  Coordinator recovers by GET. Pending preparation is not cached forever.
- Twelve overlapping preparations share one invocation; a pre-cancelled
  preparation cannot start uncancelled paid work or poison the next preparation.
- Injected receipt-cache write failure rolls back the brief write. Reopened
  outbox restores both offline. A missing receipt copy also recovers offline.
- A receipt cannot attach to the wrong source event; a generic brief writer
  cannot erase a receipt association. Corrupt receipt metadata in BYOK mode
  keeps the existing content with a typed failure, without calling a personal provider.
- Failed audio retains the receipt and does not advance the automatic heard
  cursor. Existing authored/free/direct briefs remain usable without retroactive billing.

## Limits and remaining release gates

The queue receipt is a validated local copy, not a ledger. The FULL-sync outbox
and private Gateway retain the durable operation. Historical receipts keep their
original account and balance snapshot; app account switching must not interpret
those as current wallet state or authority. That UI has not been built/tested here.

Default app composition and local intake remain unchanged until explicitly
configured. Production must persist one local origin UUID across upgrades and
keep imported events out of the local-hook mapper. Legacy-source backfill needs
proven provenance, not new IDs. Real #372 remote ingress must enforce ownership
and carry raw provider task/stable turn/tenant identity; app session IDs and poll
digests are not billing IDs. The new provider seam is included but not monetized.

No real Hub token exchange, provider call, production prices, payment, panel/UI
drill, process-kill/power-loss test, cloud reliability experiment or audio release
test occurred. Bounded worker ownership/commit-loss recovery, real authority,
operational reconciliation, retention/backups and live-provider acceptance remain
release work. Historical WSS/24-session evidence is unchanged.

The fixture reused the pinned, already-cached PostgreSQL 16.15 Docker image and
the isolation/cleanup described in [VALIDATION.md](VALIDATION.md). No existing
database/container was modified or stopped. Our disposable fixture containers
were removed; no deployment resource was created.

## Reproduce

In the private fixture repository, with Node 22+, Docker already running and the
reviewed image cached:

```sh
export TB_TEST_DATABASE=docker
export TB_GATEWAY_CONTRACT_DIR=/path/to/native/contracts/gateway/v1
export TB_NATIVE_ROOT=/path/to/native/worktree
npm run build
npm test
npm run test:native
```

The runner owns a fresh loopback service/database and supplies the opt-in URL
to `scripts/test.sh`. A normal native test run without it intentionally skips
the one HTTP integration; the reported final run included it.

Next engineering milestone, not another product-approval question: implement
Hub-to-Gateway scoped authority and then complete single-owner app activation.
See the current [source plan](../../../docs/plans/credits-launch-2026-09-13.md).
