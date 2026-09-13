# The provider seam

Ruled 13 Sep 2026, before any provider code existed.

> "Every one of these rules is cheap now and expensive later."

Ten rules for the seam that cloud agent providers plug into. Sourced from LSP
3.17, the Debug Adapter Protocol, Kubernetes CRI and dockershim, OpenTelemetry,
and Paseo's own `docs/protocol-compatibility.md`. Full research record:
`~/Documents/agents/bee124ae-b85d-48bf-b689-651c1c7d2e19/2026-09-13-durable-agent-supervision/report.md`.

Two of them are enforced mechanically, and which two is stated at the bottom.

## 1. Capabilities, never a version number

LSP and DAP both deliberately have no protocol version gating behaviour. LSP:
"Servers receiving a `ClientCapabilities` object literal with unknown properties
should ignore these properties", "A missing property should be interpreted as an
absence of the capability", and "the using side of an enumeration shouldn't fail
on an enumeration value it doesn't know."

So: **missing means absent, unknown means ignore.** An `AgentSessionState` this
app has never heard of decodes to `.unknown` and the row survives. There is no
provider protocol version and there will not be one.

## 2. Additive only

Paseo: "New fields are `.optional()` with a sensible default. Never flip
optional to required, remove a field, or narrow a type."

## 3. Every compatibility shim carries a dated removal comment

Paseo's form, adopted verbatim:

    // COMPAT(name): added in vX, remove after DATE

Their docs call grepping for `COMPAT(` "the full cleanup backlog". It is the
only debt-tracking system in the whole research that visibly worked, and it
works because the date is machine-readable and therefore expires on its own.

**Enforced.** See the bottom of this file.

## 4. No fallback paths

Paseo: "Don't build a degraded version of the feature for old daemons... The
user updates or doesn't get the feature."

A provider either declares a capability or the feature is absent there. A
degraded path is a second implementation that nobody exercises, which this
codebase has already paid for once: the signing fallback that only ran on
machines we do not own had never run, and was broken.

## 5. Every declared capability must be read by production code

`HarnessCapabilities.allowsConcurrentResume` carries forty lines of careful
measurement and its documentation ends: "Nothing in Sources/ reads it today."
That is how a seam rots into a formality. A declared capability nothing reads is
worse than no capability, because it reads as a guarantee.

Note that `AgentProvider.changes()` returning nil **is** the poll-or-push
capability declaration, rather than a separate flag beside it. A capability
expressed as the absence of a return value cannot go stale, because production
code has to branch on it to function at all. Prefer that shape wherever it fits.

**Enforced.** See the bottom of this file.

## 6. One namespaced escape hatch per provider, with defined ignore semantics

LSP reserves the `$/` prefix — an unknown notification is ignored, an unknown
request returns MethodNotFound rather than failing — plus `experimental?:
LSPAny`. It has a real promotion path: rust-analyzer shipped
`experimental/inlayHints` for years before LSP 3.17 standardised
`textDocument/inlayHint`.

## 7. Runtime truth beats the manifest

Paseo discovers models and modes from the live agent process; static catalog
entries are "used for UI scaffolding... but the runtime values from the agent
process are the source of truth."

This app already holds the same rule in another vocabulary: the process outranks
the transcript (18 Aug). Same rule, different witness.

## 8. Vendor drift is a scheduled chore, not an incident

Paseo runs `acp:version-drift:check` every release. Cursor changed its local
credential storage format at least twice and broke them both times (`2c5c629db8`,
`2347242cdf`).

## 9. The rot metric is adoption lag, not lines of code

Kubernetes' dockershim signal was that new runtime capabilities (cgroups v2,
user namespaces) became "largely incompatible with the dockershim". The shim was
blocking adoption, and that is what forced removal. Count what a seam stops you
from adding, not how big it is.

## 10. Delete the special case on a telegraphed clock

Dockershim: deprecated v1.20 (Dec 2020), removed v1.24 (Apr 2022) — about
eighteen months, with a third-party landing pad.

**The special case here is the 47 harness identity comparisons across 19 files
(#382), not the terminal path itself**, which is load-bearing for supervising
sessions the user started by hand.

## What is enforced, and how

| Rule | Mechanism | Where |
|---|---|---|
| 3 | `scripts/check-compat-comments.sh` — every `COMPAT(` must name itself and carry a parseable removal date, and a date in the past fails the build | `scripts/preflight.sh`, beside the other source checks |
| 5 | `CapabilityLivenessTests` — a declared capability no production file reads fails the suite | `Tests/TranquilityCoreTests` |

Rule 5's check carries a debt list that may only SHRINK: a listed field that
becomes live fails the suite too, so the list cannot quietly describe a past
that is no longer true. It was written expecting one entry, for the field whose
documentation confesses to being unread. **It found four.** `echoesPaste`,
`queuesInputMidTurn` and `hasHooks` are measured facts about a harness that no
production code consults, and the last of those is the one most likely to be a
genuine bug rather than dead weight: a harness without hooks would still get a
hooks row today, because `HookManifest` answers that question by another route.
All three carry a 2026-12-01 date.

Rule 3 is a grep because it is about comment text. Rule 5 is a test because it
is about whether code reads a field, which grep cannot answer without reading
Swift. Neither is a convention anyone has to remember.

At the time of writing, `COMPAT(` appeared **zero** times in the tree, so the
check is strict from its first commit rather than grandfathering a backlog.
