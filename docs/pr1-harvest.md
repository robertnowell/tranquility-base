# PR #1 harvest record

**Provenance:** PR #1 "Transcription keeps every utterance; permissions survive
rebuilds; sessions are named the way the terminal names them", opened 2026-08-04
from `robertnowell-coframe:permissions-and-background-agents`, head `a05f253`,
closed 2026-08-06 unmerged — main had moved 52 commits past its base, through the
stage arbiter and the render() collapse, so the diff was unmergeable history.

**Disposition of its six fixes:**

| Fix | Outcome |
|---|---|
| 1. Apple Speech isFinal truncation | **Ported** — commit `27f2fa3`, with unit tests the PR lacked |
| 2. Ad-hoc signing kills TCC grants | **Filed** — open-issues #12 (scripts port) |
| 3. Gestures: Accessibility OR Input Monitoring | **Filed** — open-issues #11 |
| 4. Background agents not repliable / clipboard on refusal | Clipboard: superseded on main. `kind` discriminator: folded into open-issues #1 as the lead |
| 5. Reply destroys its own reply target | Superseded — main advances the heard-cursor at dispatch and sets activeConversation at announcement |
| 6. Session naming via the terminal's own title | Superseded — `TranscriptTitles.swift`, one-displayed-identity ruling |

The full PR body follows verbatim — the cdhash/TCC analysis in §2 and the
recogniser measurement in §1 are reference-grade and the reason this file exists.

---

Six fixes from one session. Each made the app look broken in a way nothing on screen explained.

## 1. A 22-second paragraph transcribed as one clause

Measured before diagnosing: per-second RMS across the offending file is 2500–6000 for all 22.6 seconds with no silence gaps. The recording was complete. The transcript was 40 characters.

`SFSpeechRecognizer` splits audio at pauses and emits one settled result per utterance, each with its own timeline, and marks **only the last one** `isFinal`. The code was `guard result.isFinal else { return }`:

```
callback isFinal=false segments=29 span=0.87–18.81s chars=155
callback isFinal=true  segments=6  span=20.43–22.53s chars=40
```

Nineteen seconds discarded to keep two. It looked intermittent because it depended entirely on whether you paused — 16 seconds without a break is one utterance and survives intact.

Settled callbacks are now accumulated by segment start time and joined in spoken order. Across the 23 stored recordings: everything under ~10s unchanged to within a character, six longer ones recover **1.4×–5.1×**. Live in the app since: one dictation logged `8 utterance(s), 1945 chars`, where the old code would have kept only the last.

Only affects `apple-speech`; Whisper receives the whole file in one request.

## 2. Ad-hoc signing made permissions unfixable

An ad-hoc signature carries no certificate, so the designated requirement is `cdhash H"…"` — the hash of that exact binary. TCC keys grants to the requirement, so **every rebuild became an application macOS had never seen, and every grant silently died.**

The symptom is near-undiagnosable: the Privacy pane keeps listing the app with its switch ON while `AXIsProcessTrusted()` returns false. The pane describes a stored row; the API describes *this* binary. Toggling the switch doesn't help; neither does removing the row.

`scripts/make-signing-identity.sh` creates a stable local certificate — no Xcode, no system trust changes. `bundle.sh` now **creates** it rather than warning and shipping ad-hoc, because nobody reads a warning and infers their permissions are about to become unrepairable. `scripts/reset-permissions.sh` recovers when an identity does change.

Verified: designated requirement byte-identical across repeated rebuilds; all four permissions survived deliberate rebuilds that had wiped them twice.

## 3. Onboarding demanded the one permission you cannot grant

A listen-only `CGEvent` tap is authorised by Accessibility **or** Input Monitoring. This required Input Monitoring and called Accessibility optional. On a real Mac nothing requests Input Monitoring — that pane sits empty while Wispr Flow, Raycast and every comparable tool appear under Accessibility. `Permissions.gesturesGranted` now accepts either; granting Accessibility also flips `CGPreflightListenEventAccess()` true, so it is a strict superset.

## 4. Background agents no longer pretend to be repliable

`kind: "background"` sessions are hosted by `claude --bg-pty-host`, which owns the pty master: a pty but no controlling terminal and no tab, so nothing to type into and no supported IPC to reach it (`TIOCSTI` is `EPERM` on macOS 26, `ClaudeCode.app` has no scripting dictionary, `claude agents` has no send verb). Those announcements omit the Reply button and say why.

`kind` is also the discriminator the `tty` column could never be — exact correlation across 11 live sessions, first-party, available at selection time. Note the `tty` column now records `??` for *every* session, so a filter keyed on it would drop real turns rather than merely being inert.

**Refused replies reach the clipboard.** "Your words are kept" meant kept in sqlite — true, and useless while standing there having just spoken a paragraph. Excludes cancellations and `verificationTimedOut`.

## 5. Replying destroyed its own reply target

Observed: a reply dispatched at 21:51:28, the panel showing "→ clipboard" twelve seconds later. `mostRecentlyHeard` requires `heardThrough = latestId`, and a reply lands as a UserPromptSubmit that advances `latestId` — so the session you are mid-conversation with stops being addressable the moment you speak to it. And successful delivery never set `activeConversation`, so the stickiness the design intends only ever came from hearing a summary, never from answering one.

A delivered reply now keeps its session active until ⌃⌥ or Dismiss, guarded on a new `conversationGeneration` so a late send receipt cannot drag you back into a conversation you left. Deliberately unbounded: ⌃⌥ being the only thing that changes destination is what makes it predictable.

## 6. One session, three names, none of them matching

```
panel                   share-as-page
identity line           skills/share-as-page
claude agents --json    robertnowell-56  (cwd /Users/robertnowell)
Terminal tab            Analyze Quill AI visibility and retrieval mechanisms
```

The panel's name was the tail of the hook's `cwd` — which was `.claude/skills/share-as-page`, the directory of a *skill* that happened to be running when the Stop hook fired. Sessions were being named after transient working directories.

Now: title from Claude Code's own `ai-title` (the string the tab shows), project name from `claude agents --json`, identity line from the **live** cwd. Each falls back to prior behaviour when a transcript or live record is missing.

This also fixes the duplication where "client-report" was both the title and the first word spoken: `SessionBrief.spoken` always opens with `"\(topic)."` and topic falls back to the project label, so the panel read the folder name twice.

## Observability

`AppleSpeechRecovery.trace` logs utterance counts, spans and text — and is now wired into the app, not just `vdctl`. Without it the recogniser was the one unobservable stage, which is how a bug that kept only the last utterance of every paused recording survived. `app.log` therefore contains what you dictated; README says so plainly, in the same spirit as the existing `model-calls.jsonl` warning. The asymmetry is circulation, not secrecy: `app.log` is the file you attach to an issue.

## Not covered

- **No tests.** `swift test` needs full Xcode for `XCTest`. The transcription fix has an obvious shape: a fixture WAV with a pause, asserting both utterances survive.
- **The clipboard fallback has never been observed firing.**
- **`gesturesGranted`'s either-branch is untested** — granting Accessibility flips Input Monitoring true automatically, so the Input-Monitoring-only state was not reachable without giving up a working grant.
- A **bare folder-name title is a symptom of the Haiku summarizer not running** (`summaryText` NULL, spoken text falling back to verbatim assistant prose). Not chased.
- `open-issues.md` not updated, though `kind` closes issue #1's search for a discriminator.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
