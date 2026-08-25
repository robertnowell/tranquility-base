# The courtesy check — how we would know it works

Planning doc for the ruling in docs/rulings/ruling-an-arrival-does-not-move-the-panel.md
(ruling 3). Written 08 Aug 2026 in answer to "how can we test that this will
actually work… let's make sure this is safe, reliable, tested, and that it's not
going to make the codebase messy or introduce other regressions."

Nothing here is built. This is the shape of the evidence, decided before the
code, because the alternative is a threshold nobody can defend.

## The one design decision that makes it testable

**The detector never opens the microphone.** It takes audio in and returns a
decision:

```
CourtesyCheck.assess(samples) -> Assessment { speechDetected, peak, wordCount }
```

Opening the mic, timing the window, and closing it is a thin shell around that
call. Everything interesting is a pure function of a buffer.

This is the difference between a feature with a test suite and a feature whose
only evidence is somebody standing in a room saying "seems right." It also
matches how `InterruptGate` was already built — `Signals` is injectable
precisely because live-state reads once made fifteen tests depend on what was in
front on the developer's screen.

## Order of operations — the mic is the LAST question asked

Every cheap veto runs first. The microphone opens only if all of them pass.

| # | check | cost | on veto |
|---|---|---|---|
| 1 | our own capture owns the stage (`allowsAmbientSurface`) | free, already law | no hail, no toast — the user is mid-gesture |
| 2 | screen locked | free | hold |
| 3 | muted app frontmost (`mutedApps`) | one `lsappinfo` | hold |
| 4 | input device in use anywhere (`DeviceIsRunningSomewhere`) | one CoreAudio property read | hold |
| 5 | **open mic, listen ~5s** | indicator lights | hold if speech |
| 6 | **re-run 2–4** | free | hold |

Step 6 is not redundant. The check takes seconds, and the world moves inside
them: the user can lock the screen, take a call, or start typing between the
decision to listen and the decision to speak. A gate that evaluates only the
"before" is a gate that speaks into a room that changed its mind.

Step 1 is deliberately not a toast: nothing was suppressed from the user's point
of view, because the user is the one holding the key.

## Scenario matrix

The rows a session must be able to demonstrate. Fixture-testable rows are marked
**F**; live-drill rows **D**; field-only rows **L**.

| # | situation | expected | how |
|---|---|---|---|
| 1 | device idle, room silent | speak the callsign | F |
| 2 | device idle, one person talking nearby | hold + toast | F |
| 3 | device idle, fan / traffic / music without vocals | **speak** — this is the whole discrimination | F |
| 4 | device idle, podcast or video with speech | hold + toast (accepted degradation) | F |
| 5 | Zoom in background, not frontmost | hold at step 4, **mic never opens** | D |
| 6 | Zoom frontmost | held at step 3, before 4 even runs | F (injected signal) |
| 7 | user holds ⌥ mid-check | check aborts instantly, capture takes the device, no toast | D |
| 8 | on-device model unavailable | recogniser skipped, **never the network** | F |
| 9 | screen locks during the 5s window | held at step 6 | F (injected signal) |
| 10 | no input device present at all | skip the check, speak | F |
| 11 | two agents return within the window | one check, one decision, not two | F |
| 12 | Bluetooth mic that opens and sends silence | reads as "quiet room" → speaks | L, known false negative |
| 13 | permission denied for mic or speech | see open question below | — |
| 14 | check runs, hail held, panel dismissed | toast does **not** raise the panel | D |

Row 5 is the one that justifies the whole feature — it is the case that ships
broken today, because `mutedApps` only ever matches the frontmost app.

Row 12 is worth naming honestly rather than pretending it away: the same
Bluetooth failure `StateLegend.noAudioMessage` already documents will make a
loud room look silent. The consequence is that we speak when we shouldn't have,
which is exactly today's behaviour, so it is a non-regression rather than a new
bug.

## The fixture corpus

Six or seven short WAVs in `Tests/`, committed:

`silence`, `fan`, `traffic`, `music-instrumental`, `one-speaker`,
`two-speakers`, `podcast`.

Assert the expected decision for each. This corpus IS the threshold's
justification — without it, the number is a guess with a unit test wrapped
around it. Recorded on the built-in mic at a normal desk distance, and the
speech clips deliberately quiet, because a threshold tuned on loud speech will
miss the person murmuring next to you, which is the case that matters most.

No voices of real third parties, and nothing identifiable: read a paragraph of
public-domain text.

## What the drills must assert

Per CLAUDE.md rule 7, new panel behaviour owes `--selftest-hud` a drill, and
`swift test` says nothing about the panel.

1. **The suppressed-hail toast renders** — new state in the matrix.
2. **The toast does not raise a dismissed panel.** This is the regression that
   would quietly undo ruling 1, and it is exactly the class of bug the matrix
   diff was built to catch.
3. **The mic never opens when a cheap veto fired.** Assert via a counter, not by
   watching the indicator. If this regresses, the app starts lighting the
   recording light on a locked screen, and that is the failure that loses the
   user permanently.
4. **A capture that starts mid-check wins the device**, and the check leaves no
   engine running (`abandon()` was called, `running == false`).

## The log-only pass comes first

`GateObservationLog` exists for this and says so: run log-only for a day before
the gate suppresses anything, because thresholds tuned in the abstract are
usually wrong.

Concretely: ship steps 1–6 with the decision **recorded and ignored**. The hail
speaks as it does today; the log accumulates what the check would have decided
and why. After a day of real rooms, the threshold is chosen from data and the
suppression is switched on in a second commit that changes one boolean.

Log the level, the word count, and the reason. **Never the words.**

## Keeping it out of the way of the codebase

The seams all exist; the mess would come from inventing new ones.

- The device-in-use signal is a **fourth `InterruptGate.Signals` closure**, not a
  new subsystem. The gate stays the one place that answers "may I speak now."
- The mic shell uses `Recorder.start(openingStream: false)` and `abandon()`,
  which already mean "no network session" and "return no audio." No new capture
  path, and no chance of the check's audio reaching disk, because `stop()` — the
  only method that hands back `Data` — is never called.
- The toast is **`flashNotice(_:)` with a new `StateLegend` string**, exactly
  like `noWordsNotice`. Not a new `PanelState`, not a new face, not a new
  widget. `noWordsNotice` already has drill coverage to copy.
- The pure `assess()` function lives in Core with the fixtures, so it is
  `swift test`-able where nearly nothing else in this feature is.

If a session finds itself adding a `PanelState` case, a second gate, or a new
window, it has left the path.

## Open questions

1. **Permission denied — hold or speak?** If the mic (or speech recognition) is
   denied, the check cannot run. Two readings: *speak*, because the courtesy
   check is an enhancement and its absence should degrade to today's behaviour;
   or *hold*, because a check that cannot see the room should not assume it is
   empty. *This session's read: speak.* A user who denied the microphone still
   wants to know their agent came back, and holding forever turns a denied
   permission into a silently broken product. Needs Robert.

2. **How long is "a few seconds"?** Named constant, tuned in the log-only pass.
   Long enough to catch a pause between sentences, short enough that the hail
   does not feel disconnected from the arrival. The starting guess is 3–5s and
   nobody should defend it before the data arrives.
