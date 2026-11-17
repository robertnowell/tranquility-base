# Ruling: no date fails the build

**Ruled by Robert, 16 Nov 2026.** His words: "no kicking can down the road,
there should be no date dependence in our ci / cd that will deterministically
expire at some point."

## The rule

Nothing in the delivery path may pass or fail because a date arrived. The
delivery path is `scripts/preflight.sh`, `scripts/audit-source.sh`, every
script and test they run, and every workflow under `.github/workflows`.

The verdict on a commit depends on the commit. The same commit gets the same
verdict on any day.

A duration is not a date. A timeout, a reservation that lasts 120 minutes and
a test that waits for a deadline all measure time from when they start. They
stay.

## The measurement

This reverses part of rule 3 of `ruling-the-provider-seam.md` (13 Sep 2026),
which said a `COMPAT` marker whose date had passed fails the build.

- `Tests/TranquilityCoreTests/CapabilityLivenessTests.swift` carried
  `COMPAT(pendingCapabilities): ... remove after 2026-11-15`.
- On 16 Nov 2026 the source audit failed on main's own head, `b1fdf000`,
  which had passed the same audit when it merged.
- Pull request 795 changed two files under `docs/`. Its source audit failed
  with `COMPAT(pendingCapabilities) expired 2026-11-15`.
- Every open pull request was blocked the same way. At least two sessions
  reported it in the hub that day.
- Three more markers carried 2026-12-01. They would have stopped main again
  15 days later.

The date did not make anybody do the work. The three fields it guarded were
still unread when it passed. It stopped whoever tried to merge next, and that
session did not own the fields.

## What replaces the date

An event in the tree, watched by a test.

- `CapabilityLivenessTests` already does this for all five markers. A listed
  field that production code starts to read fails the suite until its entry
  is deleted. A new field that nothing reads fails the suite too.
- `scripts/check-compat-comments.sh` still refuses a marker with no name or
  with no reason. It prints every marker on every run. It never reads the
  clock, and `scripts/tests/test_compat_comments.py` holds it to that.
- Debt that needs a person is a GitHub issue. A date in a comment was a
  reminder that fired at the wrong session.

## The repair this ruling does not make

`canCancel`, `listIsCallerScoped` and `carriesPullRequest` are still declared
by four providers and read by no production file. The work that was to read
them (issues 368, 371 and 374) closed without reading them. That is real debt.
The choice is to read each field or to delete it, and the provider work owns
that choice.

## How to apply

- Do not write a check that compares today with a date in the tree.
- A new shim gets `COMPAT(name): what ends it`, and a test for that event
  where one is possible.
- A check that must age something out measures a duration from a recorded
  start, and it reports. It does not fail a merge.
