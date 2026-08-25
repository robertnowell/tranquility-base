# docs/ — design rationale and build history

**Looking for what this app does or how to install/run it? That's the
[root README](../README.md), not this folder.** Everything here is the *why*
behind the behaviour that ships — design rulings, build-process history, and
visual references — kept because the next person to touch this code (human or
agent) needs to know a decision was deliberate before changing it, not because
it's required reading to use the app.

Three subfolders, one flat remainder:

- **`rulings/`** — binding design decisions, one per file, each stating what
  was decided and (often) what open questions remain. Read before touching the
  panel, the arrival path, or the announcement path.
- **`log/`** — build-process history: the arc's own day-by-day tracking doc
  (`architecture-program.md`), the running issue list, and merged-work pass
  records. Read for *why* something is the way it is; not a description of
  current behaviour.
- **`design/`** — hand-built HTML mockups and state diagrams.
- **This directory's remaining files** (`acknowledgement.md`,
  `instant-arm.md`, etc.) are smaller built/ruled docs that didn't earn their
  own subfolder.

## Why this index exists

`docs/` had grown to thirty-plus files with **no way to tell a shipped
behaviour from a proposal** — and CLAUDE.md rule 4 ("newest ruling wins") only
works if a session can find out which ruling is newest without reading all of
them. The failure this prevents already happened, on 08 Aug: the direction
section of `rulings/ruling-the-app-is-silent-and-the-panel-speaks.md` was
superseded three hours after it was written, by a ruling in a different file.
Nothing marked it. A session arriving at the older file first would have
concluded the work was unscheduled and been confidently wrong — the pointer
that now sits there was added by hand, which does not scale to thirty files.

## Status vocabulary

| Status | Means |
|---|---|
| **BUILT** `<sha>` | The behaviour ships. The doc is a record of why, not a plan. Safe to prune to its ruling plus the sha. |
| **RULED, NOT BUILT** | A decision the user made about behaviour that does not exist yet. **Binding on whoever builds it** — do not re-litigate, do not guess past the open questions it names. |
| **PARTLY BUILT** | Some of it ships, some does not, and the doc says which. |
| **RECORD** | A pass or harvest record for work already merged. Historical; read for context, not for instructions. |
| **LIVING** | Continuously edited, never "done". |
| **SUPERSEDED** | Kept only so a session landing here is sent somewhere better. |

**When you build a ruling, stamp it.** Change its line here to `BUILT <sha>` in
the same commit that builds it. That single habit is what keeps this file true —
and it is what makes a doc prunable later, because nothing can be deleted safely
while nothing knows what is live.

## Rulings — binding, and not yet built

These describe behaviour that does not exist. They are the ones to read before
touching the panel, the arrival path, or the announcement path.

| Doc | Status | About |
|---|---|---|
| `docs/rulings/ruling-the-capture-is-a-strip-under-the-card.md` | RULED, NOT BUILT | The reading card stays up for the whole capture; arming / listening / read-back are one fixed-height strip beneath it; ⌃⌃ while recording advances the text silently. Supersedes most of `docs/rulings/ruling-capture-returns-to-its-card.md`. Names three open questions — do not guess them. |
| `docs/rulings/ruling-capture-returns-to-its-card.md` | RULED, NOT BUILT | A capture that sends nothing returns to the card it interrupted, and no outcome reopens the microphone. **Was indexed BUILT `d106206` in error** — that commit added the doc and nothing else. Read the strip ruling first: it dissolves this doc's face-restore design and keeps only §C's lost-address rescue, §D, and §E. |
| `ruling-the-collapsed-strip.md` | RULED, NOT BUILT | The grid collapses to a ~40px lamp strip; the user owns the width; three states (expanded / collapsed / minimized). Names its own open questions — do not guess them. |
| `docs/rulings/ruling-an-arrival-does-not-move-the-panel.md` | RULED, NOT BUILT | An arrival never changes the panel's shape or visibility; a live microphone vetoes the spoken hail; the courtesy check listens before speaking and keeps nothing. |
| `courtesy-check-evidence-plan.md` | RULED, PARTLY BUILT | How we would know the courtesy check works. `LiveAudioCapture` has landed; the gate itself has not. Ship log-only before it suppresses anything. |

## Rulings — built

| Doc | Status | About |
|---|---|---|
| `acknowledgement.md` | BUILT `bc67741` | The two-colour light: blue registered, green recognized, hold 500ms then fade. |
| `measurement-audio-must-be-durable-from-the-first-frame.md` | BUILT `05b9422` | A recording is on disk while it is still being spoken. |
| `instant-arm.md` | BUILT | The `.arming` state, the ~80ms grace, and why typing must never flash the panel. |
| `docs/rulings/ruling-the-app-is-silent-and-the-panel-speaks.md` | PARTLY BUILT | Launch speaks nothing (`main.swift`, shipped) and the empty room teaches the first press (`a1b5291`). The rest — mute onboarding, silence as posture — is not built. **Its "Direction" section is SUPERSEDED** by `ruling-the-collapsed-strip.md`. |
| `ws-b-ruling.md` | BUILT | The WS-B interaction model, ruled 05 Aug. Binding input for `docs/log/ws-b-grid.md`. |
| `grid-visual-port.md` | BUILT | Grid visual variant A. |
| `prompt-rationale-spec.md` | BUILT | The rationale field. |

## Pass records — history, not instructions

Merged work, kept for the reasoning. Read these to find out *why* something is
the way it is; do not read them as a description of current behaviour.

`docs/log/3a-collapse.md` · `docs/log/ws-c-changes.md` · `docs/log/phase-1b-changes.md` · `docs/log/pr1-harvest.md` ·
`docs/log/a7-corehalves-counters.md` · `docs/log/a2-hail.md` · `docs/log/stt-and-store.md` ·
`docs/log/wiring-a4.md` · `docs/log/wiring-streaming.md` · `docs/log/ui-pass-7.md` · `docs/log/ws-b-grid.md` ·
`docs/log/simplification-pass.md` (applied, but contains one proposal explicitly marked
"not built" — mid-speech back-step)

## Living

| Doc | Status |
|---|---|
| `docs/log/open-issues.md` | LIVING — the running list. |
| `exploratory-ideas.md` | LIVING — captured, explicitly not committed. Nothing here is ruled. |

## The `.html` files

`docs/design/settings-microphone.html` · `docs/design/settings-recent.html` · `docs/design/state-architecture.html` ·
`docs/design/state-machine.html` · `docs/design/trigger-test.html`

Generated or hand-built visual references — state diagrams and settings mockups.
They are in-repo because they are *artifacts*, not prose duplicating a `.md`.

**Prose rulings do not get an HTML copy in here.** The consumer of a ruling is
the next session, which greps `docs/`; a second copy of the same words is a
second thing that can go stale, and no agent will ever open it. Rendered reading
copies for a human belong outside the repo.
