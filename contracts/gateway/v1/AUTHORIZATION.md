# One app sign-in: Hub identity and managed credits

User requirement, 13 September 2026: Hub authorization and in-app credit
authorization are one onboarding sign-in experience, not separate registrations
or logins. This document constrains the upcoming implementation; it does not
claim that the authorization exchange or managed onboarding has shipped.

## User-facing contract

1. Onboarding has one **Sign in to Tranquility Base** action. Reuse the existing
   Hub browser sign-in and app-initiated device pairing. If the browser already
   has a valid session, do not ask the person to authenticate again. Keep the
   existing device-possession confirmation inside that flow.
2. The same signed-in user owns the free Hub and the personal Gateway billing
   account. Gateway account resolution and eligible once-per-account $10 credit
   happen automatically; there is no second account form or Gateway login.
3. Obtain and refresh limited Gateway authority behind the scenes. Do not show
   a Gateway token field, manual authorization-code paste, or another sign-in
   checklist row. Scope separation is a service boundary, not another identity.
4. Managed onboarding does not require personal model/provider API keys or a
   payment card. BYOK remains an explicit advanced/direct configuration. Third-party
   agent-provider credentials and macOS permissions are separate integrations,
   not a second Tranquility identity; don't imply this sign-in authenticates them.
5. Payment setup comes when needed for further paid usage. It is not authentication.
   Recurring recharge consent remains explicit and separate from signing in.

The wire format that carries this authority, and what the Gateway checks before
honouring it, is [TOKEN.md](TOKEN.md). It was written 14 Sep and implements no
new decision: the Principal it produces is already frozen in `Gateway.authorize`.

## Shared session; separate service authority

- **Identity:** Hub's immutable internal user UUID is the trusted Gateway
  principal user ID. Never join accounts by email, Mac name, client-supplied
  account ID or a new per-device user. Gateway resolves its billing account
  server-side and the existing once-per-account grant remains authoritative.
- **Device attribution:** retain the stable device UUID from the paired device
  record. Use that record's revocation state, not a new Gateway-only device list.
- **Enrollment:** the first app onboarding approval establishes the intended
  managed-app capability alongside Hub connection. Legacy/mirror-only credentials
  do not automatically gain spending rights. An existing user who needs the app
  capability completes the same app connection flow using their existing browser
  session; do not introduce a second Gateway identity or independent login.
- **Exchange:** an authorized app session obtains the frozen Gateway audience,
  required scopes and a bearer lifetime of at most 15 minutes. Server policy
  controls eligibility/scopes. A client flag cannot upgrade a mirror token.
- **Refresh:** cache short-lived authority in memory and refresh silently while
  the shared app session is valid. Coalesce simultaneous refreshes. Gateway
  credentials are never sent to the Hub mirror, provider APIs, browser URLs or logs;
  the app's Hub credential is never sent directly to Gateway/provider APIs.
- **Revocation:** Gateway must enforce linked-device revocation on requests,
  including GET/replay, as required by v1. A signature-valid unexpired token
  alone is not sufficient proof that its device is still authorized.
- **Sign-out/account change:** invalidate that app session's cached Gateway
  authority and pending refresh results. A refresh started under A cannot install
  credentials after switching to B. Use separate account-keyed outboxes; never
  replay A's pending operation under B. Historical receipts stay attributed to A,
  not shown as B's current balance. Other devices/browser sessions need not be
  globally logged out by a local app sign-out.

## Authentication is not service readiness or balance

| Condition | App interpretation |
|---|---|
| Hub sign-in succeeds; credit account still loading | Signed in; managed services are preparing. No second sign-in. |
| Short-lived Gateway token expires; app session valid | Refresh in the background; preserve operation identity. |
| Gateway/exchange unavailable | Signed in; managed service temporarily unavailable with retry. Free Hub remains available. |
| Insufficient credit | Signed in; balance/payment action. Under the 15 September ruling, an already-pasted personal key may take over, with the credit-standing warning explaining the fallback. Do not request authentication. |
| Confirmed app credential invalid/revoked | Clear that session's authority; return to the same app Sign in action. |
| Missing managed-app capability | Use the existing connection/authorization flow, not a Gateway login or silent scope escalation. |
| Managed operation admitted before disconnect/expiry | Existing operation may finish; reconnect retrieves it without another debit. |

Do not turn every 401 into a browser prompt: first distinguish an expired
Gateway bearer from an invalid shared app session. Network failure is not proof
of revocation. UI readiness must not call an account signed out merely because
its balance or managed service could not be fetched.

## Grounded implementation seams

Inspected native `32ac004` (main baseline `8282490`) and HQ `d3f2ad2`:

- `Sources/TranquilityApp/SetupChecklist.swift` already routes the Hub row into
  `HubConnect.begin()`. This is the one entry point to extend, not duplicate.
- `HubPairing` / `HubConnect` already perform app-initiated pairing and adopt the
  Hub credential. The claim response includes `device_id`, but native collection
  currently retains only the token and display name; preserve stable identity
  when implementing shared app-session state.
- HQ `app/connect/page.tsx` reuses its existing signed-in browser session.
  Extend its app-connection wording/authorization, not a new Gateway login page.
- HQ `hq_user_for_token` already returns user and device IDs. `lib/auth.ts`
  currently drops the device ID; the scoped exchange must retain it and fail
  closed for bad tokens. Do not use the development-user fallback as production
  paid authority.
- `Prerequisites` currently requires the direct summary key independently of
  Hub connection. Managed composition must replace that requirement with verified
  managed-service readiness while keeping direct mode's existing requirements.
  Hiding the key field without supplying a real managed summarizer is not completion.
- `ManagedSummaryClient.connect` already resolves the account/grant; its transport
  accepts an injected bearer source. Feed that from shared app-session authority,
  never a new stored Gateway login. The private service verifier remains injected
  until the real Hub exchange and linked-device revocation path are implemented.

## Acceptance gates before managed onboarding can ship

- Fresh user completes one sign-in/pairing flow and receives Hub plus managed
  account access, with no personal API key or card required.
- Existing browser session is reused. Second device resolves the same account
  and does not create a second welcome grant.
- Expiry refresh, concurrent refresh, sign-out during refresh, account switch,
  wrong audience/scope, legacy mirror-only credential and revoked device tests.
- Exchange outage and empty balance keep the user signed in. Outage uses the
  free floor; empty balance may use an already-pasted key with an explicit
  standing warning (15 September ruling). A valid Hub session alone does not
  fake credit readiness.
- Actual panel drill confirms a single sign-in action, background preparation,
  correct mode-specific prerequisites and no separate Gateway authentication UI.

Local/session tests and server exchange implementation precede a bounded real
sign-in/credit integration test. No new product decision is needed for this
alignment; deployment/credentials/live-spend authorization remain separate gates.
