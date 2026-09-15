# Preview ownership and deployment deferrals

A preview is an explicitly reserved commit and channel. The reservation survives
the requesting session. All four app mutation commands (`relaunch.sh`,
`install-dev.sh`, `install.sh`, and `switch-app.sh`) take the same deployment lock
and check the reservation before replacing or switching an app. An unmerged Dev
commit requires a reservation, even when no other preview is active.

## Reserve and run a preview

Commit the source first. From a current tooling checkout, resolve the desired
commit and reserve it for a named session or operator:

```sh
TARGET=$(git rev-parse HEAD)
export TB_DEPLOY_OWNER="session-01a0a703"
TB_PREVIEW_TOKEN=$(python3 scripts/deployment-state.py reserve \
  --owner "$TB_DEPLOY_OWNER" --sha "$TARGET" --channel dev --minutes 120) || exit
export TB_PREVIEW_TOKEN
scripts/relaunch.sh "$TARGET"
```

The same token is used by `install-dev.sh ... --activate` and `switch-app.sh dev`.
It authorizes only the reserved full SHA and channel. Keep it in the owning
session's environment; do not put it in an issue, report, or shared log.

Reservations default to two hours and can last between one minute and one day.
Expiry permits a later main deployment; it does not launch anything itself. An
expired token cannot authorize an unmerged preview. Renew before expiry if the
preview needs to stay up longer.

To renew, or hand the reservation to another named session/commit, supply the
current token to `reserve --preview-token "$TB_PREVIEW_TOKEN"` with the new owner,
SHA, channel, and duration. Save the returned token: each renewal or handoff
rotates it, so a delayed release from the old session cannot clear the new lease.
The current owner must explicitly transfer that token to the new owner.

```sh
python3 scripts/deployment-state.py status
python3 scripts/deployment-state.py release --preview-token "$TB_PREVIEW_TOKEN"
unset TB_PREVIEW_TOKEN
```

Status hides the token and shows owner, commit, channel, expiry, and pending
requests. A session crash leaves its preview reserved until explicit release or
expiry. It does not permanently retain the app mutation lock: a later command
can recover a lock whose process has exited. Never delete a live lock directory
or the state file to get around a preview.

## Deferred work and rollout boundary

A reservation denial returns exit 75 and persists the requested operation,
full SHA, channel, reason, timestamp, and `TB_DEPLOY_OWNER` as retry owner. Set
that owner on automated and supervised commands; its fallback is `manual`.
Requests for the same operation, SHA and channel are deduplicated. Release or
expiry retains the pending list for the owner to inspect and retry. This first
stage records preview deferrals; it does not claim that every recorded request
is still applicable or that a successful retry has been acknowledged.

The state is stored in `~/Library/Application Support/VoiceDispatch/deployment.json`
with private permissions and atomic replacement. Short metadata transactions
use a kernel file lock. The existing `/tmp/tb-relaunch.lock` directory remains the
long app mutation lock for compatibility with older scripts. Process and random
token must both match to release it. A fresh directory without a PID is treated
as an initializing writer, not as an abandoned lock.

This policy is effective only when every live caller uses the updated scripts.
During cutover, let any old writer finish, update the deployment checkout and
hook together, and reserve an existing unmerged preview before allowing the next
automatic deployment. Old checkouts do not know about reservations. The
supervised delivery work in issue #492 owns that cutover, persistent intent for
lock/capture deferrals, acknowledgement after runtime verification, and automatic
activation rules that respect the selected channel and intentional Quit.

The existing capture/transcription guard still runs immediately before stopping
an app. Signature, notarization, database compatibility, and channel checks are
retained. A denied reservation never starts a fallback app. Signal handlers exit
through one cleanup path; cleanup keeps ownership until restoration finishes.

## Validation

`python3 scripts/tests/test_deployment_state.py` uses temporary state, locks,
repositories, and bundles. It covers concurrent/crashed writers, expiry,
handoff, stale release, corrupted state, and token handling. It executes all four
shell entry points with tripwires for app mutations, and verifies lock ownership
survives `install-dev`'s same-process `exec` handoff. The source audit runs it on
every assigned candidate. These checks never install or launch the live app.
