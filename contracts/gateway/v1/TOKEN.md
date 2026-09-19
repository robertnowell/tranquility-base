# The Gateway access token, exactly

How a paired Mac gets authority to spend, and how the Gateway decides to honour
it. This is the wire half of [AUTHORIZATION.md](AUTHORIZATION.md), which states
the user-facing requirement; nothing here relaxes anything there.

Written 14 September 2026. **Not yet implemented on either side.** The Principal
this produces is already frozen in `src/gateway.ts` and enforced by
`Gateway.authorize`, so the freedom here is smaller than it looks: the token
exists to fill in that shape and nothing else.

## What the Gateway already insists on

`Gateway.authorize` refuses unless all of this holds, today, before any of the
below is built:

- `userId` and `deviceId` are both UUIDs. A user alone is not a principal.
- `audience` is exactly `tranquility-gateway`.
- `issuedAt` is not in the future, `expiresAt` is in the future, and
  **`expiresAt - issuedAt` is at most 900,000 ms**. The fifteen-minute ceiling
  is code, not prose.
- `revoked` is false.
- The scope required by the route is present.

So a verifier's whole job is to produce that struct honestly, or nothing.

## The access token

A JWT following RFC 9068, the JWT profile for OAuth 2.0 access tokens.

Header: `typ` is `at+jwt`, `alg` is `ES256`, `kid` names the signing key in the
hub's JWKS. `alg` of `none`, or any MAC algorithm, is refused before anything
else is read.

| Claim | Becomes | Rule |
|---|---|---|
| `iss` | (checked, not stored) | Exactly the hub issuer. A token from anywhere else is not a token. |
| `aud` | `audience` | Exactly `tranquility-gateway`. |
| `sub` | `userId` | The hub's internal `users.id` UUID. Never an email, never a Clerk id, never a client-supplied account id. |
| `device` | `deviceId` | The `device_tokens.id` UUID. There is no separate device table: the token row is the device. |
| `scope` | `scopes` | Space-delimited, per OAuth convention. Vocabulary today: `account:read`, `summary:read`, `summary:create`. |
| `iat` | `issuedAt` | Seconds. Multiplied by 1000 at the boundary, once. |
| `exp` | `expiresAt` | Seconds. The hub MUST NOT issue `exp - iat` greater than 900. |
| `cnf.jkt` | (matched, not stored) | Base64url SHA-256 JWK thumbprint (RFC 7638) of the Mac's public key. See binding. |
| `promotional_eligible` | `promotionalEligible` | Hub-decided. The Gateway owns the ledger; the hub owns who is eligible for a welcome grant, because eligibility is an identity and abuse question and the ledger cannot see those. |

**`revoked` is not a claim and must never become one.** The Gateway sets it from
its own revocation state at verification time. A token that could assert its own
liveness is a token that cannot be withdrawn, which is the whole failure this
design exists to avoid.

## Binding: the token is useless without the key

Sender-constrained per RFC 9449 (DPoP). RFC 9700, the OAuth security best current
practice, says a resource server SHOULD sender-constrain, and this one spends
money.

The Mac holds a P-256 key in the **Secure Enclave**, where it cannot be exported
by anyone, including someone who can read every file on the machine. Its
thumbprint is registered **at pairing**, not at first spend: a long-lived device
token sitting in a file that could mint a freshly bound access token would leave
the front door exactly as open as before, while appearing to have been hardened.

Every request carries:

```
Authorization: DPoP <access token>
DPoP: <proof JWT>
```

It is `DPoP`, not `Bearer`, and a bound token presented as a bearer token
**MUST be rejected**. There is deliberately no transitional period in which both
work, because a mode that accepts an unbound presentation is the mode an attacker
will ask for.

The proof is a JWT with `typ: dpop+jwt`, `alg: ES256`, the public key in the
`jwk` header, and claims:

| Claim | Content |
|---|---|
| `jti` | Unique per proof. At least 96 bits of randomness. |
| `htm` | The request's HTTP method. |
| `htu` | The target URI **without query and fragment**. |
| `iat` | Creation time. |
| `ath` | Base64url SHA-256 of the ASCII access token. Required whenever a token is presented, which here is always. |

## What the verifier checks, in order

1. Exactly one `DPoP` header, one well-formed JWT.
2. `typ` is `dpop+jwt`; `alg` is asymmetric and supported; never `none`.
3. The proof's signature verifies against the `jwk` in its own header, and that
   `jwk` carries no private key.
4. `htm` matches the method; `htu` matches the request URI after RFC 3986
   syntax and scheme normalization, ignoring query and fragment.
5. `iat` is within the acceptance window.
6. The access token's signature verifies against the hub JWKS by `kid`, and
   `iss`, `aud`, `exp` and `iat` hold.
7. `ath` equals the hash of the presented access token, and the proof key's
   thumbprint equals the token's `cnf.jkt`.
8. **The device is not revoked**, from the Gateway's own store. This runs on
   every request, which the seam gives for free: `server()` in `src/http.ts`
   calls `verify` before routing, so replay and idempotent GET of an
   already-created operation are covered by construction rather than by
   remembering to check.

Only then is a Principal constructed. Failing any step produces no Principal at
all, never a partial one.

## What is deliberately not built

**No `jti` replay store.** RFC 9449 makes single-use checking RECOMMENDED, not
required, and says in terms that it "may not always be feasible in practice,
e.g., when multiple servers behind a single endpoint have no shared state". The
proof is already bound to the method, the URL and a hash of the token, over TLS.
Revisit if the Gateway ever runs somewhere a replayed proof buys something.

**No nonce round trip.** Server-provided nonces are optional. The one rule
attached to skipping them is that a deployment without nonces "SHOULD NOT issue
long-lived DPoP constrained access tokens", and fifteen minutes is not long-lived.

**No introspection call on the paid path.** Local verification, so a hub outage
degrades to a stale revocation set rather than a credits outage.

## Two things the specification does not solve for us

**`htu` behind a proxy.** RFC 9449 says nothing about reverse proxies, and the
hosting candidate is one. The URL the Mac signed and the URL the process sees
will differ in scheme and host, and the comparison then fails with a correct
signature and a correct key, which is the worst kind of failure to debug.
Reconstruct the public URL from trusted forwarded headers, deliberately, in one
place, with a test that fails when the headers are absent rather than falling
back to the observed host.

**Enclave keys need a signed app.** Creating one requires proper code signing
and entitlements, so an unsigned test binary cannot make one. The key provider
is therefore injected, exactly as `HubPairing` injects its transport, and the
real path needs an in-app drill. A software-key test going green says nothing
about the enclave. The 2019 iMac is the only Mac that runs Sonoma without a
Secure Enclave and is therefore the whole fallback population; write that path
and test it, because a branch that only runs on machines nobody here owns has
never run.

## Revocation reaching the Gateway

Pushed by the hub when a device is revoked, and reconciled by the Gateway polling
a since-cursor. Both, not either: Clerk's own documentation says webhook delivery
is eventually consistent and must not be used in a synchronous flow, and a missed
push is otherwise silent.

This is the shape the OpenID Shared Signals Framework and its CAEP profile
standardise, and deliberately not its wire format. That machinery exists so
unrelated organisations can exchange revocation events without a shared codebase.
Both of these services are ours. Adopt real SSF the day a third party's identity
provider is involved, and not before.

## Errors

| Condition | Response |
|---|---|
| No token, bad signature, expired, wrong issuer | 401, `auth_required` |
| Wrong audience, or a missing scope | 403, `forbidden` |
| Malformed or failing proof | 401, `WWW-Authenticate: DPoP error="invalid_dpop_proof"` |
| Token bound to a different key | 401, `error="invalid_token"`, description `Invalid DPoP key binding` |
| Bound token presented as `Bearer` | 401. Never honoured. |

A revoked device is `auth_required`, not `forbidden`: the credential is gone, not
insufficient. The app distinguishes these, because per AUTHORIZATION.md an empty
balance and a service outage must not read as being signed out, and neither must
a revocation read as a permissions problem.
