# Measure the protected product queue

The collector is read-only and hardcoded to this product repository. It never
admits a PR, updates a branch, merges, changes protection or installs an app.
Run it from a clean checkout; retain evidence outside the source tree:

```
python3 scripts/measure-merge-queue.py snapshot --evidence /absolute/path/burst.jsonl --prs 540 541 542
python3 scripts/measure-merge-queue.py report --evidence /absolute/path/burst.jsonl
```

The numbers above illustrate syntax, not an authorized cohort. Name reviewed,
ready PRs in issue 493. Start before admission and repeat snapshots during the
burst. Use a separate file for each cohort; reports reject changed cohorts so
an unfinished or slow PR cannot disappear from the final statistics.

Reports retain the **first** admission-label timestamp and subsequent requests.
The fixture's resolved conflict took 6m31s from initial admission but only 7s
after re-admission. Reporting only that last interval would hide the actual
wait. Open waits remain separate from completed durations; median/max is over
observed, admitted, completed PRs only. A small cohort does not support p95.

Timelines, branch-specific pull-request workflows and jobs are paginated.
Each snapshot records current workflow attempts; a report retains previously
observed attempts across later reruns. Attempts that finished before collection
started may be absent. Polling can miss intermediate heads. Run creation to
job start includes scheduling/setup, not just waiting for a runner, especially
for reruns. A failed workflow is not automatically wasted work: inspect logs
and base/head movement before calling it an invalidated candidate.

An API error aborts collection instead of appending an empty-queue observation.
Reports show the last observation timestamp and its age; an old snapshot is
not a fresh claim about the queue. Record readiness, published releases and
verified Dev activation separately. Delivery requests and process/source
receipts come from `delivery.py status` and the worker ledger.
