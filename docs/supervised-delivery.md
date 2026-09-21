# Supervised merge delivery

Issue #492 connects merge observation to the preview policy in #491. Queue
admission, merge completion, and running software have separate evidence.

## The operator's path

For every new authorized shipment, use `delivery.py admit --pr NUMBER --owner
SESSION --head FULL_PR_HEAD_SHA` before any label-only admission. It persists
delivery intent before requesting the queue. See [merge-queue.md](merge-queue.md)
for cutover, coordinator ownership, explicit holds and conflict re-admission.

After requesting a merge, keep one named supervisor on the request:

```sh
python3 scripts/delivery.py watch --pr 498 --owner session-01a0a703 --wait
```

The command does not merge or rebase PRs. It observes GitHub, retains intent,
and deploys only after GitHub returns a real merge commit reachable from main.
Without `--wait` it checks once. With it, it checks every 30 seconds until
delivery is verified, the PR is closed, or activation fails. A failed activation
returns nonzero instead of repeatedly reinstalling that source. Stop with Ctrl-C;
pending work survives. An optional installed worker can take responsibility after
the foreground session ends; see below.

```sh
python3 scripts/delivery.py status
python3 scripts/delivery.py resume --owner session-01a0a703 --wait
```

`resume` explicitly takes retry responsibility for unfinished requests. After
sleep, session loss, or a hook timeout, the next supervisor uses it. Record the
named owner in the workstream issue.

## Durable delivery worker

After merging the tooling, update the clean persistent `deployment-main`
checkout and run its `scripts/install-delivery-supervisor.py`. It installs
`dev.tranquilitybase.delivery-supervisor`, a per-user launch agent that invokes
`delivery.py supervise` every 30 seconds and at login. Stop it with the same
installer's `--stop` option. Installation refuses an unmerged/stale driver or a
temporary feature checkout. Credentials stay in the existing GitHub CLI store.

The worker processes only recorded requests in `delivery.json`. It does not
replay `deployment.json`'s old refused preview/switch operations and does not
automatically admit arbitrary open PRs. Each tick observes eligible PRs, chooses
current main containing their merges and starts at most one install. A successful
receipt also completes the other observed requests whose merges it contains.
Newer main movement during that install is handled by a later request/tick.

The same installer retains capture, preview, signing, channel, intentional Quit
and launch-drill checks. Preview expiry only permits the next attempt; it is not
a deadline by which a build must be running. Sleep delays the worker until wake.
Build preparation now owns a separate workspace lock and produces a leased
artifact before app ownership. See `prepared-dev-builds.md` for activation
checks and the bounded informational diagnostic after the runtime receipt.

A failed source is held across ticks/restarts, including other requests for that
same source. A newer main can be attempted; an operator can explicitly retry via
`watch`/`resume` after inspecting the failure. Two interrupted activation attempts
also hold that source. Safe deferrals do not consume that recovery budget. A
singleton lock prevents overlapping workers, and the existing per-PR/app locks
still arbitrate foreground operators and other installers.

`delivery-supervisor.json` stores the last tick's phase, timestamp, target and
reason beside private logs. A timestamp is a heartbeat, not proof of a running
app; only the process/source receipt proves delivery. Missing/stale heartbeat or
`unavailable` means the worker needs attention. Disable the launch agent for
rollback; keep durable requests and the guarded foreground commands.

| State | Evidence |
| --- | --- |
| `requested` | Intent and retry owner persisted before a network call. |
| `awaiting_merge` | PR is open; no queue admission was observed. |
| `queued` | The configured `merge-queue` label was observed without an active competing merge mechanism, hold or conflict. |
| `merged` | GitHub returned the actual squash merge SHA and merge time. |
| `deployment_pending` | Main contains that merge; a full target is retained for activation. |
| `failed` | Deployment exited unsuccessfully or lacked verified runtime evidence. |
| `running` | A receipt records the full SHA, bundle path, process ID/start time and passing launch drills. |
| `closed` | GitHub says the PR closed without merging. |

Each status carries timestamps. A `running` receipt is historical evidence;
`status` also checks `currently_running`, so a later Quit or process replacement
does not look like a fresh live verification.

The delivery target is main as resolved at that attempt. A delayed request can
be coalesced into a newer main containing its actual merge SHA. Both identities
are retained. The target is pinned through building and bundle verification;
moving main during the build cannot change that attempt's source.

Once a verified running main build contains a requested merge, that request is
complete even if main advances again. Resuming it reuses the still-running
receipt and records that build as its delivered target. A receipt from an
unmerged preview, or from a build that does not contain the requested merge,
cannot satisfy main delivery. Newer PRs retain their own delivery requests.

## What can defer a deployment

An active preview, a busy deployment lock, a capture/transcription still in
flight, stale deployment tooling, selected Prod, or a stopped app leaves intent
for the supervisor. Automatic delivery does not undo Quit; a stopped process is
treated conservatively even if it stopped because of a crash. Start the desired
Dev lane explicitly before retrying. Changing lanes remains an explicit user or
operator action, guarded by preview ownership.

The activation policy is checked at entry and immediately before replacement,
including after the capture wait. Existing capture, signing, notarization and
schema guards remain in effect. A failed attempt does not clear pending work.
A receipt requires exactly one product process, a process start at this launch,
the expected bundle's full `TBSourceCommit`, and successful launch drills.

State is in `~/Library/Application Support/VoiceDispatch/delivery.json`; each
request has a private log beside it. A per-PR lock prevents competing supervised
attempts, while all PRs and installers share the app mutation lock. Interrupted
attempts retain their intent. Timeouts stop the install process group instead
of leaving a build child to race the next attempt.
Recovery checks the whole supervised process group even if its original shell
has died. A stale legacy/manual lock with unknown children requires operator
inspection before release; absence of the shell alone is not sufficient.

## Hook and deployment checkout cutover

The old PostToolUse merge hook invokes relaunch from a potentially stale checkout
and compares only build-checkout HEAD with main. Replace its command with:

```sh
python3 /absolute/path/to/deployment-checkout/scripts/hooks/merge-delivery.py
```

Keep its `Bash` matcher and allow 180 seconds. This new hook observes once and
records pending work; it never installs. The requesting session's `watch`,
`resume`, or the installed worker uses the supervised installer. A delayed
auto-merge requires one of these active supervisors.

Perform the cutover under the shared app mutation lock, after this tooling is
merged and required CI has passed:

1. Let any old writer finish. Verify the deployment checkout is clean and that
   its origin is this repository. Resolve current main to a full SHA.
2. Save the current hook setting for rollback. Update the deployment checkout
   to that SHA and replace only the old merge-hook command. Preserve all other
   hooks and settings. Keep the observer and supervisor on this same checkout.
3. Identify the currently running bundle and source commit. Reserve any existing
   unmerged preview before releasing the lock. Do not relaunch just to activate
   a tooling-only change.
4. Exercise the hook in observation mode, inspect durable state, and attempt a
   supervised delivery only when its preview/channel/Quit guards permit it.
   Verify the actual process and receipt before marking the issue complete.

Old worktrees do not become reservation-aware automatically. All app mutation
commands must use the updated deployment checkout. Never route around a denied
preview by invoking an older installer. If rollback is needed, disable the new
hook and retain explicit supervised operations and state; restoring the old
automatic relaunch hook would restore its preview-clobbering behavior.

The hook recognizes literal PR numbers/URLs, scopes bare numbers to the event's
repository, and handles the current branch when no target is supplied. It never
evaluates shell expressions. Dynamic/ambiguous merge commands need the explicit
`watch --pr NUMBER` invocation; the hook prints that recovery instruction.

## Tests

`scripts/tests/test_delivery.py` verifies queued versus merged evidence, squash
identity and ancestry, durable interrupted intent, idempotent runtime receipts,
stale helpers, process reuse, wrong bundles, capture rechecks and hook parsing.
The preview entrypoint tests additionally exercise automatic Quit/Prod deferral.
These tests use temporary state and fixture processes; no live app is installed.

## Prepared builds

See [prepared-dev-builds.md](prepared-dev-builds.md) for separate build ownership,
leased artifacts, activation rechecks and bounded archive diagnostics. Use
`python3 scripts/update-deployment-tooling.py` to update the stable checkout
under both locks. A preview can defer activation while a merged build is
prepared and retained for its later handoff.

## Owned admission and recovery (#554)

`admit` is the supported merge-request entry point. `watch` remains an observer
and installer after merge; it never converts arbitrary native auto-merge into
queue admission. To hand off a previously authorized native request, use:

```
python3 scripts/delivery.py admit --pr NUMBER --owner SESSION --head FULL_REVIEWED_SHA --handoff-auto-merge
```

Authorization is persisted before disabling native auto-merge. The head, open
state, main target and holds are re-read before adding admission. The worker
resumes only this recorded authorization after a session exit or timeout. It
never restores native auto-merge. A changed head, conflict or hold requires
explicit review. If adding the label times out, the worker can recognize a
label that is present, but will not blindly re-add an absent/withdrawn label.

`merge_mode` distinguishes `none`, `github_auto_merge`, `kodiak`, and
`competing`. `queue_state` distinguishes `native_auto_merge`, `queued`,
`handoff_blocked`, holds/conflicts/removal, and unavailable observations.
`queue_action`, the stable `request_owner`/`queue_owner`, and
`queue_observed_at` explain the next action and freshness. Failed remote reads
retain the last evidence and explicitly mark it unavailable. Status reads
older than five minutes are marked stale.

An open, non-draft native-auto-merge PR that is behind main, outside the queue,
and has a successful Source audit becomes `queue_attention` after five minutes
from the later observed audit completion/auto-merge request (or from first
observation when timestamps are missing). This is a diagnostic threshold, not
a merge guarantee. Missing/failed/pending checks are not counted as passing.
An edited head resets the observation. Holds and conflicts remain separate.
The 30-second worker reports `awaiting_merge` or `attention`, not idle, for
these recorded pending requests; sleep/network outages can delay observation.

The optional shell PreToolUse guard is the same hook with `--guard`. Install
it on the Bash matcher from the current merged deployment checkout. It rejects
literal `gh pr merge` product-repository submissions with an actionable admit
command; it allows `--disable-auto` for handoff and leaves other repos alone.
This guards the supported shell path, not every possible API client. Fresh
GitHub observations still expose alternate paths. PostToolUse stays observation
only. Keep all unrelated hooks intact and never install a feature-branch hook.
