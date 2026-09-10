# audio-hal-watchdog

Developer diagnostics for one machine: notice a wedged `coreaudiod` and save the
one artefact no incident has produced, a spindump of the daemon at the moment of
the deadlock. Capture only; the app's own "Audio stopped" card does the restart.

## The failure it covers

Three times (28 Aug, 03 Sep, 09 Sep 2026) macOS audio died system-wide while
AirPods Pro were connected and Zoom activated its virtual "share computer sound"
device with Voice Isolation on. coreaudiod logs `Negotiate response failed` on
every such click; on one click in three it then deadlocks, and every CoreAudio
call from every process times out at 30 s. Since 09 Sep the app detects that within
five seconds and offers the restart behind the password sheet. What is still
unknown is who holds the lock, and whether this app is ever part of it. Only a
spindump of coreaudiod taken while it is wedged answers that.

## Safety

- One sudoers line, one exact command, no wildcard:
  `/usr/sbin/spindump coreaudiod 3 -stdout`. The dump goes to stdout and this
  script redirects it as the user, so the rule cannot write a file anywhere as root.
- No automated privileged restart by default. `install.sh --with-restart` adds
  `killall coreaudiod` and `WATCHDOG_RESTART=1` uses it; not recommended on a
  machine somebody is sitting at, because a false positive would cut a live call.
- The probe (`say -a ?` every 20 s, 8 s timeout, confirmed 5 s later) is one HAL
  read; it makes no changes and has no false positives under a Bluetooth
  renegotiation, which takes about 2 s.
- Removal is two commands, printed by install.sh.

## Install

    bash tools/audio-hal-watchdog/install.sh

Asks for your password once and proves the rule on the spot with a three-second
dump of the healthy daemon.

## What it saves when it fires

Under `~/Library/Application Support/VoiceDispatch/audio-watchdog/incidents/<stamp>/`:
`coreaudiod.spindump.txt` (root, the point of the tool), `TranquilityApp.sample.txt`
and `zoom.us.sample.txt` (no root needed), `processes.txt`, and a five-minute
unified-log slice. Plus a macOS notification telling you to use the app's Restart
audio button.

## Test without acting

    DRY_RUN=1 PROBE_TIMEOUT=0 bash tools/audio-hal-watchdog/watchdog.sh
