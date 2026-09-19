#!/usr/bin/env python3
"""Read-only product queue evidence. Never changes labels, branches, protection or deployments."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import statistics
import subprocess
from urllib.parse import urlencode

REPO = "robertnowell/tranquility-base"


def gh(*args):
    return json.loads(subprocess.check_output(["gh", *args], text=True, timeout=45))


def seconds(start, end):
    return (datetime.fromisoformat(end.replace("Z", "+00:00")) -
            datetime.fromisoformat(start.replace("Z", "+00:00"))).total_seconds()


def pages(path, key=None):
    data = gh("api", path, "--paginate", "--slurp")
    return [item for page in data for item in (page[key] if key else page)]


def collect(prs):
    result = {"checked_at": datetime.now(timezone.utc).isoformat(), "repo": REPO, "prs": [], "runs": []}
    for number in prs:
        pr = gh("pr", "view", str(number), "--repo", REPO, "--json",
                "number,state,headRefOid,headRefName,mergeCommit,mergedAt,mergeStateStatus,labels,statusCheckRollup")
        events = pages(f"repos/{REPO}/issues/{number}/timeline?per_page=100")
        pr["timeline"] = [{key: e.get(key) for key in ("event", "created_at", "commit_id", "label")}
                          for e in events if e.get("event") in ("labeled", "unlabeled", "committed", "merged")]
        result["prs"].append(pr)
    runs = {}
    for branch in {p["headRefName"] for p in result["prs"]}:
        query = urlencode({"branch": branch, "event": "pull_request", "per_page": 100})
        for run in pages(f"repos/{REPO}/actions/runs?{query}", "workflow_runs"):
            runs[run["id"]] = run
    for run in runs.values():
        jobs = pages(f"repos/{REPO}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs?per_page=100", "jobs")
        result["runs"].append({**{k: run.get(k) for k in ("id", "run_attempt", "head_sha", "head_branch",
                                     "created_at", "run_started_at", "updated_at", "status", "conclusion")},
                               "jobs": [{k: j.get(k) for k in ("id", "name", "status", "conclusion", "started_at", "completed_at")}
                                        for j in jobs]})
    return result


def report(samples):
    if not samples:
        raise ValueError("no observations recorded")
    latest = samples[-1]
    cohort = {p["number"] for p in latest["prs"]}
    if any(s["repo"] != REPO or {p["number"] for p in s["prs"]} != cohort for s in samples):
        raise ValueError("repository/cohort changed; use a separate evidence file")
    now = datetime.now(timezone.utc).isoformat()
    rows = []
    for pr in latest["prs"]:
        admitted = [e["created_at"] for e in pr["timeline"]
                    if e["event"] == "labeled" and (e.get("label") or {}).get("name") == "merge-queue"]
        changed_heads = list(dict.fromkeys(p["headRefOid"] for sample in samples for p in sample["prs"]
                                          if p["number"] == pr["number"]))
        rows.append({"pr": pr["number"], "state": pr["state"], "queue_request_at": admitted[0] if admitted else None,
                     "last_queue_request_at": admitted[-1] if admitted else None,
                     "admission_requests": len(admitted),
                     "merged_at": pr["mergedAt"], "observed_heads": changed_heads,
                     "request_to_merge_seconds": seconds(admitted[0], pr["mergedAt"])
                     if admitted and pr["mergedAt"] else None,
                     "open_wait_seconds": seconds(admitted[0], now) if admitted and pr["state"] == "OPEN" else None})
    durations = [r["request_to_merge_seconds"] for r in rows if r["request_to_merge_seconds"] is not None]
    jobs = []
    # Preserve observed attempts even if the latest snapshot contains a rerun.
    attempts = {(r["id"], r["run_attempt"]): r for sample in samples for r in sample["runs"]}
    for run in attempts.values():
        for job in run["jobs"]:
            jobs.append({"run": run["id"], "attempt": run["run_attempt"], "sha": run["head_sha"],
                         "name": job["name"], "conclusion": job["conclusion"],
                         "run_created_to_job_start_seconds": seconds(run["created_at"], job["started_at"])
                         if job["started_at"] else None,
                         "execution_seconds": seconds(job["started_at"], job["completed_at"])
                         if job["started_at"] and job["completed_at"] else None})
    return {"checked_at": latest["checked_at"], "observation_age_seconds": seconds(latest["checked_at"], now),
            "prs": rows, "jobs": jobs, "merged_samples": len(durations),
            "request_to_merge_median_seconds": statistics.median(durations) if durations else None,
            "request_to_merge_max_seconds": max(durations) if durations else None,
            "limits": ["Label time is an opt-in request, not evidence of bot acceptance.",
                       "Run creation to job start includes scheduling and setup; it is not a pure runner-capacity measure.",
                       "A small cohort does not establish a stable p95; open waits are not completed durations.",
                       "Only observed workflow attempts are retained; failures are not automatically classified as wasted CI.",
                       "Readiness, publication and verified activation require their own evidence.",
                       "Polling can miss intermediate heads; raw run identities and timelines remain evidence."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["snapshot", "report"])
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--prs", nargs="+", type=int)
    args = parser.parse_args()
    if args.operation == "snapshot":
        if not args.prs or any(pr < 1 for pr in args.prs) or len(set(args.prs)) != len(args.prs):
            parser.error("snapshot requires distinct positive --prs")
        sample = collect(args.prs)
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        with args.evidence.open("a") as out: out.write(json.dumps(sample) + "\n")
        print(json.dumps({"checked_at": sample["checked_at"], "prs": len(sample["prs"]), "runs": len(sample["runs"])}))
    else:
        samples = [json.loads(line) for line in args.evidence.read_text().splitlines() if line.strip()]
        print(json.dumps(report(samples), indent=2))
