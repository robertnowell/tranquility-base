# Speech Recognition was always required; now it is asked for

Ruled 09 Aug 2026, after a measurement that went the other way twice. Records
what the acoustic eval established, because two of the three conclusions drawn
along the way were wrong and the wrong ones are the memorable ones.

## What is true

`AppleSpeechRecovery` is the last provider in `RecoveryChain`, described there as
"on-device last because it can never be unavailable." It cannot run at all
without the Speech Recognition grant, and **nothing in the app ever asked for
it.** The grant was acquired implicitly, the first time the recogniser actually
ran — in the middle of a failed dictation, which is the worst moment available.

So it joins the required set in `Permissions.Kind`, asked for in onboarding with
the other four.

This is an argument against evidence, per CLAUDE.md rule 4, not an argument
against an argument: a fallback that cannot execute is not a fallback, and the
app had no way to report that it wasn't there.

## The measurement, including the two wrong turns

The acoustic eval (docs/courtesy-check-evidence-plan.md, scripts/courtesy-eval.sh)
was built to answer whether the courtesy check can hear a person across a room.
It answered that, and found two permission bugs on the way that had nothing to do
with the question.

**Wrong turn 1 — "the detector cannot hear anything."** Every stimulus, including
speech at full volume, reported `level 0.0000`. The terminal has no microphone
grant, and a denied microphone does not throw: `AVAudioEngine` starts and
delivers zeros. Fixed by moving the harness into the app bundle, and separately
by making `CourtesyCheck` name digital silence as a dead device rather than as a
quiet room.

**Wrong turn 2 — "the app never asks, so the feature is inert in production and
`AppleSpeechRecovery` has never worked."** Half right, and the half that was
wrong was the alarming half. TCC keys on **path** as well as bundle id, so
`.build/debug/Tranquility Base.app` and `/Applications/Tranquility Base.app` are
different subjects with independent grants. The eval measured the build copy
(`notDetermined`); the installed copy had the grant and used it that same day —
`apple-speech: final: 9 utterance(s), 409 chars`, and again 513 chars.

The lesson for any future eval: **an eval that runs a different bundle than the
one that ships is measuring a different app.** Print the grants, as
`CourtesyEval` now does, or the environment will quietly answer a question you
did not ask.

## What the eval actually established about the detector

Same audio, captured by the app (which holds the microphone) and recognised in
the terminal (which holds speech) — the split exists precisely because no single
process on this machine holds both.

| stimulus | level | words | verdict |
|---|---|---|---|
| speech near (vol 70) | 0.0516 | 14 | HOLD |
| speech mid (vol 40) | 0.0126 | 5 | HOLD |
| speech with pauses (vol 40) | 0.0064 | 4 | HOLD |
| speech far (vol 20) | 0.0049 | — | never reached the recogniser |
| speech very far (vol 10) | 0.0039 | — | never reached the recogniser |
| broadband noise (vol 50) | 0.0238 | 0 | SPEAK |
| pure tone (vol 50) | 0.2474 | 0 | SPEAK |
| quiet room | 0.0030 | — | SPEAK |

**The recogniser is not the weak link.** It rejected a tone at 0.2474 — roughly
twenty times the level of speech it correctly caught at 0.0126 — and rejected
broadband noise at twice that speech's level. It does not false-positive on
loudness, which was the thing most likely to make this feature a mute switch.

**The level pre-filter is the weak link.** `quietFloor = 0.005` discarded both
far-speech rows before recognition, and the quiet room measured 0.0030 — inside
a factor of two of speech we wanted to catch. The floor is sitting in the noise.

**The pause failure did not appear.** Speech with 1.2–1.4s gaps was detected with
four words. Predicted, and wrong.

## Consequence for the floor — not yet ruled

The pre-filter's only justification was cost: don't wake the recogniser for an
empty room. Since the recogniser is demonstrably not fooled by loud non-speech,
the filter is buying very little safety and is provably costing real detections.

The indicated change is to drop `quietFloor` to just above digital silence and
let the recogniser arbitrate everything audible. That makes the code simpler and
the detection better at the same time, which is rare enough to be worth saying
plainly. The cost is that the recogniser runs on nearly every check — about a
second of CPU, once per arrival, not continuously.

Also unresolved: the room floor read 0.0010 on one run and 0.0030 on another, so
a fixed absolute threshold is fragile across rooms and times of day. Lowering it
sidesteps that; an adaptive floor would be the alternative, and is more machinery
than this deserves.

## Still not measured

A human voice at real distance. Every row above is a speaker at reduced volume,
which moves signal-to-noise but not directivity or room reverb. The runbook's
human round is what closes that, and nothing here substitutes for it.
