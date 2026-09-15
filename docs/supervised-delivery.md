# Supervised merge delivery

Issue #492 connects merge observation to the preview policy in #491. Queue
admission, merge completion, and running software have separate evidence.

## The operator's path

After requesting a merge, keep one named supervisor on the request:

```sh
python3 scripts/delivery.py watch --pr 498 --owner session-01a0a703 --wait
```

The command does not merge or rebase PRs. It observes GitHub, retains intent,
and deploys only after GitHub returns a real merge commit reachable from main.
Without `--wait` it checks once. With it, it checks every 30 seconds until
delivery is verified or the PR is closed. Stop it with Ctrl-C; pending work
survives. There is no installed daemon or unattended retry guarantee.

```sh
python3 scripts/delivery.py status
python3 scripts/delivery.py resume --owner session-01a0a703 --wait
```

`resume` explicitly takes retry responsibility for unfinished requests. After
sleep, session loss, or a hook timeout, the next supervisor uses it. Record the
named owner in the workstream issue while the pilot is supervised.

| State | Evidence |
| --- | --- |
| `requested` | Intent and retry owner persisted before a network call. |
| `awaiting_merge` | PR is open; no queue admission was observed. |
| `queued` | GitHub auto-merge or the configured `merge-queue` label was observed. |
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

## Hook and deployment checkout cutover

The old PostToolUse merge hook invokes relaunch from a potentially stale checkout
and compares only build-checkout HEAD with main. Replace its command with:

```sh
python3 /absolute/path/to/deployment-checkout/scripts/hooks/merge-delivery.py
```

Keep its `Bash` matcher and allow 180 seconds. This new hook observes once and
records pending work; it never installs. The requesting session's `watch` or
`resume` command is the supervised installer. A delayed auto-merge therefore
requires that named supervisor or a later explicit resume.

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
