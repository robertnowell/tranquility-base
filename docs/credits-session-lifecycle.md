# CL-02 / CL-03: one managed session, truthful standing

Implements the A7–A9 package approved 15 September 2026. This is not a
deployment, payment implementation, or external launch decision.

## Ownership

The app constructs one `ManagedCreditSession` before sign-in and retains it in
the Coordinator's provider chain. Hub credential writes notify that session;
it prepares the account and reads its balance without invoking a provider.
Setup observes standing changes, so completing pairing updates the existing
checklist without a restart or personal summary key. Token presence alone
does not count as verified managed readiness. Direct-key setup still works.

Each identity gets a separate context: an immutable Hub/token binding, an
authority instance, account resolver, generation and account-keyed outbox.
Every managed operation rereads identity; the Hub token deliberately bypasses
the general per-launch secret cache. A replaced/removed token cannot silently
leave this process spending as the previous account. Old connections refuse
new sends; in-flight results may settle and are retained in their original
outbox but cannot publish into the next identity's UI. A cancelled context
does not manufacture a fallback summary.

No routine cross-session message or shared-checkout edit was used. This work
is isolated on `fix/credits-session-lifecycle`, based on the open credit-standing
branch; its owner’s work is retained, not overwritten.

## Balance is not a receipt

Receipts stay historical and immutable. The managed session uses GET balance
after a successful summary (including replay) and during sign-in preparation.
It rejects older ledger sequences and late status updates. Cached successful
operations cannot clear an exhaustion/failure warning; new successful work
and a fresh balance can. A failed balance request never discards a successful
paid operation's receipt. The row says “at last balance check”, not a promise
that another device has not spent since.

This adds a balance read to summary completion. It introduces no new polling
loop and no additional provider call. A network delay in that read currently
uses the existing transport timeout; quantify it in live acceptance before
release, alongside the original latency checks.

## Validation

`ManagedCreditSessionTests` exercises a chain created before pairing, key-free
onboarding, A→B account transitions, sign-out, late account resolution, late
paid completion saved for A, replay without another debit, stale balance
responses, exhausted-wallet replay, and balance-read failure after payment.
`GatewayAuthorityTests` also exercises cached and in-flight device-token
replacement/removal against the actual authority implementation.

The app's `--selftest-credits-onboarding` route runs the real checklist with
fixture services before AppDelegate exists: no microphone, hotkey, browser,
real credentials, production requests, or installed-app replacement.

Remaining separate acceptance: signed-app browser pairing/key enrollment,
live provider completion, multi-device/revocation-while-spending and deployment
ownership. Unit tests and the isolated UI drill do not certify those paths.
