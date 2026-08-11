# Ruling: no second of user audio is ever lost, and silence never asks a question

Ruled 10 Aug 2026, by the user, against measurement. Supersedes the write-ahead
paragraph in `Recorder`'s header comment and the current `.pendingSend` flow.

## 1. Audio is durable from the first frame, not from key-up

**"You should never lose a recording. You should never lose a transcript. If
there's ever an app restart or something fucks up, the recording should be
complete."**

`Recorder`'s header currently says per-chunk write-ahead "was considered and
rejected: it only buys the crash-mid-utterance case, and the failures that
actually happen are network and API ones." That reasoning was sound when it was
written and is now overruled by evidence rather than by argument, which is the
standard this repo holds reversals to:

- 10 Aug 18:59:41Z — a hands-free capture ran four minutes and was destroyed by
  `scripts/relaunch.sh`. The `capturing` marker exists to prevent exactly that
  and had aged out at its 180-second bound, so the relaunch read a live capture
  as stale and killed it.
- The crash-mid-utterance case is therefore not hypothetical. It happened, to a
  real recording, tonight.

**The rule.** Captured audio reaches disk while the capture is still running, not
only at key-up. A restart, a crash, or a relaunch at any instant leaves a
playable WAV containing everything spoken up to that instant. Uncompressed WAV
already gives us this property — a truncated WAV is parseable up to the last
flushed frame — and `AudioStore` already documents that as the reason for the
format. The write cadence is the only thing changing.

**The marker follows the capture, not a constant.** `CaptureMarker.staleAfter =
180` was calibrated on push-to-talk, where the longest observed utterance was 92
seconds. Hands-free has no such bound. The marker must be refreshed for as long
as the capture is live, so "stale" means "the writer died", never "the user is
still talking".

## 2. Transcription is retryable, by hand, from the settings panel

**"Transcription should be a button press to retry from the settings panel. And
then I can copy it and take it to the agent my fucking self."**

Audio surviving is necessary and not sufficient — a recording you cannot reach is
lost in every sense that matters to the person who spoke it. The Recent pane
(`docs/settings-recent.html`, design v3, still unshipped) is where this lives:
every capture listed, each with a retry-transcription action and a copy action.
Retry re-runs the existing `RecoveryChain` against the stored WAV; copy puts the
text on the pasteboard and gets out of the way.

This makes the settings panel load-bearing rather than cosmetic, and moves it
from the tail of the roadmap onto the durability lane.

## 3. Two paths out of a capture, and silence takes the quiet one

The current flow makes no distinction between "you said something I got wrong"
and "you said nothing at all". It must.

**Path A — speech was captured.** Transcript, `.pendingSend`, Go / Don't send.
Don't send **closes the microphone and returns to idle. Nothing reopens until you
ask.** Today `StatusHUD.swift:269` hardcodes `cancelPendingSend(restartListening:
true)`, whose callback calls `recorder.start()` again (`main.swift:1993–1995`) —
the gesture that means "no" behaves like "again". The parameter already exists;
it becomes `false`.

**Path B — no speech was captured.** **Skip the confirmation card entirely.** One
quiet line that fades, then the grid. No Don't-send, no readback, no decision
asked of someone who did not ask a question. A screen that appears for a slip
teaches you to fear the key — the existing comment above `reportNothingHeard`
already says this; the code just does not reach it on this path.

### Why path B is currently unreachable, and the gate that fixes it

The silence gate is `recorder.stop()` throwing `nothingRecorded` below 1600
bytes — about 50 ms. **Three seconds of a quiet room is not 50 ms of audio.** It
is three seconds of room tone, it clears the gate comfortably, and it is handed
to the recogniser, which hallucinates. Observed: a silent hold produced
plausible-looking Korean text, which then took the full Path A treatment.

So `!text.isEmpty` is the wrong test and always was. Recognisers do not return
empty strings on silence; they invent. **The gate must be on the audio, not on
the text.**

`CourtesyCheck.assess(samples:sampleRate:)` already does exactly this
discrimination and is already tuned: digital-silence detection, a measured
`quietFloor`, and a word count that separates a person from a fan. It is used
today only to decide whether to talk over someone. It becomes the gate on the
dictation path too — same thresholds, same measurements, one implementation.

## 4. A capture may begin while the app is speaking — that is the product

Barge-in stays. What changes is that stopping the speech and reading the input
format are no longer the same instant: the speech stops, the device is given
time to settle, and only then is the format read and the tap installed. Every
lost capture on 10 Aug began during playback, and the rate in every failure
(24 kHz mono Float32) is the announcement's rate, not the microphone's (48 kHz).

## 5. The bundle identifier is renamed now

`BUNDLE_ID=com.robertnowell.voice-dispatch` becomes the product's own identifier.
Ruled against the recommendation to keep the legacy id permanently: the user's
call, made knowing that TCC keys grants to the identifier and that Microphone,
Input Monitoring and Accessibility will each need re-granting once on every
machine that has the app installed.

Sequencing consequence to respect: a fresh permission grant lands in the middle
of an open microphone investigation, so any capture failure observed immediately
after the rename must be re-derived rather than attributed.

## 6. And one screen has to justify itself

`main.swift:1917` — "This recording lost its address. Audio kept; nothing sent."
Reached when `recordingTarget` is nil at send time. The user does not know what
it is for, which is the whole finding: a card that appears at the end of a
capture, offers no action, and names an internal concept ("address") is not
communicating a condition, it is reporting an implementation detail. Either it
names something the user can act on, or it becomes a quiet line under Path B's
rule, or the condition that produces it gets fixed so it cannot occur. Open.
