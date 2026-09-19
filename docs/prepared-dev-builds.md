# Prepare a build, then activate it

`scripts/relaunch.sh` delegates preparation to `prepare-dev.py`. Preparation
owns a separate advisory build lock, builds committed source in the existing
clean incremental workspace, and copies the app, CLI and matching verification
scripts into a source-stamped artifact. The current app stays usable. No app
mutation lock is held during fetch, compilation or artifact preparation.

An artifact key contains source SHA, debug configuration, requested
architectures, signing inputs, Swift toolchain and SDK build. The manifest
records actual architecture and checksums of the verification tools. App
signature, source/channel and tool checksums are revalidated before activation.
Repeated safe deferrals reuse the artifact instead of recompiling it. Swift's
incremental workspace remains reusable across source changes.

The activation holds a shared artifact lease; a later build cannot replace
the bundle or checks it is using. Cleanup considers only artifacts untouched
for a day, obtains their exclusive lease, and preserves any artifact whose
bundle is currently running. An interrupted build can leave a partial cache
directory; it is not eligible for activation.

Once preparation finishes, activation refreshes main, waits for voice input
outside the app lock, then acquires the existing app-mutation lock. Automatic
delivery defers if its main target was superseded, Prod is selected, or the app
was deliberately stopped. Preview ownership is checked under the lock and
again immediately before stopping. If new voice input starts after the early
wait, the stop guard defers immediately instead of occupying the lock for two
minutes. Signing identity, self-tests, CLI canary and full runtime receipt remain.

The informational archive diagnostic runs after successful activation in a
separate process with a 30-second bound and a pinned CLI. Its log is in
`~/Library/Logs/TranquilityBase/delivery-health/`. It cannot hold the app lock
or delay the verified receipt. A diagnostic timeout is recorded as a failure
in that health log; it is not a passing archive check.

Update the stable checkout with `python3 scripts/update-deployment-tooling.py`.
It accepts only merged origin/main in the designated deployment checkout and
holds both build and app-mutation locks. Do not switch that checkout while a
builder or activator is using its scripts.

Acceptance drills exercise an app lock acquired during a paused build,
exclusive build ownership, artifact reuse and isolation, lease-safe cleanup,
wrong-source/tool rejection, preview protection and main advancing before
activation. Measure preparation, app-launch time and verified-receipt time
separately; the cache and lock split alone do not establish a latency promise.
