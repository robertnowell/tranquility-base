# Contributing

Tranquility Base is built primarily through Claude Code sessions working
directly in this repo — `CLAUDE.md`, at the repo root, is the operating
protocol those sessions follow: worktree discipline, deploy verification,
multi-session collision rules. It's written entirely as instructions to an
agent, not to you, so don't expect it to read like a contributor guide.

This one is for a human sending a PR.

## The short version

1. Fork, branch, make your change.
2. `swift build && swift test` (see the note on `swift test` below — this
   toolchain has a real gotcha).
3. Open a PR against `main`.

Nothing else is required. There's no CLA, no mandatory issue template.

## The one toolchain gotcha worth knowing

On some machines, a bare `swift test` silently runs only the Swift Testing
suites and skips every XCTest-based test — no error, no non-zero exit, just a
much smaller number than you'd expect. If your test count looks low, run:

```sh
arch -arm64e swift test --enable-xctest --disable-swift-testing
arch -arm64e swift test --disable-xctest --enable-swift-testing
```

## Testing the Intel slice

The app ships universal (arm64 + x86_64). To run the suite against the Intel
slice on an Apple Silicon Mac:

```sh
arch -x86_64 swift test --arch x86_64 --enable-xctest --disable-swift-testing
```

**Both halves are required.** `arch -x86_64` alone still builds arm64 and then
fails to load its own bundle ("doesn't contain a version for the current
architecture"); the flag picks the slice and the translated shell supplies an
x86_64 `xctest` to load it. 1285 tests, 0 failures as of 02 Sep 2026.

This is Rosetta, so it is evidence about **correctness and not about timing**.
It runs on Apple Silicon, and in a published real-time-audio benchmark Rosetta
beat native Intel outright, so a green run here says nothing about whether an
Intel Mac keeps up. CI compiles the core natively on Intel
(`macos-15-intel`) but cannot run the suite there, because that runner's SDK
is too old to build `Sources/TranquilityApp` and `swift test` builds every
target. See the comment on that job.

Beware that `swift build --arch ...` routes through XCBuild rather than
SwiftPM's own build system and plans a different, smaller target graph. A
result from one is not a result about the other.

`scripts/preflight.sh` runs both automatically before it'll tell you a branch
is safe to land — worth running yourself before opening a PR.

## Where things live

- `docs/` is design rationale and build history, not a user guide — see
  `docs/README.md` for what's where. If you're trying to understand what the
  app does or how to run it, that's this file and the root `README.md`, not
  `docs/`.
- `Sources/TranquilityCore` is the testable half (pure logic, no AppKit).
  `Sources/TranquilityApp` is the panel itself — it has no unit tests, by
  design (see `docs/README.md`); if you're touching it, build and run the app
  to check your change.

## Questions

Open an issue. If it touches something `docs/rulings/` or `docs/log/` already
has an answer for, a session (or a human) will point you at it.
