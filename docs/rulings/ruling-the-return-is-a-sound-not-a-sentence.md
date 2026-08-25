# The return is a sound, not a sentence

Ruled 10 Aug 2026, spoken. Final. Supersedes A2 (the spoken hail), ruling 3 of
docs/rulings/ruling-an-arrival-does-not-move-the-panel.md, and
docs/rulings/ruling-the-courtesy-check-is-one-question.md in its entirety.

## The ruling

> "I don't think I've received a single callsign reply announced. These are just
> going silent. I think it's basically not working, but I think it's fine. It's
> fine to kill the callsign announcement. It's just too complicated.
>
> Instead, if you're on Do Not Disturb, then agents return silently — no audio.
> If you're not on Do Not Disturb, they give a little sound indicator that
> something's come back. That's Pavlovian, and it tells you there's something
> ready for you to work.
>
> Final decision, rip out everything we did about the courtesy check, because I
> think it's just overwrought architecture for something we don't need."

## What the callsign cost, for the record

It never worked. Across every day it shipped it announced successfully zero
times — and the reason was not any of the three things investigated: it was that
`requestAuthorization` had never been called, so the recogniser the courtesy
check depended on refused, so every hail was held.

What it accumulated on the way:

- the interrupt gate consulted for unprompted surfacing (kept — cheap and right)
- a microphone opened for four seconds before every announcement, with a room
  detector, an acoustic eval harness and a fixture corpus (deleted 10 Aug)
- a HAL process-list gate replacing it (deleted the same day, by this ruling)
- a second lifecycle inside `Recorder`, the most incident-scarred file in the
  repo (deleted)
- two permissions argued over, one of them briefly made required and put in
  front of the user at every launch

All to decide whether saying one word was rude. The chime carries the same
information at none of that cost, and the panel already carries which agent.

## What ships

`ArrivalChime.play()` — one notification, sound, no body, `.passive`.

**Do Not Disturb is honoured by the system, not by us.** The app cannot read
Focus state: `~/Library/DoNotDisturb/DB/` is TCC-protected (measured 10 Aug —
`PermissionError` without Full Disk Access) and the legacy
`com.apple.notificationcenterui doNotDisturb` default has returned nothing since
Monterey. There is no public API. Asking for Full Disk Access so a menu-bar app
can decide whether to chime is not a trade worth making.

`UNUserNotificationCenter` inverts it: we do not ask permission to make a sound,
we hand the system a request and it applies Focus, Do Not Disturb, per-app sound
settings and scheduled summaries itself — correctly, for free, with native
controls the user already knows how to find.

The cost, stated because it is real: one authorisation prompt, and an entry in
Notification Center per arrival. `.passive` keeps it off the screen; a user who
wants sound without banners can say so in Settings.

**The notification carries no callsign.** The panel is up with the grid and it
says which agent. One bit — something came back — is what a Pavlovian cue can
carry, and is what was asked for.

## Deleted by this ruling

`AudioInputDevice.otherAppUsingAudio` / `audioProcesses` / `anyInputInUse` /
`anyOutputInUse` / `allOutputs` / `alwaysOnAudioClients`, the `audioBusyWith`
signal and `heldForCourtesy` on `InterruptGate.Decision`, `StateLegend.heldNotice`
and its advisory lens, the courtesy drill and pose, `tbase devices`, and
`speakHail` with the A2 hail it implemented.

`InterruptGate` is back to three free signals: locked screen, muted app in front,
active typing.

## Kept

- **The interrupt gate**, for whether the panel surfaces at all.
- **The 120s bound on `AppleSpeechRecovery`'s continuation** — an unbounded
  third-party callback on the transcription floor is a defect on its own terms.
- **Speech Recognition in onboarding**, now justified solely by that recovery
  provider, which genuinely cannot run without it and had never been asked.

## The lesson worth keeping

Two days of architecture went into protecting a feature that had never once
worked, and nobody noticed it had never worked because its failure mode was
silence — the same silence as success. Before building the thing that protects a
feature, confirm the feature does anything at all.
