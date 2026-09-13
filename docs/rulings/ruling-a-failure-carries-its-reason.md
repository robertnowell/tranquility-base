# A failure carries its reason

Ruled 11 Sep 2026.

> "A rule going forward: a failure worth recording is recorded through
> `Failures.report` with its full reason, which now carries that reason to both
> streams."

## What was wrong

A remote user was stuck on an old build for a day. Her update checks were
failing every hour, and all we had recorded was the word "failed": no error, no
domain, no code. The reason was on her machine, in `app.log`, and nowhere we
could reach. She was undebuggable from telemetry.

She was not special. An audit found the same shape in eleven places. The
anti-pattern, everywhere:

    catch {
        Permissions.log("... \(error)")        // the reason, in app.log only
        Track.record("<event>", ["outcome": "failed"])  // a token, in PostHog
    }

The error lands in `app.log`, a token lands in PostHog, and the two are never
joined. A failure becomes a count with no recoverable cause off the user's
machine.

## The rule

A failure worth recording is recorded through `Failures.report(kind:reason:)`
with its full reason. That is the one helper that keeps the reason, and its
product mirror now carries the reason to PostHog too (scrubbed and bounded by
`.prose`), so a failure count and its cause live together in both streams.

For an event that is not itself a failure but has a failure branch (a lifecycle
event like `go_to_agent`, `agent_ended`, `hooks_state`), the failure branch
carries a `detail` on the event, again the reason, not a token.

## The one thing the reason must never be

The user's own speech. That is the only privileged content (7 Sep ruling). A
reason is the app's and the agent's own words: an error, an exit status, a
provider and its HTTP code, a disposition enum, a pane's last line. Never the
transcript, never the spoken message. `.prose` scrubs and bounds every reason
as a backstop, but the discipline is at the source: log the why, never the
words.


## Addendum, 12 Sep 2026: two more edges

Two things the first pass did not say, both learned while closing the class.

**A refusal is not a failure.** A by-design guard that declines to act (the mic
is already live, a second timer was refused, a revive was declined because the
agent is live elsewhere) is a progress note, not a failure. It stays a local
`Permissions.log` line. Elevating refusals to `Failures.report` floods the
alert stream with non-events. The test is whether something *broke*: a revive
that *failed* reports; a revive that was *refused* does not.

**A high-frequency benign error must not reach the alert stream.** Every
`Failures.report` becomes a Sentry capture and a Slack alert; there is no
severity filter. So a failure that fires often and benignly is recorded as DATA
(a `Track.record` with its reason), not through `Failures.report`. The update
check is the case that taught this: on the scheduled timer it errors on every
asleep or offline tick, hourly, on every install. That is classified `offline`
(`UpdateReadiness.isOffline`) and kept to PostHog; only a check that reached the
feed and still failed alerts. Before routing a new failure through
`Failures.report`, ask how often it fires when nothing is actually wrong.
