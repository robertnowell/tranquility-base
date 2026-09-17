# Test progress and stall recovery

`scripts/test.sh` runs XCTest and Swift Testing separately, preserving their
exit status and the discovered-inventory/coverage guards. Output now reaches
the hosted log as it is produced instead of sitting in two command substitutions.
Full logs remain in `.build/ci-diagnostics/` and both audit workflows upload
them with `always()` and seven-day retention. No release credentials enter
the source-audit job.

Each test-framework invocation has a 600-second deadline. Discovery has a
60-second deadline per framework. The healthy release 35243781312 spent
126.82 seconds in the complete test phase (16:05:49 to 16:07:56 UTC on
17 September). These conservative initial limits leave substantial headroom;
they are not estimates of a typical test duration. A test timeout exits 124
and immediately fails the gate, retaining every required coverage check.

Before timeout or a handled SIGINT/SIGTERM, the runner records only its own
process group's PID, parent, group, elapsed time, state and executable. On
macOS it also attempts bounded samples of up to two XCTest processes. It
then terminates the entire group, including children that ignore SIGTERM.
Diagnostics are best effort; SIGKILL or loss of the hosted runner cannot be
made to run an upload step. Live progress gives a second source of evidence.

Run 35058586437 stalled in the test phase and cleanup found an XCTest process.
Its buffered log does not identify the individual test. This change bounds
and exposes a recurrence; it does not establish that original root cause.

Validation: `scripts/tests/test_run_stage.py` runs actual processes to prove
live progress, preserved failures, cancellation diagnostics and cleanup of a
stalled parent and termination-resistant descendant. The existing wrapper
and audit-boundary tests still prove neither suite can silently disappear.
