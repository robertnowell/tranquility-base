# Protected merge queue pilot

The opt-in configuration in `.kodiak.toml` was exercised in the isolated
[fixture](https://github.com/robertnowell/tranquility-base-merge-pilot/blob/6547ff8/RESULTS.md).
Eight bot merges preserved strict required checks and matched their tested
file trees. This proves observed coordination behavior, not production burst
throughput. Product installation and the active cohort are recorded in
[issue 493](https://github.com/robertnowell/tranquility-base/issues/493); the
presence of this file does not itself activate an installation or admit a PR.

## Admission includes delivery intent

Use the current, clean persistent deployment checkout. Update it with
`python3 scripts/update-deployment-tooling.py`, which holds both deployment
locks. From that checkout, the named coordinator admits only a reviewed PR:

```
python3 scripts/delivery.py admit --pr NUMBER --owner SESSION --head FULL_PR_HEAD_SHA
```

This verifies the product remote and merged admission tooling, checks that the
reviewed head still names an open, non-draft PR targeting main, and refuses a
conflict, unresolved mergeability, explicit hold or competing GitHub auto-merge.
It writes durable delivery intent **before** adding `merge-queue`, and observes
the result without installing. A PR behind main can be admitted; the bot owns
its update and fresh required validation.

Exit 0 means admission or an actual merge was observed; it does not mean the
app is running. Exit 75 means admission/delivery remains unresolved: inspect
the output and `delivery.py status`. A failed label request may have reached
GitHub. Do not delete its delivery record or blindly restore/remove labels.
The stored expected head is the reviewed admission source, not a permanent
head lock: a bot update or subsequent edit still needs the required check.
GitHub's label API offers no atomic compare-and-set against the head SHA.

The installed delivery worker observes recorded requests after the requesting
session ends. A foreground supervisor can instead use:

```
python3 scripts/delivery.py watch --pr NUMBER --owner SESSION --wait
```

Do not use a bare label command as the sole admission path. It bypasses the
merge-command hook, and an unrecorded merge is not picked up by the worker.
See [supervised-delivery.md](supervised-delivery.md) for worker installation,
capture/preview/Quit/channel protection, failure holds and runtime receipts.

## Ownership and visible recovery

The current coordinator and cohort belong in issue 493. While admitted, the
PR's branch is owned by that coordinator: other sessions must not separately
rebase, update, or arm auto-merge on it. If source changes are necessary, tell
the coordinator through the normal workstream record and withdraw/review the
candidate before re-admission. Keep required protection enforced even if the
bot is unavailable. Other main merges can still invalidate a candidate; record
those events rather than treating the queue as protection against every writer.

The deployment ledger includes `queue_owner`, the reviewed head, first/last
admission-request timestamps, `queue_state` and `queue_observed_at`:

| Queue state | Operator action |
| --- | --- |
| `held` | Leave `queue-hold` in place until its owner deliberately releases it. Admission never removes it. |
| `conflict` | Resolve and review the product-code conflict. The bot removes admission on conflict. |
| `awaiting_readmission` | A previously admitted conflict is no longer reported but admission is absent. Verify the resolution and fresh validation, then re-admit explicitly. |
| `admission_removed` | Admission was seen/requested and is now absent. Inspect why; do not automatically re-add it. |
| `queued` | Admission is observed; this alone proves neither bot acceptance nor passing CI. Inspect required checks. |
| `not_admitted` | No current admission was observed. |

`last_error` plus an old observation timestamp means the remote state is
unavailable/stale, not an empty queue. `queue_admission_error` records an
uncertain mutation until a label or merge is observed. Initial request time
survives re-admission; do not hide conflict/recovery waits by using only the
last attempt. GitHub label events are the actual label-time evidence.

## Cutover, measurement and rollback

Before adding the product to the existing selected-repository installation:

1. Land this configuration and admission path through normal required checks.
   Update the stable tooling; verify the worker heartbeat and existing preview.
2. Retain the exact main-protection snapshot. It must still require strict
   `Source audit` from Actions app 15368, include administrators, require linear
   history/conversation resolution and prohibit force pushes/deletions. Keep
   the existing settings; the queue does not replace their enforcement.
3. Select only the intended product repository in addition to the fixture.
   Verify the resulting access scope. No repository transfer is needed for
   this serial pilot. Create the `merge-queue` and `queue-hold` labels if absent.
4. Name three to six genuinely ready, reviewed PRs. Old open PRs are not an
   automatic cohort. Exercise admission through bot merge, session loss,
   safe activation deferral and the worker's cumulative running receipt.

Capture readiness/admission-to-merge waiting, candidate head/base, workflow
attempt/job timings, actual merge and invalidated work. Measure publication and
verified Dev activation separately. Report observed median/max for a small
burst; do not claim a stable p95 from three samples. The provisional 20-minute
p95 target is an operating goal, not a guarantee or industry standard.

If serial checks dominate, evaluate concurrent cumulative candidates with
measured macOS runner capacity, including Intel and release jobs. The serial
fixture does not establish that ten simultaneous ready PRs will merge quickly.
The fast local preview path remains independent of merge/publication.

For rollback, stop new admissions, remove admission from open queued PRs, and
suspend product access if necessary. Recheck any candidate already merging:
removing a label is not an atomic cancellation of an in-flight merge. Preserve
all required checks, durable delivery requests and the guarded worker. Never
restore an older unguarded installer as queue rollback.
