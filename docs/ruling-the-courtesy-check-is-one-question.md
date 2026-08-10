# The courtesy check is one question, asked of the HAL

Ruled 10 Aug 2026, spoken, after two days that produced ~200 lines of detector,
an acoustic eval harness, three wrong diagnoses and one real bug. Supersedes the
room-listening half of docs/ruling-an-arrival-does-not-move-the-panel.md
(ruling 3) and retires docs/courtesy-check-evidence-plan.md.

## The ruling

> "To avoid the listener, given that we can check if the mic is currently in
> use, to decide whether to announce or not… let's go ahead and ship that
> simpler model, and delete any code for the interruption listener except for
> checking whether the microphone is currently in use. We could probably also
> tell if there's anything coming out through the speakers right now… if there's
> sound output or input, then probably don't announce."

And, earlier, the reason:

> "For seed, this seems complicated."

It was. The detector worked — measured through air, it held on speech at level
0.0017 and spoke through noise at seven times that. It was still the wrong
thing to build: insurance against a failure nobody has yet observed, whose
premium was a microphone opening on every arrival and a second lifecycle inside
`Recorder`, the most incident-scarred file in the repo.

## What ships

One question, asked of CoreAudio: **is another app using audio right now?**

`AudioInputDevice.otherAppUsingAudio(ourBundleID:)`. One HAL round-trip, no
permission, nothing opened, no indicator lit. It answers what the listener was
trying to infer — is a human on the other end of some audio — without inferring
anything.

Input and output both count. Talking over a video is the same discourtesy as
talking over a person, and output needs no microphone to detect.

## Why the device-level flag was not enough

The obvious version — `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
input device — was written first and would have shipped a permanently silent
app. Sampled every three seconds on an idle machine, 10 Aug:

    sample 1: com.apple.CoreSpeech[mic]  com.apple.Sound-Settings.extension[mic]
    sample 2: com.apple.CoreSpeech[mic]  com.apple.Sound-Settings.extension[mic]
    sample 3: com.apple.Sound-Settings.extension[mic]
    sample 4: com.apple.Sound-Settings.extension[mic]

Siri holds the microphone. So does the Sound pane in System Settings, drawing
its level meter, for as long as that window is open. A device-level check cannot
tell either from a phone call, so the gate would have vetoed every announcement
with no visible cause — a worse failure than the interruption it prevents,
because the user cannot even see it happening.

`kAudioHardwarePropertyProcessObjectList` (macOS 14.2+) names the clients, so the
gate can exclude the ones that are always on and the one that is us. Before 14.2
the list is empty, which callers must read as "cannot tell" and fall back to the
device flag — never as "the coast is clear".

## Deleted

`CourtesyCheck` (the detector, 121 code lines), `Recorder.sampleRoom` and the
generation-stamped second lifecycle it needed, `CourtesyEval` (118 lines that
shipped inside the app binary), `CourtesyLive`, `CourtesyDemo`,
`scripts/courtesy-eval.sh`, and the `tbase courtesy*` commands. `Recorder` is
back to one lifecycle, one `running` flag.

## Kept, because each stands on its own

- **The 120s bound on `AppleSpeechRecovery`'s continuation.** An unbounded
  third-party callback on the provider that is meant to be the floor under
  transcription is a defect regardless.
- **Speech Recognition in onboarding.** Its justification narrows to the
  recovery provider now that the courtesy path no longer needs a recogniser —
  but that provider genuinely cannot run without it, and it had never once been
  asked for.
- **The held-hail notice.** Now names the app: "Held — zoom.us is using audio".
  A hail held in silence is indistinguishable from an agent that never came back.

## What this does not settle

Whether the spoken callsign should exist at all. The cheap test is the one the
repo already owns: run with it on and record, via `tbase dogfood record`, every
time an announcement lands badly. Zero occurrences means even this gate is
insurance against nothing; many means the answer is a ping, not a better gate.
Neither outcome argues for listening to the room.
